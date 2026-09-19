#!/usr/bin/env bash
#
# sync-github-repo.sh
#
# Fetches all of your personal GitHub repositories (excluding forks and
# organization repositories) and replicates them to one or more
# destinations (Codeberg, rickub, or any Forgejo-compatible instance):
# creates the remote repository if it doesn't exist, then a full mirror
# (branches + tags) via `git clone --mirror` / `git push --mirror`.
# The repository description is copied at creation time, and kept in sync
# (via PATCH) whenever it differs from the GitHub one.
#
# For destinations that support archiving (Codeberg), if the GitHub
# repository is archived the destination repository is unarchived for the
# duration of the update and re-archived afterward; if it is already
# archived on the destination side, it is also unarchived before syncing
# (otherwise the push fails).
#
# Releases are also synchronized: GitHub releases (metadata, and assets
# where supported) are replicated to the destination, with draft releases
# skipped and orphaned destination releases deleted. This can be
# controlled via SYNC_RELEASES and SYNC_RELEASE_ASSETS environment
# variables.
#
# Usage:
#   ./sync-github-repo.sh [--dry-run] [--limit N] [--repo owner/repo]...
#                            [--dest codeberg] [--dest rickub]...
#
# If --dest is not specified, all configured destinations (those whose
# tokens and usernames are present in .env) are used automatically.
# Configuration: see .env.example (copy to .env and fill in the values).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
DRY_RUN=0
LIMIT=0
REPOS=()
DESTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --limit)
      LIMIT="${2:?"--limit requires a value"}"
      shift 2
      ;;
    --repo)
      REPOS+=("${2:?"--repo requires a value"}")
      shift 2
      ;;
    --dest)
      DESTS+=("${2:?"--dest requires a value"}")
      shift 2
      ;;
    --dest=*)
      DESTS+=("${1#--dest=}")
      shift
      ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

if [[ -f "$SCRIPT_DIR/../.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../.env"
  set +a
fi

# Release sync configuration (defaults: both enabled)
SYNC_RELEASES="${SYNC_RELEASES:-true}"
SYNC_RELEASE_ASSETS="${SYNC_RELEASE_ASSETS:-true}"

log()  { printf '%s\n' "$*"; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Destination profiles
# ---------------------------------------------------------------------------
# Each profile sets the DEST_* variables used by the generic API helpers
# and the main sync loop.  To add a new destination, add a case below and
# the corresponding env vars to .env.example.

# Known destination names (used for auto-detection)
ALL_DESTS=(codeberg rickub)

load_dest_profile() {
  local dest="$1"
  case "$dest" in
    codeberg)
      DEST_KEY="codeberg"
      DEST_NAME="Codeberg"
      DEST_API="${CODEBERG_API:-https://codeberg.org/api/v1}"
      DEST_GIT_HOST="codeberg.org"
      DEST_TOKEN="${CODEBERG_TOKEN:-}"
      DEST_USER="${CODEBERG_USER:-}"
      DEST_AUTH_SCHEME="token"
      DEST_SUPPORTS_ARCHIVE=true
      DEST_SUPPORTS_ASSETS=true
      DEST_NEEDS_RELEASES_ENABLED=true
      DEST_CREATE_ENDPOINT="user/repos"
      DEST_VISIBILITY_FORMAT="boolean"
      DEST_RELEASES_PER_PAGE=100
      ;;
    rickub)
      DEST_KEY="rickub"
      DEST_NAME="rickub"
      DEST_API="${RICKUB_API:-https://rickub.com/api/v1}"
      DEST_GIT_HOST="${RICKUB_GIT_HOST:-git.rickub.com}"
      DEST_TOKEN="${RICKUB_TOKEN:-}"
      DEST_USER="${RICKUB_USER:-}"
      DEST_AUTH_SCHEME="Bearer"
      DEST_SUPPORTS_ARCHIVE=false
      DEST_SUPPORTS_ASSETS=false
      DEST_NEEDS_RELEASES_ENABLED=false
      DEST_CREATE_ENDPOINT="repos"
      DEST_VISIBILITY_FORMAT="string"
      DEST_RELEASES_PER_PAGE=50
      ;;
    *)
      err "Unknown destination: $dest"
      err "Available destinations: ${ALL_DESTS[*]}"
      exit 1
      ;;
  esac
}

# Returns 0 if the destination's required env vars are configured, 1 otherwise.
dest_is_configured() {
  local dest="$1"
  load_dest_profile "$dest"
  [[ -n "$DEST_TOKEN" && -n "$DEST_USER" ]]
}

# Validate a destination's configuration and error out if incomplete.
dest_validate() {
  local dest="$1"
  load_dest_profile "$dest"
  local token_var user_var
  case "$dest" in
    codeberg) token_var="CODEBERG_TOKEN"; user_var="CODEBERG_USER" ;;
    rickub)   token_var="RICKUB_TOKEN";   user_var="RICKUB_USER" ;;
  esac
  if [[ -z "$DEST_TOKEN" ]]; then
    err "Missing variable '$token_var' for destination '$dest'. Copy .env.example to .env and fill it in."
    return 1
  fi
  if [[ -z "$DEST_USER" ]]; then
    err "Missing variable '$user_var' for destination '$dest'. Copy .env.example to .env and fill it in."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Resolve the list of destinations to sync
