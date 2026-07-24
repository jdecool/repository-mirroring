#!/usr/bin/env bash
#
# sync-github-to-codeberg.sh
#
# Fetches all of your personal GitHub repositories (excluding forks and
# organization repositories) and replicates them to Codeberg (Forgejo):
# creates the remote repository if it doesn't exist, then a full mirror
# (branches + tags) via `git clone --mirror` / `git push --mirror`.
# The repository description is copied at creation time, and kept in sync
# (via PATCH) whenever it differs from the GitHub one.
# If the GitHub repository is archived, the Codeberg repository is
# unarchived for the duration of the update and re-archived afterward; if
# it is already archived on the Codeberg side, it is always unarchived
# before syncing (otherwise the push fails).
#
# Releases are also synchronized: GitHub releases (metadata and assets)
# are replicated to Codeberg, with draft releases skipped and orphaned
# Codeberg releases deleted. This can be controlled via SYNC_RELEASES and
# SYNC_RELEASE_ASSETS environment variables.
#
# Usage:
#   ./sync-github-to-codeberg.sh [--dry-run] [--limit N] [--repo owner/repo]...
#
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

CODEBERG_API="${CODEBERG_API:-https://codeberg.org/api/v1}"

# Release sync configuration (defaults: both enabled)
SYNC_RELEASES="${SYNC_RELEASES:-true}"
SYNC_RELEASE_ASSETS="${SYNC_RELEASE_ASSETS:-true}"

log()  { printf '%s\n' "$*"; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

missing_config=0
for var in CODEBERG_TOKEN CODEBERG_USER; do
  if [[ -z "${!var:-}" ]]; then
    err "Missing variable '$var'. Copy .env.example to .env and fill it in."
    missing_config=1
  fi
done
[[ "$missing_config" -eq 1 ]] && exit 1

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
  sed -e "s#${GITHUB_TOKEN}#***#g" -e "s#${CODEBERG_TOKEN}#***#g" <<<"$1"
}

# ---------------------------------------------------------------------------
# Temporary working directory
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh2codeberg.XXXXXX")"
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

log "→ $total repo(s) to process."
[[ "$DRY_RUN" -eq 1 ]] && log "(--dry-run mode: no changes will be made)"

# ---------------------------------------------------------------------------
# Process repositories one by one
# ---------------------------------------------------------------------------
successes=0
failures=()

http_status() {
  # $1: method, $2: url, rest: additional curl args
  local method="$1" url="$2"
  shift 2
  curl -s -o "$WORKDIR/resp_body.json" -w '%{http_code}' \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -X "$method" "$@" "$url"
}

patch_archived() {
  # $1: repo name, $2: "true" or "false"
  local name="$1" archived="$2"
  http_status PATCH "$CODEBERG_API/repos/$CODEBERG_USER/$name" \
    -H 'Content-Type: application/json' \
    -d "{\"archived\":$archived}"
}

patch_description() {
  # $1: repo name, $2: description
  local name="$1" description="$2" payload
  payload="$(jq -n --arg description "$description" '{description: $description}')"
  http_status PATCH "$CODEBERG_API/repos/$CODEBERG_USER/$name" \
    -H 'Content-Type: application/json' \
    -d "$payload"
}

# ---------------------------------------------------------------------------
# API Helper Functions
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

# Generic Codeberg API caller (returns HTTP status code)
# Usage: cb_api_status GET /repos/user/repo/releases
#        cb_api_status POST /repos/user/repo/releases -d '{"tag_name":"v1"}'
cb_api_status() {
  local method="$1" path="$2"
  shift 2
  curl -s -o "$WORKDIR/cb_resp_body.json" -w '%{http_code}' \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    -X "$method" "$CODEBERG_API${path}" "$@"
}

