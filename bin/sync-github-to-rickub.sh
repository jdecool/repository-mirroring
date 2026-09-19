#!/usr/bin/env bash
#
# sync-github-to-rickub.sh
#
# Fetches all of your personal GitHub repositories (excluding forks and
# organization repositories) and replicates them to rickub: creates the
# remote repository if it doesn't exist, then a full mirror (branches +
# tags) via `git clone --mirror` / `git push`.
# The repository description is copied at creation time, and kept in sync
# (via PATCH) whenever it differs from the GitHub one.
#
# Releases are also synchronized: GitHub release metadata (name, body,
# prerelease flag) is replicated to rickub, with draft releases skipped
# and orphaned rickub releases deleted. This can be controlled via the
# SYNC_RELEASES environment variable.
#
# Usage:
#   ./sync-github-to-rickub.sh [--dry-run] [--limit N] [--repo owner/repo]...
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

RICKUB_API="${RICKUB_API:-https://rickub.com/api/v1}"
RICKUB_GIT_HOST="${RICKUB_GIT_HOST:-git.rickub.com}"

# Release sync configuration (default: enabled)
SYNC_RELEASES="${SYNC_RELEASES:-true}"

log()  { printf '%s\n' "$*"; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

missing_config=0
for var in RICKUB_TOKEN RICKUB_USER; do
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
  sed -e "s#${GITHUB_TOKEN}#***#g" -e "s#${RICKUB_TOKEN}#***#g" <<<"$1"
}

# ---------------------------------------------------------------------------
# Temporary working directory
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh2rickub.XXXXXX")"
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
    -H "Authorization: Bearer ${RICKUB_TOKEN}" \
    -X "$method" "$@" "$url"
}

patch_description() {
  # $1: repo name, $2: description
  local name="$1" description="$2" payload
  payload="$(jq -n --arg description "$description" '{description: $description}')"
  http_status PATCH "$RICKUB_API/repos/$RICKUB_USER/$name" \
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

# Generic rickub API caller (returns HTTP status code)
# Usage: rk_api_status GET /repos/user/repo/releases
#        rk_api_status POST /repos/user/repo/releases -d '{"tag_name":"v1"}'
rk_api_status() {
  local method="$1" path="$2"
  shift 2
  curl -s -o "$WORKDIR/rk_resp_body.json" -w '%{http_code}' \
    -H "Authorization: Bearer ${RICKUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -X "$method" "$RICKUB_API${path}" "$@"
}

# rickub API caller that returns JSON body
# Usage: rk_api GET /repos/user/repo/releases
rk_api() {
  local method="$1" path="$2"
  shift 2
  local status
  status="$(rk_api_status "$method" "$path" "$@")"
  if [[ "$status" != "200" && "$status" != "201" && "$status" != "204" ]]; then
    return 1
  fi
  cat "$WORKDIR/rk_resp_body.json"
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
      err "Failed to fetch GitHub releases for ${owner}/${repo}"
      return 1
    fi

    # Check for rate limiting
    local rate_message
    rate_message="$(jq -r '.message' <<<"$response" 2>/dev/null || true)"
    if [[ "$rate_message" == *"rate limit"* ]]; then
      err "GitHub rate limit exceeded: $rate_message"
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

# Fetch all releases from rickub for a repository
# Returns JSON array of releases
fetch_rickub_releases() {
  local repo_name="$1"
  local page=1
  local all_releases="[]"
  local per_page=50

  while true; do
    local status
    status="$(rk_api_status GET "/repos/${RICKUB_USER}/${repo_name}/releases?per_page=${per_page}&page=${page}")"

    if [[ "$status" == "200" ]]; then
      local page_releases
      page_releases="$(cat "$WORKDIR/rk_resp_body.json")"
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

# Create a release on rickub
# $1: repo_name, $2: tag_name, $3: name, $4: body, $5: prerelease (true/false)
# Returns the created release JSON or empty on error
create_rickub_release() {
  local repo_name="$1" tag_name="$2" name="$3" body="$4" prerelease="$5"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] Would create rickub release: tag=$tag_name name=$name"
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
  status="$(rk_api_status POST "/repos/${RICKUB_USER}/${repo_name}/releases" \
    -H 'Content-Type: application/json' \
    -d "$payload")"

  if [[ "$status" == "201" ]]; then
    cat "$WORKDIR/rk_resp_body.json"
    return 0
  else
    err "  Failed to create rickub release (HTTP $status): $(cat "$WORKDIR/rk_resp_body.json")"
    return 1
  fi
}

# Update a release on rickub
# $1: repo_name, $2: release_id, $3: name, $4: body, $5: prerelease (true/false)
# Returns 0 on success, 1 on error
update_rickub_release() {
  local repo_name="$1" release_id="$2" name="$3" body="$4" prerelease="$5"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] Would update rickub release $release_id: name=$name"
    return 0
  fi

  local payload
  payload="$(jq -n \
    --arg name "$name" \
    --arg body "$body" \
    --argjson prerelease "$prerelease" \
    '{name: $name, body: $body, prerelease: $prerelease}')"

  local status
  status="$(rk_api_status PATCH "/repos/${RICKUB_USER}/${repo_name}/releases/${release_id}" \
    -H 'Content-Type: application/json' \
    -d "$payload")"

  if [[ "$status" == "200" ]]; then
    return 0
  else
    err "  Failed to update rickub release $release_id (HTTP $status): $(cat "$WORKDIR/rk_resp_body.json")"
    return 1
  fi
}

# Delete a release on rickub
# $1: repo_name, $2: release_id
# Returns 0 on success, 1 on error
delete_rickub_release() {
  local repo_name="$1" release_id="$2"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] Would delete rickub release $release_id"
    return 0
  fi

  local status
  status="$(rk_api_status DELETE "/repos/${RICKUB_USER}/${repo_name}/releases/${release_id}")"

  if [[ "$status" == "204" ]]; then
    return 0
  else
    err "  Failed to delete rickub release $release_id (HTTP $status): $(cat "$WORKDIR/rk_resp_body.json")"
    return 1
  fi
}