# ---------------------------------------------------------------------------
if [[ ${#DESTS[@]} -gt 0 ]]; then
  # Validate explicitly specified destinations
  for dest in "${DESTS[@]}"; do
    if ! dest_validate "$dest"; then
      exit 1
    fi
  done
else
  # Auto-detect all configured destinations
  log "No --dest specified, detecting configured destinations..."
  for dest in "${ALL_DESTS[@]}"; do
    if dest_is_configured "$dest"; then
      DESTS+=("$dest")
      log "  Found configured destination: $dest"
    fi
  done
  if [[ ${#DESTS[@]} -eq 0 ]]; then
    err "No destinations configured. Set CODEBERG_TOKEN/CODEBERG_USER and/or RICKUB_TOKEN/RICKUB_USER in .env, or specify --dest explicitly."
    exit 1
  fi
fi

log "Destinations: ${DESTS[*]}"

# ---------------------------------------------------------------------------
# Binary checks
# ---------------------------------------------------------------------------
for bin in gh git curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { err "'$bin' is required but was not found in PATH."; exit 1; }
done

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  err "No GitHub token available. Run 'gh auth login' or set GITHUB_TOKEN in .env."
  exit 1
fi

# ---------------------------------------------------------------------------
# Redact secrets in logs
# ---------------------------------------------------------------------------
redact() {
  local sed_expr=()
  sed_expr+=(-e "s#${GITHUB_TOKEN}#***#g")
  for dest in "${DESTS[@]}"; do
    load_dest_profile "$dest"
    sed_expr+=(-e "s#${DEST_TOKEN}#***#g")
  done
  sed "${sed_expr[@]}" <<<"$1"
}

# ---------------------------------------------------------------------------
# Temporary working directory
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh2dest.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fetch the list of GitHub repositories (personal, non-forks)
# ---------------------------------------------------------------------------
log "Fetching the list of GitHub repositories..."
if [[ ${#REPOS[@]} -gt 0 ]]; then
  repos_json="[]"
  for repo_spec in "${REPOS[@]}"; do
    repo_json="$(gh repo view "$repo_spec" \
      --json nameWithOwner,name,isFork,isArchived,isPrivate,description 2>/dev/null || true)"
    if [[ -z "$repo_json" ]]; then
      err "Repository '$repo_spec' not found or inaccessible"
      exit 1
    fi
    repos_json="$(jq --argjson r "$repo_json" '. + [$r]' <<<"$repos_json")"
  done
else
  repos_json="$(gh repo list --source --limit 1000 \
    --json nameWithOwner,name,isFork,isArchived,isPrivate,description)"
fi

# Safety filter (gh --source should already exclude forks)
filtered_json="$(jq -c '[.[] | select(.isFork == false)]' <<<"$repos_json")"
total="$(jq 'length' <<<"$filtered_json")"

if [[ "$LIMIT" -gt 0 && "$LIMIT" -lt "$total" ]]; then
  filtered_json="$(jq -c ".[0:$LIMIT]" <<<"$filtered_json")"
  total="$LIMIT"
fi

log "-> $total repo(s) to process."
[[ "$DRY_RUN" -eq 1 ]] && log "(--dry-run mode: no changes will be made)"

# ---------------------------------------------------------------------------
# Generic API helper functions (use DEST_* variables set by load_dest_profile)
# ---------------------------------------------------------------------------

# Generic GitHub API caller
# Usage: gh_api GET /repos/owner/repo/releases
#        gh_api POST /repos/owner/repo/releases -d '{"tag_name":"v1"}'
gh_api() {
  local method="$1" path="$2"
  shift 2
  curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -X "$method" "https://api.github.com${path}" "$@"
}

# Destination API caller for repo-level operations (returns HTTP status code)
# Uses DEST_AUTH_SCHEME and DEST_TOKEN from the current profile.
# Usage: dest_http_status GET "$DEST_API/repos/$DEST_USER/$name"
dest_http_status() {
  local method="$1" url="$2"
  shift 2
  curl -s -o "$WORKDIR/resp_body.json" -w '%{http_code}' \
    -H "Authorization: ${DEST_AUTH_SCHEME} ${DEST_TOKEN}" \
    -X "$method" "$@" "$url"
}

# Destination API caller for release operations (returns HTTP status code)
# Uses DEST_API as base URL.
# Usage: dest_api_status GET /repos/user/repo/releases
#        dest_api_status POST /repos/user/repo/releases -d '{"tag_name":"v1"}'
dest_api_status() {
  local method="$1" path="$2"
  shift 2
  curl -s -o "$WORKDIR/resp_body.json" -w '%{http_code}' \
    -H "Authorization: ${DEST_AUTH_SCHEME} ${DEST_TOKEN}" \
    -H "Content-Type: application/json" \
    -X "$method" "${DEST_API}${path}" "$@"
}

# Destination API caller that returns JSON body
# Usage: dest_api GET /repos/user/repo/releases
dest_api() {
  local method="$1" path="$2"
  shift 2
  local status
  status="$(dest_api_status "$method" "$path" "$@")"
  if [[ "$status" != "200" && "$status" != "201" && "$status" != "204" ]]; then
    return 1
  fi
  cat "$WORKDIR/resp_body.json"
}

patch_archived() {
  # $1: repo name, $2: "true" or "false"
  local name="$1" archived="$2"
  dest_http_status PATCH "${DEST_API}/repos/${DEST_USER}/${name}" \
    -H 'Content-Type: application/json' \
    -d "{\"archived\":$archived}"
}

patch_description() {
  # $1: repo name, $2: description
  local name="$1" description="$2" payload
  payload="$(jq -n --arg description "$description" '{description: $description}')"
  dest_http_status PATCH "${DEST_API}/repos/${DEST_USER}/${name}" \
    -H 'Content-Type: application/json' \
    -d "$payload"
}

create_repo() {
  # $1: repo name, $2: is_private ("true"/"false"), $3: description
  local name="$1" is_private="$2" description="$3" payload endpoint
  if [[ "$DEST_VISIBILITY_FORMAT" == "boolean" ]]; then
    payload="$(jq -n --arg name "$name" --argjson private "$is_private" \
      --arg description "$description" \
      '{name: $name, private: $private, auto_init: false, description: $description}')"
  else
    local visibility
    if [[ "$is_private" == "true" ]]; then
      visibility="private"
    else
      visibility="public"
    fi
    payload="$(jq -n \
      --arg name "$name" \
      --arg visibility "$visibility" \
      --arg description "$description" \
      '{name: $name, visibility: $visibility, description: $description}')"
  fi
  endpoint="${DEST_API}/${DEST_CREATE_ENDPOINT}"
  dest_http_status POST "$endpoint" \
    -H 'Content-Type: application/json' \
    -d "$payload"
}

# ---------------------------------------------------------------------------
# Release Synchronization Functions
# ---------------------------------------------------------------------------

# Fetch all releases from GitHub for a repository
# Returns JSON array of published (non-draft) releases
fetch_github_releases() {
  local owner="$1" repo="$2"
  local page=1
  local all_releases="[]"
  local per_page=100

  while true; do
    local response
    response="$(gh_api GET "/repos/${owner}/${repo}/releases?per_page=${per_page}&page=${page}")"

    if [[ -z "$response" ]]; then
      err "  Failed to fetch GitHub releases for ${owner}/${repo}"
      return 1
    fi

    # Check for rate limiting
    local rate_message
    rate_message="$(jq -r '.message' <<<"$response" 2>/dev/null || true)"
    if [[ "$rate_message" == *"rate limit"* ]]; then
      err "  GitHub rate limit exceeded: $rate_message"
      return 1
    fi

    # Filter out draft releases and add to collection
    local page_releases
    page_releases="$(jq '[.[] | select(.draft == false)]' <<<"$response")"
    all_releases="$(jq --argjson existing "$all_releases" --argjson new "$page_releases" '$existing + $new' <<<"$all_releases")"

    # Check if there are more pages (based on the raw page size, before draft
    # filtering, so a page containing drafts doesn't stop pagination early)
    local raw_count
    raw_count="$(jq 'length' <<<"$response")"
    if [[ "$raw_count" -lt "$per_page" ]]; then
      break
    fi

    page=$((page + 1))
  done

  echo "$all_releases"
}

# Fetch all releases from the destination for a repository
# Returns JSON array of releases
fetch_dest_releases() {
  local repo_name="$1"
  local page=1
  local all_releases="[]"
  local per_page="$DEST_RELEASES_PER_PAGE"

  while true; do
    local status
    status="$(dest_api_status GET "/repos/${DEST_USER}/${repo_name}/releases?per_page=${per_page}&page=${page}")"

    if [[ "$status" == "200" ]]; then
      local page_releases
      page_releases="$(cat "$WORKDIR/resp_body.json")"
      all_releases="$(jq --argjson existing "$all_releases" --argjson new "$page_releases" '$existing + $new' <<<"$all_releases")"

      local count
      count="$(jq 'length' <<<"$page_releases")"
      if [[ "$count" -lt "$per_page" ]]; then
        break
      fi
      page=$((page + 1))
    else
      break
    fi
  done

  echo "$all_releases"
}

# Create a release on the destination
# $1: repo_name, $2: tag_name, $3: name, $4: body, $5: prerelease (true/false)
# Returns the created release JSON or empty on error
create_dest_release() {
  local repo_name="$1" tag_name="$2" name="$3" body="$4" prerelease="$5"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "    [dry-run] Would create ${DEST_NAME} release: tag=$tag_name name=$name"
    return 0
  fi

  local payload
  payload="$(jq -n \
    --arg tag_name "$tag_name" \
    --arg name "$name" \
    --arg body "$body" \
    --argjson prerelease "$prerelease" \
    '{tag_name: $tag_name, name: $name, body: $body, prerelease: $prerelease}')"

  local status
  status="$(dest_api_status POST "/repos/${DEST_USER}/${repo_name}/releases" \
    -H 'Content-Type: application/json' \
    -d "$payload")"

  if [[ "$status" == "201" ]]; then
    cat "$WORKDIR/resp_body.json"
    return 0
  else
    err "    Failed to create ${DEST_NAME} release (HTTP $status): $(cat "$WORKDIR/resp_body.json")"
    return 1
  fi
}

# Update a release on the destination
# $1: repo_name, $2: release_id, $3: name, $4: body, $5: prerelease (true/false)
# Returns 0 on success, 1 on error
update_dest_release() {
  local repo_name="$1" release_id="$2" name="$3" body="$4" prerelease="$5"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "    [dry-run] Would update ${DEST_NAME} release $release_id: name=$name"
    return 0
  fi

  local payload
  payload="$(jq -n \
    --arg name "$name" \
    --arg body "$body" \
    --argjson prerelease "$prerelease" \
    '{name: $name, body: $body, prerelease: $prerelease}')"

  local status
  status="$(dest_api_status PATCH "/repos/${DEST_USER}/${repo_name}/releases/${release_id}" \
    -H 'Content-Type: application/json' \
    -d "$payload")"

  if [[ "$status" == "200" ]]; then
    return 0
  else
    err "    Failed to update ${DEST_NAME} release $release_id (HTTP $status): $(cat "$WORKDIR/resp_body.json")"
    return 1
  fi
}

# Delete a release on the destination
# $1: repo_name, $2: release_id
# Returns 0 on success, 1 on error
delete_dest_release() {
  local repo_name="$1" release_id="$2"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "    [dry-run] Would delete ${DEST_NAME} release $release_id"
    return 0
  fi

  local status
  status="$(dest_api_status DELETE "/repos/${DEST_USER}/${repo_name}/releases/${release_id}")"

  if [[ "$status" == "204" ]]; then
    return 0
  else
    err "    Failed to delete ${DEST_NAME} release $release_id (HTTP $status): $(cat "$WORKDIR/resp_body.json")"
    return 1
  fi
}

# Enable releases feature on the destination repository (if needed)
# $1: repo_name
# Returns 0 on success, 1 on error
ensure_releases_enabled() {
  local repo_name="$1"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "    [dry-run] Would check/enable releases feature"
    return 0
  fi

  local status
  status="$(dest_api_status GET "/repos/${DEST_USER}/${repo_name}")"

  if [[ "$status" != "200" ]]; then
    err "    Failed to check ${DEST_NAME} repository (HTTP $status): $(cat "$WORKDIR/resp_body.json")"
    return 1
  fi

  local has_releases
  has_releases="$(jq -r '.has_releases // false' <<<"$(cat "$WORKDIR/resp_body.json")")"

  if [[ "$has_releases" == "true" ]]; then
    return 0
  fi

  log "    Enabling releases feature on ${DEST_NAME} repository..."

  local payload
  payload="$(jq -n '{has_releases: true}')"

  status="$(dest_api_status PATCH "/repos/${DEST_USER}/${repo_name}" \
    -H 'Content-Type: application/json' \
    -d "$payload")"

  if [[ "$status" == "200" ]]; then
    log "    Releases feature enabled on ${DEST_NAME}"
    return 0
  else
    err "    Failed to enable releases feature (HTTP $status): $(cat "$WORKDIR/resp_body.json")"
    return 1
  fi
}

# Sync assets for a release
# $1: gh_owner, $2: gh_repo, $3: gh_release_id, $4: dest_repo, $5: dest_release_id
sync_release_assets() {
  local gh_owner="$1" gh_repo="$2" gh_release_id="$3"
  local dest_repo="$4" dest_release_id="$5"

  if [[ "${SYNC_RELEASE_ASSETS:-true}" != "true" ]]; then
    log "    Asset sync disabled, skipping"
    return 0
  fi

  log "    Syncing assets for release..."

  # Fetch GitHub assets
  local gh_assets
  gh_assets="$(gh_api GET "/repos/${gh_owner}/${gh_repo}/releases/${gh_release_id}/assets")"

  if [[ -z "$gh_assets" || "$gh_assets" == "[]" ]]; then
    log "    No GitHub assets to sync"
    # Check if destination has assets to delete
    local dest_assets
    dest_assets="$(dest_api GET "/repos/${DEST_USER}/${dest_repo}/releases/${dest_release_id}/assets" 2>/dev/null || echo "[]")"

    if [[ "$dest_assets" != "[]" ]]; then
      local dest_asset_count
      dest_asset_count="$(jq 'length' <<<"$dest_assets")"
      log "    Deleting $dest_asset_count orphaned assets from ${DEST_NAME}..."

      local asset_ids
      asset_ids="$(jq -r '.[].id' <<<"$dest_assets")"

      for asset_id in $asset_ids; do
        if ! delete_dest_release_asset "$dest_repo" "$asset_id"; then
          return 1
        fi
      done
    fi
    return 0
  fi

  # Fetch destination assets
  local dest_assets
  dest_assets="$(dest_api GET "/repos/${DEST_USER}/${dest_repo}/releases/${dest_release_id}/assets" 2>/dev/null || echo "[]")"

  # Build map of destination assets by name
  local dest_asset_names
  dest_asset_names="$(jq -r '[.[].name] | unique | .[]' <<<"$dest_assets" 2>/dev/null || echo "")"

  # Process each GitHub asset
  local gh_asset_count
  gh_asset_count="$(jq 'length' <<<"$gh_assets")"
  local processed=0

  while IFS= read -r gh_asset; do
    if [[ -z "$gh_asset" ]]; then continue; fi

    local gh_asset_name
    gh_asset_name="$(jq -r '.name' <<<"$gh_asset")"
    local gh_asset_id
    gh_asset_id="$(jq -r '.id' <<<"$gh_asset")"

    # Check if asset exists on destination
    if grep -qxF "$gh_asset_name" <<<"$dest_asset_names" 2>/dev/null; then
      log "    Asset '$gh_asset_name' already exists on ${DEST_NAME}, skipping"
    else
      log "    Uploading asset '$gh_asset_name' to ${DEST_NAME}..."

      # Download from GitHub
      local temp_file="$WORKDIR/asset_${gh_asset_id}_${gh_asset_name}"
      if ! download_github_asset "$gh_owner" "$gh_repo" "$gh_asset_id" "$temp_file"; then
        err "    Failed to download asset '$gh_asset_name'"
        return 1
      fi

      # Upload to destination
      if ! upload_dest_asset "$dest_repo" "$dest_release_id" "$gh_asset_name" "$temp_file"; then
        rm -f "$temp_file"
        return 1
      fi

      rm -f "$temp_file"
    fi

    processed=$((processed + 1))
  done < <(jq -c '.[]' <<<"$gh_assets")

  # Delete orphaned destination assets (those not on GitHub)
  while IFS= read -r dest_asset; do
    if [[ -z "$dest_asset" ]]; then continue; fi

    local dest_asset_name
    dest_asset_name="$(jq -r '.name' <<<"$dest_asset")"
    local dest_asset_id
    dest_asset_id="$(jq -r '.id' <<<"$dest_asset")"

    # Check if this asset exists on GitHub
    if ! jq -e --arg name "$dest_asset_name" 'any(.[]; .name == $name)' <<<"$gh_assets" >/dev/null 2>&1; then
      log "    Deleting orphaned asset '$dest_asset_name' from ${DEST_NAME}..."
      if ! delete_dest_release_asset "$dest_repo" "$dest_asset_id"; then
        return 1
      fi
    fi
  done < <(jq -c '.[]' <<<"$dest_assets")

  return 0
}

# Download a release asset from GitHub
# $1: owner, $2: repo, $3: asset_id, $4: output_file
download_github_asset() {
  local owner="$1" repo="$2" asset_id="$3" output_file="$4"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "    [dry-run] Would download asset $asset_id to $output_file"
    touch "$output_file"
    return 0
  fi

  local asset_info
  asset_info="$(gh_api GET "/repos/${owner}/${repo}/releases/assets/${asset_id}")"

  if [[ -z "$asset_info" ]]; then
    err "    Failed to get asset info from GitHub"
    return 1
  fi

  local download_url
  download_url="$(jq -r '.browser_download_url' <<<"$asset_info")"

  if [[ "$download_url" == "null" || -z "$download_url" ]]; then
    err "    No download URL for asset $asset_id"
    return 1
  fi

  local status
  status="$(curl -s -w '%{http_code}' -L \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    -o "$output_file" \
    "$download_url")"

  if [[ "$status" != "200" ]]; then
    rm -f "$output_file"
    err "    Failed to download asset (HTTP $status)"
    return 1
  fi

  return 0
}

# Upload a release asset to the destination
# $1: repo_name, $2: release_id, $3: asset_name, $4: file_path
upload_dest_asset() {
  local repo_name="$1" release_id="$2" asset_name="$3" file_path="$4"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "    [dry-run] Would upload asset '$asset_name' to ${DEST_NAME}"
    return 0
  fi

  local encoded_name url status fallback_status
  encoded_name="$(jq -rn --arg n "$asset_name" '$n|@uri')"
  url="${DEST_API}/repos/${DEST_USER}/${repo_name}/releases/${release_id}/assets?name=${encoded_name}"

  # Forgejo accepts a raw octet-stream body when the name is given as a query parameter.
  status="$(curl -s -o "$WORKDIR/resp_body.json" -w '%{http_code}' \
    -X POST \
    -H "Authorization: ${DEST_AUTH_SCHEME} ${DEST_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${file_path}" \
    "$url")"

  if [[ "$status" == "201" || "$status" == "200" ]]; then
    return 0
  fi

  # Fallback for older Forgejo versions that only accept multipart/form-data.
  fallback_status="$(curl -s -o "$WORKDIR/resp_body.json" -w '%{http_code}' \
    -X POST \
    -H "Authorization: ${DEST_AUTH_SCHEME} ${DEST_TOKEN}" \
    -F "attachment=@${file_path};filename=${asset_name}" \
    "$url")"

  if [[ "$fallback_status" == "201" || "$fallback_status" == "200" ]]; then
    return 0
  fi

  err "    Failed to upload asset '$asset_name' (HTTP $status, fallback HTTP $fallback_status): $(redact "$(cat "$WORKDIR/resp_body.json")")"
  return 1
}

# Delete a release asset from the destination
# $1: repo_name, $2: asset_id
delete_dest_release_asset() {
  local repo_name="$1" asset_id="$2"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "    [dry-run] Would delete ${DEST_NAME} asset $asset_id"
    return 0
  fi

  local status
  status="$(dest_api_status DELETE "/repos/${DEST_USER}/${repo_name}/releases/assets/${asset_id}")"

  if [[ "$status" == "204" ]]; then
    return 0
  else
    err "    Failed to delete ${DEST_NAME} asset $asset_id (HTTP $status): $(cat "$WORKDIR/resp_body.json")"
    return 1
  fi
}

# Main release sync function
# $1: repo_name, $2: owner
sync_releases() {
  local repo_name="$1" owner="$2"

  log "    Syncing releases..."

  # Ensure releases feature is enabled on destination (if needed)
  if [[ "$DEST_NEEDS_RELEASES_ENABLED" == "true" ]]; then
    if ! ensure_releases_enabled "$repo_name"; then
      err "    Cannot sync releases: releases feature not available on ${DEST_NAME}"
      return 1
    fi
  fi

  # Fetch GitHub releases (published only)
  local gh_releases
  if ! gh_releases="$(fetch_github_releases "$owner" "$repo_name")"; then
    err "    Failed to fetch GitHub releases"
    return 1
  fi

  # Fetch destination releases
  local dest_releases
  dest_releases="$(fetch_dest_releases "$repo_name")"

  # Build map by tag_name for destination releases
  local dest_by_tag="{}"
  if [[ "$dest_releases" != "[]" ]]; then
    dest_by_tag="$(jq -c 'map({(.tag_name): .}) | add // {}' <<<"$dest_releases")"
  fi

  local gh_count=0 dest_count=0 created=0 updated=0 deleted=0
  gh_count="$(jq 'length' <<<"$gh_releases")"
  dest_count="$(jq 'length' <<<"$dest_releases")"

  log "    GitHub: $gh_count published releases, ${DEST_NAME}: $dest_count releases"

  # First pass: create/update releases from GitHub
  while IFS= read -r gh_release; do
    if [[ -z "$gh_release" ]]; then continue; fi

    local tag_name
    tag_name="$(jq -r '.tag_name' <<<"$gh_release")"
    local name
    name="$(jq -r '.name // ""' <<<"$gh_release")"
    local body
    body="$(jq -r '.body // ""' <<<"$gh_release")"
    local prerelease
    prerelease="$(jq -r '.prerelease // false' <<<"$gh_release")"
    local gh_release_id
    gh_release_id="$(jq -r '.id' <<<"$gh_release")"

    # Check if release exists on destination
    local dest_release
    dest_release="$(jq -r --arg tag "$tag_name" '.[$tag] // empty' <<<"$dest_by_tag")"

    if [[ -z "$dest_release" ]]; then
      # Create new release on destination
      log "    Creating release: $tag_name"
      local new_release
      if ! new_release="$(create_dest_release "$repo_name" "$tag_name" "$name" "$body" "$prerelease")"; then
        return 1
      fi

      local new_dest_release_id
      new_dest_release_id="$(jq -r '.id' <<<"$new_release")"

      # Sync assets (if supported)
      if [[ "$DEST_SUPPORTS_ASSETS" == "true" && "${SYNC_RELEASE_ASSETS:-true}" == "true" ]]; then
        if ! sync_release_assets "$owner" "$repo_name" "$gh_release_id" "$repo_name" "$new_dest_release_id"; then
          err "    Failed to sync assets for release $tag_name"
          # Continue, don't fail the whole sync
        fi
      fi

      created=$((created + 1))
    else
      # Update existing release
      local dest_release_id
      dest_release_id="$(jq -r '.id' <<<"$dest_release")"
      local dest_name
      dest_name="$(jq -r '.name // ""' <<<"$dest_release")"
      local dest_body
      dest_body="$(jq -r '.body // ""' <<<"$dest_release")"
      local dest_prerelease
      dest_prerelease="$(jq -r '.prerelease // false' <<<"$dest_release")"

      # Check if update is needed
      local needs_update=false
      [[ "$name" != "$dest_name" ]] && needs_update=true
      [[ "$body" != "$dest_body" ]] && needs_update=true
      [[ "$prerelease" != "$dest_prerelease" ]] && needs_update=true

      if [[ "$needs_update" == "true" ]]; then
        log "    Updating release: $tag_name"
        if ! update_dest_release "$repo_name" "$dest_release_id" "$name" "$body" "$prerelease"; then
          return 1
        fi
        updated=$((updated + 1))
      else
        log "    Release $tag_name already up to date"
      fi

      # Sync assets (if supported)
      if [[ "$DEST_SUPPORTS_ASSETS" == "true" && "${SYNC_RELEASE_ASSETS:-true}" == "true" ]]; then
        if ! sync_release_assets "$owner" "$repo_name" "$gh_release_id" "$repo_name" "$dest_release_id"; then
          err "    Failed to sync assets for release $tag_name"
        fi
      fi
    fi

    # Mark this tag as processed
    dest_by_tag="$(jq --arg tag "$tag_name" 'del(.[$tag])' <<<"$dest_by_tag")"
  done < <(jq -c '.[]' <<<"$gh_releases")

  # Second pass: delete orphaned releases on destination
  # dest_by_tag now contains only releases not on GitHub
  local orphan_count
  orphan_count="$(jq 'length' <<<"$dest_by_tag")"

  if [[ "$orphan_count" -gt 0 ]]; then
    log "    Deleting $orphan_count orphaned releases from ${DEST_NAME}..."

    for tag_name in $(jq -r 'keys[]' <<<"$dest_by_tag"); do
      local dest_release
      dest_release="$(jq -r --arg tag "$tag_name" '.[$tag]' <<<"$dest_by_tag")"
      local dest_release_id
      dest_release_id="$(jq -r '.id' <<<"$dest_release")"

      log "    Deleting orphaned release: $tag_name"
      if ! delete_dest_release "$repo_name" "$dest_release_id"; then
        return 1
      fi
      deleted=$((deleted + 1))
    done
  fi

  log "    Release sync complete: $created created, $updated updated, $deleted deleted"
  return 0
}

# ---------------------------------------------------------------------------
# Sync a single repository to a single destination
# ---------------------------------------------------------------------------
# Sets DEST_* variables via load_dest_profile before calling.
# $1: repo_json (JSON object from the GitHub repo list)
# $2: mirror_dir (path to the already-cloned mirror)
sync_repo_to_dest() {
  local repo_json="$1" mirror_dir="$2"

  local name
  name="$(jq -r '.name' <<<"$repo_json")"
  local name_with_owner
  name_with_owner="$(jq -r '.nameWithOwner' <<<"$repo_json")"
  local is_private
  is_private="$(jq -r '.isPrivate' <<<"$repo_json")"
  local is_archived
  is_archived="$(jq -r '.isArchived' <<<"$repo_json")"
  local description
  description="$(jq -r '.description // ""' <<<"$repo_json")"

  log "  [$DEST_NAME] Syncing $name..."

  # --- 1. Check / create the repository on destination -------------------
  local status
  status="$(dest_http_status GET "${DEST_API}/repos/${DEST_USER}/${name}")"
  local dest_archived="false"
  local needs_description_update=0

  if [[ "$status" == "200" ]]; then
    local body
    body="$(cat "$WORKDIR/resp_body.json")"
    if [[ "$DEST_SUPPORTS_ARCHIVE" == "true" ]]; then
      dest_archived="$(jq -r '.archived' <<<"$body")"
    fi
    local dest_description
    dest_description="$(jq -r '.description // ""' <<<"$body")"
    log "  [$DEST_NAME] repository already exists$( [[ "$DEST_SUPPORTS_ARCHIVE" == "true" ]] && echo ", archived=$dest_archived")."
    [[ "$dest_description" != "$description" ]] && needs_description_update=1
  elif [[ "$status" == "404" ]]; then
    log "  [$DEST_NAME] repository missing, creating..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  [$DEST_NAME] [dry-run] creation skipped."
    else
      local create_status
      create_status="$(create_repo "$name" "$is_private" "$description")"
      if [[ "$create_status" != "201" ]]; then
        local body
        body="$(cat "$WORKDIR/resp_body.json")"
        err "  [$DEST_NAME] Failed to create (HTTP $create_status): $(redact "$body")"
        return 1
      fi
      log "  [$DEST_NAME] repository created."
    fi
  else
    local body
    body="$(cat "$WORKDIR/resp_body.json")"
    err "  [$DEST_NAME] Unable to check (HTTP $status): $(redact "$body")"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$DEST_SUPPORTS_ARCHIVE" == "true" && "$dest_archived" == "true" ]]; then
      log "  [$DEST_NAME] [dry-run] temporary unarchiving skipped."
    fi
    [[ "$needs_description_update" -eq 1 ]] && log "  [$DEST_NAME] [dry-run] description update skipped."
    log "  [$DEST_NAME] [dry-run] push skipped."
    if [[ "$DEST_SUPPORTS_ARCHIVE" == "true" && "$is_archived" == "true" ]]; then
      log "  [$DEST_NAME] [dry-run] re-archiving skipped."
    fi
    [[ "${SYNC_RELEASES:-true}" == "true" ]] && log "  [$DEST_NAME] [dry-run] release sync skipped."
    return 0
  fi

  # --- 1b. Update the description if it differs -------------------------
  if [[ "$needs_description_update" -eq 1 ]]; then
    log "  [$DEST_NAME] description differs, updating..."
    local description_status
    description_status="$(patch_description "$name" "$description")"
    if [[ "$description_status" != "200" ]]; then
      local body
      body="$(cat "$WORKDIR/resp_body.json")"
      err "  [$DEST_NAME] Failed to update description (HTTP $description_status): $(redact "$body")"
      return 1
    fi
  fi

  # --- 2. Unarchive if needed, to allow the update ----------------------
  if [[ "$DEST_SUPPORTS_ARCHIVE" == "true" && "$dest_archived" == "true" ]]; then
    log "  [$DEST_NAME] repository archived, temporarily unarchiving..."
    local unarchive_status
    unarchive_status="$(patch_archived "$name" false)"
    if [[ "$unarchive_status" != "200" ]]; then
      local body
      body="$(cat "$WORKDIR/resp_body.json")"
      err "  [$DEST_NAME] Failed to unarchive (HTTP $unarchive_status): $(redact "$body")"
      return 1
    fi
  fi

  # --- 3. Mirror push to destination ------------------------------------
  # Deliberately restricted to branches and tags (refs/heads/*, refs/tags/*)
  # rather than a raw --mirror: GitHub exposes internal refs besides
  # branches/tags (refs/pull/*/head, etc.) that the destination rejects
  # ("hidden ref"), and a true --mirror would also try to delete on the
  # destination side any ref missing from the source. --prune here only
  # applies to these two ref namespaces, so it faithfully syncs
  # branches/tags without touching anything else.
  local push_url
  push_url="https://${DEST_USER}:${DEST_TOKEN}@${DEST_GIT_HOST}/${DEST_USER}/${name}.git"
  log "  [$DEST_NAME] Mirror pushing (branches + tags)..."
  local push_out
  if ! push_out="$(git -C "$mirror_dir" push --prune --quiet "$push_url" \
        '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>&1)"; then
    err "  [$DEST_NAME] Push failed: $(redact "$push_out")"
    return 1
  fi

  # --- 3b. Sync releases if enabled -------------------------------------
  if [[ "${SYNC_RELEASES:-true}" == "true" ]]; then
    local owner
    owner="$(jq -r '.nameWithOwner' <<<"$repo_json" | cut -d/ -f1)"
    if ! sync_releases "$name" "$owner"; then
      err "  [$DEST_NAME] Release sync failed for $name_with_owner"
      return 1
    fi
  fi

  # --- 4. Re-archive if the GitHub repository is archived ----------------
  if [[ "$DEST_SUPPORTS_ARCHIVE" == "true" && "$is_archived" == "true" ]]; then
    log "  [$DEST_NAME] GitHub repository archived, re-archiving..."
    local archive_status
    archive_status="$(patch_archived "$name" true)"
    if [[ "$archive_status" != "200" ]]; then
      local body
      body="$(cat "$WORKDIR/resp_body.json")"
      err "  [$DEST_NAME] Failed to re-archive (HTTP $archive_status): $(redact "$body")"
      return 1
    fi
  fi

  log "  [$DEST_NAME] OK."
  return 0
}

# ---------------------------------------------------------------------------
# Process repositories one by one
# ---------------------------------------------------------------------------
successes=0
failures=()

index=0
while IFS= read -r repo_json; do
  index=$((index + 1))
  name="$(jq -r '.name' <<<"$repo_json")"
  name_with_owner="$(jq -r '.nameWithOwner' <<<"$repo_json")"
  is_private="$(jq -r '.isPrivate' <<<"$repo_json")"
  is_archived="$(jq -r '.isArchived' <<<"$repo_json")"

  log ""
  log "[$index/$total] $name_with_owner (private=$is_private, archived=$is_archived)"

  # --- Clone from GitHub once (shared across all destinations) ----------
  mirror_dir="$WORKDIR/$name.git"
  clone_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${name_with_owner}.git"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] clone from GitHub skipped."
  else
    log "  Mirror cloning from GitHub..."
    clone_out=""
    if ! clone_out="$(git clone --mirror --quiet "$clone_url" "$mirror_dir" 2>&1)"; then
      err "  Clone failed: $(redact "$clone_out")"
      failures+=("$name_with_owner (GitHub clone)")
      continue
    fi
  fi

  # --- Sync to each destination -------------------------------------------
  repo_failed=0
  for dest in "${DESTS[@]}"; do
    load_dest_profile "$dest"

    if ! sync_repo_to_dest "$repo_json" "$mirror_dir"; then
      failures+=("$name_with_owner ($DEST_NAME)")
      repo_failed=1
    fi
  done

  # Clean up the mirror clone
  rm -rf "$mirror_dir"

  if [[ "$repo_failed" -eq 0 ]]; then
    successes=$((successes + 1))
  fi
done < <(jq -c '.[]' <<<"$filtered_json")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "=================== Summary ==================="
log "Successes: $successes / $total"
log "Destinations: ${DESTS[*]}"
if [[ "${#failures[@]}" -gt 0 ]]; then
  log "Failures: ${#failures[@]}"
  for f in "${failures[@]}"; do
    log "  - $f"
  done
  exit 1
fi

log "All repositories were synchronized successfully."