# Codeberg API caller that returns JSON body
# Usage: cb_api GET /repos/user/repo/releases
cb_api() {
  local method="$1" path="$2"
  shift 2
  local status
  status="$(cb_api_status "$method" "$path" "$@")"
  if [[ "$status" != "200" && "$status" != "201" && "$status" != "204" ]]; then
    return 1
  fi
  cat "$WORKDIR/cb_resp_body.json"
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
    
    # Check for errors
    if [[ -z "$response" ]]; then
      err "Failed to fetch GitHub releases for ${owner}/${repo}"
      return 1
    fi
    
    # Check for rate limiting
    local rate_remaining
    rate_remaining="$(jq -r '.message' <<<"$response" 2>/dev/null || true)"
    if [[ "$rate_remaining" == *"rate limit"* ]]; then
      err "GitHub rate limit exceeded: $rate_remaining"
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

# Fetch all releases from Codeberg for a repository
# Returns JSON array of releases
fetch_codeberg_releases() {
  local repo_name="$1"
  local page=1
  local all_releases="[]"
  local per_page=100

  while true; do
    local status
    status="$(cb_api_status GET "/repos/${CODEBERG_USER}/${repo_name}/releases?per_page=${per_page}&page=${page}")"
    
    if [[ "$status" == "200" ]]; then
      local page_releases
      page_releases="$(cat "$WORKDIR/cb_resp_body.json")"
      all_releases="$(jq --argjson existing "$all_releases" --argjson new "$page_releases" '$existing + $new' <<<"$all_releases")"
      
      # Check for pagination in Link header (Forgejo may not support it, but be safe)
      # For now, just check if we got fewer than per_page items
      local count
      count="$(jq 'length' <<<"$page_releases")"
      if [[ "$count" -lt "$per_page" ]]; then
        break
      fi
      page=$((page + 1))
    else
      # No releases or error - return what we have
      break
    fi
  done
  
  echo "$all_releases"
}

# Create a release on Codeberg
# $1: repo_name, $2: tag_name, $3: name, $4: body, $5: prerelease (true/false)
# Returns the created release JSON or empty on error
create_codeberg_release() {
  local repo_name="$1" tag_name="$2" name="$3" body="$4" prerelease="$5"
  
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] Would create Codeberg release: tag=$tag_name name=$name"
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
  status="$(cb_api_status POST "/repos/${CODEBERG_USER}/${repo_name}/releases" \
    -H 'Content-Type: application/json' \
    -d "$payload")"
  
  if [[ "$status" == "201" ]]; then
    cat "$WORKDIR/cb_resp_body.json"
    return 0
  else
    err "  Failed to create Codeberg release (HTTP $status): $(cat "$WORKDIR/cb_resp_body.json")"
    return 1
  fi
}

# Update a release on Codeberg
# $1: repo_name, $2: release_id, $3: name, $4: body, $5: prerelease (true/false)
# Returns 0 on success, 1 on error
update_codeberg_release() {
  local repo_name="$1" release_id="$2" name="$3" body="$4" prerelease="$5"
  
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] Would update Codeberg release $release_id: name=$name"
    return 0
  fi
  
  local payload
  payload="$(jq -n \
    --arg name "$name" \
    --arg body "$body" \
    --argjson prerelease "$prerelease" \
    '{name: $name, body: $body, prerelease: $prerelease}')"
  
  local status
  status="$(cb_api_status PATCH "/repos/${CODEBERG_USER}/${repo_name}/releases/${release_id}" \
    -H 'Content-Type: application/json' \
    -d "$payload")"
  
  if [[ "$status" == "200" ]]; then
    return 0
  else
    err "  Failed to update Codeberg release $release_id (HTTP $status): $(cat "$WORKDIR/cb_resp_body.json")"
    return 1
  fi
}

# Delete a release on Codeberg
# $1: repo_name, $2: release_id
# Returns 0 on success, 1 on error
delete_codeberg_release() {
  local repo_name="$1" release_id="$2"
  
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] Would delete Codeberg release $release_id"
    return 0
  fi
  
  local status
  status="$(cb_api_status DELETE "/repos/${CODEBERG_USER}/${repo_name}/releases/${release_id}")"
  
  if [[ "$status" == "204" ]]; then
    return 0
  else
    err "  Failed to delete Codeberg release $release_id (HTTP $status): $(cat "$WORKDIR/cb_resp_body.json")"
    return 1
  fi
}

