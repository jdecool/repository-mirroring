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