# Main release sync function
# $1: repo_name, $2: owner
sync_releases() {
  local repo_name="$1" owner="$2"

  log "  Syncing releases..."

  # Fetch GitHub releases (published only)
  local gh_releases
  if ! gh_releases="$(fetch_github_releases "$owner" "$repo_name")"; then
    err "  Failed to fetch GitHub releases"
    return 1
  fi

  # Fetch rickub releases
  local rk_releases
  rk_releases="$(fetch_rickub_releases "$repo_name")"

  # Build map by tag_name for rickub releases
  local rk_by_tag="{}"
  if [[ "$rk_releases" != "[]" ]]; then
    rk_by_tag="$(jq -c 'map({(.tag_name): .}) | add // {}' <<<"$rk_releases")"
  fi

  local gh_count=0 rk_count=0 created=0 updated=0 deleted=0
  gh_count="$(jq 'length' <<<"$gh_releases")"
  rk_count="$(jq 'length' <<<"$rk_releases")"

  log "  GitHub: $gh_count published releases, rickub: $rk_count releases"

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

    # Check if release exists on rickub
    local rk_release
    rk_release="$(jq -r --arg tag "$tag_name" '.[$tag] // empty' <<<"$rk_by_tag")"

    if [[ -z "$rk_release" ]]; then
      log "  Creating release: $tag_name"
      if ! create_rickub_release "$repo_name" "$tag_name" "$name" "$body" "$prerelease"; then
        return 1
      fi
      created=$((created + 1))
    else
      local rk_release_id
      rk_release_id="$(jq -r '.id' <<<"$rk_release")"
      local rk_name
      rk_name="$(jq -r '.name // ""' <<<"$rk_release")"
      local rk_body
      rk_body="$(jq -r '.body // ""' <<<"$rk_release")"
      local rk_prerelease
      rk_prerelease="$(jq -r '.prerelease // false' <<<"$rk_release")"

      local needs_update=false
      [[ "$name" != "$rk_name" ]] && needs_update=true
      [[ "$body" != "$rk_body" ]] && needs_update=true
      [[ "$prerelease" != "$rk_prerelease" ]] && needs_update=true

      if [[ "$needs_update" == "true" ]]; then
        log "  Updating release: $tag_name"
        if ! update_rickub_release "$repo_name" "$rk_release_id" "$name" "$body" "$prerelease"; then
          return 1
        fi
        updated=$((updated + 1))
      else
        log "  Release $tag_name already up to date"
      fi
    fi

    # Mark this tag as processed
    rk_by_tag="$(jq --arg tag "$tag_name" 'del(.[$tag])' <<<"$rk_by_tag")"
  done < <(jq -c '.[]' <<<"$gh_releases")

  # Second pass: delete orphaned releases on rickub
  local orphan_count
  orphan_count="$(jq 'length' <<<"$rk_by_tag")"

  if [[ "$orphan_count" -gt 0 ]]; then
    log "  Deleting $orphan_count orphaned releases from rickub..."

    for tag_name in $(jq -r 'keys[]' <<<"$rk_by_tag"); do
      local rk_release
      rk_release="$(jq -r --arg tag "$tag_name" '.[$tag]' <<<"$rk_by_tag")"
      local rk_release_id
      rk_release_id="$(jq -r '.id' <<<"$rk_release")"

      log "  Deleting orphaned release: $tag_name"
      if ! delete_rickub_release "$repo_name" "$rk_release_id"; then
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
  description="$(jq -r '.description // ""' <<<"$repo_json")"

  # Map GitHub visibility to rickub's string format
  if [[ "$is_private" == "true" ]]; then
    visibility="private"
  else
    visibility="public"
  fi

  log ""
  log "[$index/$total] $name_with_owner (private=$is_private)"

  # --- 1. Check / create the repository on rickub ---------------------------
  status="$(http_status GET "$RICKUB_API/repos/$RICKUB_USER/$name")"
  needs_description_update=0

  if [[ "$status" == "200" ]]; then
    body="$(cat "$WORKDIR/resp_body.json")"
    rickub_description="$(jq -r '.description // ""' <<<"$body")"
    log "  rickub: repository already exists."
    [[ "$rickub_description" != "$description" ]] && needs_description_update=1
  elif [[ "$status" == "404" ]]; then
    log "  rickub: repository missing, creating..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  [dry-run] creation skipped."
    else
      create_payload="$(jq -n \
        --arg name "$name" \
        --arg visibility "$visibility" \
        --arg description "$description" \
        '{name: $name, visibility: $visibility, description: $description}')"
      create_status="$(http_status POST "$RICKUB_API/repos" \
        -H 'Content-Type: application/json' \
        -d "$create_payload")"
      if [[ "$create_status" != "201" ]]; then
        body="$(cat "$WORKDIR/resp_body.json")"
        err "  Failed to create on rickub (HTTP $create_status): $(redact "$body")"
        failures+=("$name_with_owner (rickub creation)")
        continue
      fi
      log "  rickub: repository created."
    fi
  else
    body="$(cat "$WORKDIR/resp_body.json")"
    err "  Unable to check rickub (HTTP $status): $(redact "$body")"
    failures+=("$name_with_owner (rickub check)")
    continue
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    [[ "$needs_description_update" -eq 1 ]] && log "  [dry-run] description update skipped."
    log "  [dry-run] clone/push skipped."
    [[ "${SYNC_RELEASES:-true}" == "true" ]] && log "  [dry-run] release sync skipped."
    successes=$((successes + 1))
    continue
  fi

  # --- 1b. Update the description if it differs ----------------------------
  if [[ "$needs_description_update" -eq 1 ]]; then
    log "  rickub: description differs, updating..."
    description_status="$(patch_description "$name" "$description")"
    if [[ "$description_status" != "200" ]]; then
      body="$(cat "$WORKDIR/resp_body.json")"
      err "  Failed to update description on rickub (HTTP $description_status): $(redact "$body")"
      failures+=("$name_with_owner (rickub description update)")
      continue
    fi
  fi

  # --- 2. Mirror clone from GitHub -----------------------------------------
  mirror_dir="$WORKDIR/$name.git"
  clone_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${name_with_owner}.git"
  log "  Mirror cloning from GitHub..."
  if ! clone_out="$(git clone --mirror --quiet "$clone_url" "$mirror_dir" 2>&1)"; then
    err "  Clone failed: $(redact "$clone_out")"
    failures+=("$name_with_owner (GitHub clone)")
    continue
  fi

  # --- 3. Mirror push to rickub --------------------------------------------
  # Deliberately restricted to branches and tags (refs/heads/*, refs/tags/*)
  # rather than a raw --mirror: GitHub exposes internal refs besides
  # branches/tags (refs/pull/*/head, etc.) that rickub rejects ("hidden ref"),
  # and a true --mirror would also try to delete on the rickub side any ref
  # missing from the source. --prune here only applies to these two ref
  # namespaces, so it faithfully syncs branches/tags without touching anything else.
  push_url="https://${RICKUB_USER}:${RICKUB_TOKEN}@${RICKUB_GIT_HOST}/${RICKUB_USER}/${name}.git"
  log "  Mirror pushing (branches + tags) to rickub..."
  if ! push_out="$(git -C "$mirror_dir" push --prune --quiet "$push_url" \
        '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>&1)"; then
    err "  Push failed: $(redact "$push_out")"
    failures+=("$name_with_owner (rickub push)")
    rm -rf "$mirror_dir"
    continue
  fi

  rm -rf "$mirror_dir"

  # --- 3b. Sync releases if enabled ----------------------------------------
  if [[ "${SYNC_RELEASES:-true}" == "true" ]]; then
    owner="$(jq -r '.nameWithOwner' <<<"$repo_json" | cut -d/ -f1)"
    if ! sync_releases "$name" "$owner"; then
      err "  Release sync failed for $name_with_owner"
      failures+=("$name_with_owner (release sync)")
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