# Enable releases feature on Codeberg repository
# $1: repo_name
# Returns 0 on success, 1 on error
ensure_releases_enabled() {
  local repo_name="$1"
  
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] Would check/enable releases feature"
    return 0
  fi
  
  # Check current repository features
  local status
  status="$(cb_api_status GET "/repos/${CODEBERG_USER}/${repo_name}")"
  
  if [[ "$status" != "200" ]]; then
    err "  Failed to check Codeberg repository (HTTP $status): $(cat "$WORKDIR/cb_resp_body.json")"
    return 1
  fi
  
  local has_releases
  has_releases="$(jq -r '.has_releases // false' <<<"$(cat "$WORKDIR/cb_resp_body.json")")"
  
  if [[ "$has_releases" == "true" ]]; then
    return 0
  fi
  
  log "  Enabling releases feature on Codeberg repository..."
  
  local payload
  payload="$(jq -n '{has_releases: true}')"
  
  status="$(cb_api_status PATCH "/repos/${CODEBERG_USER}/${repo_name}" \
    -H 'Content-Type: application/json' \
    -d "$payload")"
  
  if [[ "$status" == "200" ]]; then
    log "  Releases feature enabled on Codeberg"
    return 0
  else
    err "  Failed to enable releases feature (HTTP $status): $(cat "$WORKDIR/cb_resp_body.json")"
    return 1
  fi
}

# Sync assets for a release
# $1: gh_owner, $2: gh_repo, $3: gh_release_id, $4: cb_repo, $5: cb_release_id
sync_release_assets() {
  local gh_owner="$1" gh_repo="$2" gh_release_id="$3"
  local cb_repo="$4" cb_release_id="$5"
  
  if [[ "${SYNC_RELEASE_ASSETS:-true}" != "true" ]]; then
    log "  Asset sync disabled, skipping"
    return 0
  fi
  
  log "  Syncing assets for release..."
  
  # Fetch GitHub assets
  local gh_assets
  gh_assets="$(gh_api GET "/repos/${gh_owner}/${gh_repo}/releases/${gh_release_id}/assets")"
  
  if [[ -z "$gh_assets" || "$gh_assets" == "[]" ]]; then
    log "  No GitHub assets to sync"
    # Check if Codeberg has assets to delete
    local cb_assets
    cb_assets="$(cb_api GET "/repos/${CODEBERG_USER}/${cb_repo}/releases/${cb_release_id}/assets" 2>/dev/null || echo "[]")"
    
    if [[ "$cb_assets" != "[]" ]]; then
      local cb_asset_count
      cb_asset_count="$(jq 'length' <<<"$cb_assets")"
      log "  Deleting $cb_asset_count orphaned assets from Codeberg..."
      
      local asset_ids
      asset_ids="$(jq -r '.[].id' <<<"$cb_assets")"
      
      for asset_id in $asset_ids; do
        if ! delete_codeberg_release_asset "$cb_repo" "$asset_id"; then
          return 1
        fi
      done
    fi
    return 0
  fi
  
  # Fetch Codeberg assets
  local cb_assets
  cb_assets="$(cb_api GET "/repos/${CODEBERG_USER}/${cb_repo}/releases/${cb_release_id}/assets" 2>/dev/null || echo "[]")"
  
  # Build map of Codeberg assets by name
  local cb_asset_names
  cb_asset_names="$(jq -r '[.[].name] | unique | .[]' <<<"$cb_assets" 2>/dev/null || echo "")"
  
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
    local gh_asset_url
    gh_asset_url="$(jq -r '.url' <<<"$gh_asset")"
    
    # Check if asset exists on Codeberg
    if grep -qxF "$gh_asset_name" <<<"$cb_asset_names" 2>/dev/null; then
      log "  Asset '$gh_asset_name' already exists on Codeberg, skipping"
    else
      log "  Uploading asset '$gh_asset_name' to Codeberg..."
      
      # Download from GitHub
      local temp_file="$WORKDIR/asset_${gh_asset_id}_${gh_asset_name}"
      if ! download_github_asset "$gh_owner" "$gh_repo" "$gh_asset_id" "$temp_file"; then
        err "  Failed to download asset '$gh_asset_name'"
        return 1
      fi
      
      # Upload to Codeberg
      if ! upload_codeberg_asset "$cb_repo" "$cb_release_id" "$gh_asset_name" "$temp_file"; then
        rm -f "$temp_file"
        return 1
      fi
      
      rm -f "$temp_file"
    fi
    
    processed=$((processed + 1))
  done < <(jq -c '.[]' <<<"$gh_assets")
  
  # Delete orphaned Codeberg assets (those not on GitHub)
  while IFS= read -r cb_asset; do
    if [[ -z "$cb_asset" ]]; then continue; fi
    
    local cb_asset_name
    cb_asset_name="$(jq -r '.name' <<<"$cb_asset")"
    local cb_asset_id
    cb_asset_id="$(jq -r '.id' <<<"$cb_asset")"
    
    # Check if this asset exists on GitHub
    if ! jq -e --arg name "$cb_asset_name" 'any(.[]; .name == $name)' <<<"$gh_assets" >/dev/null 2>&1; then
      log "  Deleting orphaned asset '$cb_asset_name' from Codeberg..."
      if ! delete_codeberg_release_asset "$cb_repo" "$cb_asset_id"; then
        return 1
      fi
    fi
  done < <(jq -c '.[]' <<<"$cb_assets")
  
  return 0
}

# Download a release asset from GitHub
# $1: owner, $2: repo, $3: asset_id, $4: output_file
download_github_asset() {
  local owner="$1" repo="$2" asset_id="$3" output_file="$4"
  
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] Would download asset $asset_id to $output_file"
    touch "$output_file"
    return 0
  fi
  
  # Use the GitHub API to get the download URL
  local asset_info
  asset_info="$(gh_api GET "/repos/${owner}/${repo}/releases/assets/${asset_id}")"
  
  if [[ -z "$asset_info" ]]; then
    err "  Failed to get asset info from GitHub"
    return 1
  fi
  
  local download_url
  download_url="$(jq -r '.browser_download_url' <<<"$asset_info")"
  
  if [[ "$download_url" == "null" || -z "$download_url" ]]; then
    err "  No download URL for asset $asset_id"
    return 1
  fi
  
  # Download with authentication
  local status
  status="$(curl -s -w '%{http_code}' -L \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    -o "$output_file" \
    "$download_url")"
  
  if [[ "$status" != "200" ]]; then
    rm -f "$output_file"
    err "  Failed to download asset (HTTP $status)"
    return 1
  fi
  
  return 0
}

# Upload a release asset to Codeberg
# $1: repo_name, $2: release_id, $3: asset_name, $4: file_path
upload_codeberg_asset() {
  local repo_name="$1" release_id="$2" asset_name="$3" file_path="$4"
  
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] Would upload asset '$asset_name' to Codeberg"
    return 0
  fi
  
  local encoded_name url status fallback_status
  encoded_name="$(jq -rn --arg n "$asset_name" '$n|@uri')"
  url="${CODEBERG_API}/repos/${CODEBERG_USER}/${repo_name}/releases/${release_id}/assets?name=${encoded_name}"

  # Forgejo accepts a raw octet-stream body when the name is given as a query parameter.
  status="$(curl -s -o "$WORKDIR/cb_resp_body.json" -w '%{http_code}' \
    -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${file_path}" \
    "$url")"

  if [[ "$status" == "201" || "$status" == "200" ]]; then
    return 0
  fi

  # Fallback for older Forgejo versions that only accept multipart/form-data.
  fallback_status="$(curl -s -o "$WORKDIR/cb_resp_body.json" -w '%{http_code}' \
    -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -F "attachment=@${file_path};filename=${asset_name}" \
    "$url")"

  if [[ "$fallback_status" == "201" || "$fallback_status" == "200" ]]; then
    return 0
  fi

  err "  Failed to upload asset '$asset_name' (HTTP $status, fallback HTTP $fallback_status): $(redact "$(cat "$WORKDIR/cb_resp_body.json")")"
  return 1
}

# Delete a release asset from Codeberg
# $1: repo_name, $2: asset_id
delete_codeberg_release_asset() {
  local repo_name="$1" asset_id="$2"
  
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] Would delete Codeberg asset $asset_id"
    return 0
  fi
  
  local status
  status="$(cb_api_status DELETE "/repos/${CODEBERG_USER}/${repo_name}/releases/assets/${asset_id}")"
  
  if [[ "$status" == "204" ]]; then
    return 0
  else
    err "  Failed to delete Codeberg asset $asset_id (HTTP $status): $(cat "$WORKDIR/cb_resp_body.json")"
    return 1
  fi
}

# Main release sync function
# $1: repo_name, $2: owner
sync_releases() {
  local repo_name="$1" owner="$2"
  
  log "  Syncing releases..."
  
  # Ensure releases feature is enabled on Codeberg
  if ! ensure_releases_enabled "$repo_name"; then
    err "  Cannot sync releases: releases feature not available on Codeberg"
    return 1
  fi
  
  # Fetch GitHub releases (published only)
  local gh_releases
  if ! gh_releases="$(fetch_github_releases "$owner" "$repo_name")"; then
    err "  Failed to fetch GitHub releases"
    return 1
  fi
  
  # Fetch Codeberg releases
  local cb_releases
  cb_releases="$(fetch_codeberg_releases "$repo_name")"
  
  # Build map by tag_name for Codeberg releases
  local cb_by_tag="{}"
  if [[ "$cb_releases" != "[]" ]]; then
    cb_by_tag="$(jq -c 'map({(.tag_name): .}) | add // {}' <<<"$cb_releases")"
  fi
  
  # Process GitHub releases
  local gh_count=0 cb_count=0 created=0 updated=0 deleted=0
  gh_count="$(jq 'length' <<<"$gh_releases")"
  cb_count="$(jq 'length' <<<"$cb_releases")"
  
  log "  GitHub: $gh_count published releases, Codeberg: $cb_count releases"
  
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
    
    # Check if release exists on Codeberg
    local cb_release
    cb_release="$(jq -r --arg tag "$tag_name" '.[$tag] // empty' <<<"$cb_by_tag")"
    
    if [[ -z "$cb_release" ]]; then
      # Create new release on Codeberg
      log "  Creating release: $tag_name"
      local new_release
      if ! new_release="$(create_codeberg_release "$repo_name" "$tag_name" "$name" "$body" "$prerelease")"; then
        return 1
      fi
      
      local new_cb_release_id
      new_cb_release_id="$(jq -r '.id' <<<"$new_release")"
      
      # Sync assets
      if [[ "${SYNC_RELEASE_ASSETS:-true}" == "true" ]]; then
        if ! sync_release_assets "$owner" "$repo_name" "$gh_release_id" "$repo_name" "$new_cb_release_id"; then
          err "  Failed to sync assets for release $tag_name"
          # Continue, don't fail the whole sync
        fi
      fi
      
      created=$((created + 1))
    else
      # Update existing release
      local cb_release_id
      cb_release_id="$(jq -r '.id' <<<"$cb_release")"
      local cb_name
      cb_name="$(jq -r '.name // ""' <<<"$cb_release")"
      local cb_body
      cb_body="$(jq -r '.body // ""' <<<"$cb_release")"
      local cb_prerelease
      cb_prerelease="$(jq -r '.prerelease // false' <<<"$cb_release")"
      
      # Check if update is needed
      local needs_update=false
      [[ "$name" != "$cb_name" ]] && needs_update=true
      [[ "$body" != "$cb_body" ]] && needs_update=true
      [[ "$prerelease" != "$cb_prerelease" ]] && needs_update=true
      
      if [[ "$needs_update" == "true" ]]; then
        log "  Updating release: $tag_name"
        if ! update_codeberg_release "$repo_name" "$cb_release_id" "$name" "$body" "$prerelease"; then
          return 1
        fi
        updated=$((updated + 1))
      else
        log "  Release $tag_name already up to date"
      fi
      
      # Sync assets
      if [[ "${SYNC_RELEASE_ASSETS:-true}" == "true" ]]; then
        if ! sync_release_assets "$owner" "$repo_name" "$gh_release_id" "$repo_name" "$cb_release_id"; then
          err "  Failed to sync assets for release $tag_name"
        fi
      fi
    fi
    
    # Mark this tag as processed
    cb_by_tag="$(jq --arg tag "$tag_name" 'del(.[$tag])' <<<"$cb_by_tag")"
  done < <(jq -c '.[]' <<<"$gh_releases")
  
  # Second pass: delete orphaned releases on Codeberg
  # cb_by_tag now contains only releases not on GitHub
  local orphan_count
  orphan_count="$(jq 'length' <<<"$cb_by_tag")"
  
  if [[ "$orphan_count" -gt 0 ]]; then
    log "  Deleting $orphan_count orphaned releases from Codeberg..."
    
    for tag_name in $(jq -r 'keys[]' <<<"$cb_by_tag"); do
      local cb_release
      cb_release="$(jq -r --arg tag "$tag_name" '.[$tag]' <<<"$cb_by_tag")"
      local cb_release_id
      cb_release_id="$(jq -r '.id' <<<"$cb_release")"
      
      log "  Deleting orphaned release: $tag_name"
      if ! delete_codeberg_release "$repo_name" "$cb_release_id"; then
        return 1
      fi
      deleted=$((deleted + 1))
    done
  fi
  
  log "  Release sync complete: $created created, $updated updated, $deleted deleted"
  return 0
}

index=0
while IFS= read -r repo_json; do
  index=$((index + 1))
  name="$(jq -r '.name' <<<"$repo_json")"
  name_with_owner="$(jq -r '.nameWithOwner' <<<"$repo_json")"
  is_private="$(jq -r '.isPrivate' <<<"$repo_json")"
  is_archived="$(jq -r '.isArchived' <<<"$repo_json")"
  description="$(jq -r '.description // ""' <<<"$repo_json")"

  log ""
  log "[$index/$total] $name_with_owner (private=$is_private, archived=$is_archived)"

  # --- 1. Check / create the repository on Codeberg --------------------------
  status="$(http_status GET "$CODEBERG_API/repos/$CODEBERG_USER/$name")"
  codeberg_archived="false"
  needs_description_update=0

  if [[ "$status" == "200" ]]; then
    body="$(cat "$WORKDIR/resp_body.json")"
    codeberg_archived="$(jq -r '.archived' <<<"$body")"
    codeberg_description="$(jq -r '.description // ""' <<<"$body")"
    log "  Codeberg: repository already exists (archived=$codeberg_archived)."
    [[ "$codeberg_description" != "$description" ]] && needs_description_update=1
  elif [[ "$status" == "404" ]]; then
    log "  Codeberg: repository missing, creating..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  [dry-run] creation skipped."
    else
      create_payload="$(jq -n --arg name "$name" --argjson private "$is_private" \
        --arg description "$description" \
        '{name: $name, private: $private, auto_init: false, description: $description}')"
      create_status="$(http_status POST "$CODEBERG_API/user/repos" \
        -H 'Content-Type: application/json' \
        -d "$create_payload")"
      if [[ "$create_status" != "201" ]]; then
        body="$(cat "$WORKDIR/resp_body.json")"
        err "  Failed to create on Codeberg (HTTP $create_status): $(redact "$body")"
        failures+=("$name_with_owner (Codeberg creation)")
        continue
      fi
      log "  Codeberg: repository created."
    fi
  else
    body="$(cat "$WORKDIR/resp_body.json")"
    err "  Unable to check Codeberg (HTTP $status): $(redact "$body")"
    failures+=("$name_with_owner (Codeberg check)")
    continue
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    [[ "$codeberg_archived" == "true" ]] && log "  [dry-run] temporary unarchiving skipped."
    [[ "$needs_description_update" -eq 1 ]] && log "  [dry-run] description update skipped."
    log "  [dry-run] clone/push skipped."
    [[ "$is_archived" == "true" ]] && log "  [dry-run] re-archiving skipped."
    [[ "${SYNC_RELEASES:-true}" == "true" ]] && log "  [dry-run] release sync skipped."
    successes=$((successes + 1))
    continue
  fi

  # --- 1b. Update the description if it differs -------------------------------
  if [[ "$needs_description_update" -eq 1 ]]; then
    log "  Codeberg: description differs, updating..."
    description_status="$(patch_description "$name" "$description")"
    if [[ "$description_status" != "200" ]]; then
      body="$(cat "$WORKDIR/resp_body.json")"
      err "  Failed to update description on Codeberg (HTTP $description_status): $(redact "$body")"
      failures+=("$name_with_owner (Codeberg description update)")
      continue
    fi
  fi

  # --- 2. Unarchive if needed, to allow the update ----------------------------
  if [[ "$codeberg_archived" == "true" ]]; then
    log "  Codeberg: repository archived, temporarily unarchiving..."
    unarchive_status="$(patch_archived "$name" false)"
    if [[ "$unarchive_status" != "200" ]]; then
      body="$(cat "$WORKDIR/resp_body.json")"
      err "  Failed to unarchive on Codeberg (HTTP $unarchive_status): $(redact "$body")"
      failures+=("$name_with_owner (Codeberg unarchiving)")
      continue
    fi
  fi

  # --- 3. Mirror clone from GitHub --------------------------------------------
  mirror_dir="$WORKDIR/$name.git"
  clone_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${name_with_owner}.git"
  log "  Mirror cloning from GitHub..."
  if ! clone_out="$(git clone --mirror --quiet "$clone_url" "$mirror_dir" 2>&1)"; then
    err "  Clone failed: $(redact "$clone_out")"
    failures+=("$name_with_owner (GitHub clone)")
    continue
  fi

  # --- 4. Mirror push to Codeberg ----------------------------------------------
  # Deliberately restricted to branches and tags (refs/heads/*, refs/tags/*)
  # rather than a raw --mirror: GitHub exposes internal refs besides
  # branches/tags (refs/pull/*/head, etc.) that Codeberg rejects ("hidden ref"),
  # and a true --mirror would also try to delete on the Codeberg side any ref
  # missing from the source. --prune here only applies to these two ref
  # namespaces, so it faithfully syncs branches/tags without touching anything else.
  push_url="https://${CODEBERG_USER}:${CODEBERG_TOKEN}@codeberg.org/${CODEBERG_USER}/${name}.git"
  log "  Mirror pushing (branches + tags) to Codeberg..."
  if ! push_out="$(git -C "$mirror_dir" push --prune --quiet "$push_url" \
        '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>&1)"; then
    err "  Push failed: $(redact "$push_out")"
    failures+=("$name_with_owner (Codeberg push)")
    rm -rf "$mirror_dir"
    continue
  fi

  rm -rf "$mirror_dir"

  # --- 4b. Sync releases if enabled ---------------------------------------------
  if [[ "${SYNC_RELEASES:-true}" == "true" ]]; then
    owner="$(jq -r '.nameWithOwner' <<<"$repo_json" | cut -d/ -f1)"
    if ! sync_releases "$name" "$owner"; then
      err "  Release sync failed for $name_with_owner"
      failures+=("$name_with_owner (release sync)")
      continue
    fi
  fi

  # --- 5. Re-archive if the GitHub repository is archived ----------------------
  if [[ "$is_archived" == "true" ]]; then
    log "  Codeberg: GitHub repository archived, re-archiving..."
    archive_status="$(patch_archived "$name" true)"
    if [[ "$archive_status" != "200" ]]; then
      body="$(cat "$WORKDIR/resp_body.json")"
      err "  Failed to re-archive on Codeberg (HTTP $archive_status): $(redact "$body")"
      failures+=("$name_with_owner (Codeberg re-archiving)")
      continue
    fi
  fi

  log "  OK."
  successes=$((successes + 1))
done < <(jq -c '.[]' <<<"$filtered_json")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "=================== Summary ==================="
log "Successes: $successes / $total"
if [[ "${#failures[@]}" -gt 0 ]]; then
  log "Failures: ${#failures[@]}"
  for f in "${failures[@]}"; do
    log "  - $f"
  done
  exit 1
fi

log "All repositories were synchronized successfully."
