#!/usr/bin/env bash
#
# Recursively walks a directory looking for Git repositories whose "origin"
# remote points to a GitHub repository owned by a Github user, and adds an extra
# push URL pointing to the corresponding Codeberg mirror, so that
# `git push` pushes to both GitHub and Codeberg.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

DRY_RUN=0
ROOT="."

usage() {
    cat <<EOF
Usage: $(basename "$0") [-n|--dry-run] [directory]

Recursively walks the given directory (defaults to the current directory)
looking for Git repositories whose "origin" remote points to
git@github.com:\${GITHUB_USER}/<repo>.git, and configures an extra push URL
pointing to the corresponding Codeberg mirror:
ssh://git@codeberg.org/\${GITHUB_USER}/<repo>.git

GITHUB_USER is read from .env (see .env.example).

Options:
  -n, --dry-run   Show the actions without executing them
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
        *) ROOT="$1"; shift ;;
    esac
done

if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/../.env"
    set +a
fi

if [[ -z "${GITHUB_USER:-}" ]]; then
    echo "Missing variable 'GITHUB_USER'. Copy .env.example to .env and fill it in." >&2
    exit 1
fi

if [[ ! -d "$ROOT" ]]; then
    echo "Directory not found: $ROOT" >&2
    exit 1
fi

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [dry-run] $*"
    else
        echo "  + $*"
        "$@"
    fi
}

repo_count=0

while IFS= read -r -d '' gitdir; do
    repo_dir="$(dirname "$gitdir")"

    origin_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
    [[ -z "$origin_url" ]] && continue

    if [[ "$origin_url" =~ ^git@github\.com:${GITHUB_USER}/(.+)\.git$ ]]; then
        repo_name="${BASH_REMATCH[1]}"
        github_push_url="git@github.com:${GITHUB_USER}/${repo_name}.git"
        codeberg_push_url="ssh://git@codeberg.org/${GITHUB_USER}/${repo_name}.git"

        echo "Repository: $repo_dir (origin: $origin_url)"
        repo_count=$((repo_count + 1))

        # Reads the config directly (unlike `git remote get-url --push`,
        # which falls back to the fetch URL as long as no explicit pushurl
        # is configured), to know whether the push URLs have already been added.
        existing_push_urls="$(git -C "$repo_dir" config --get-all remote.origin.pushurl 2>/dev/null || true)"

        if ! grep -qxF "$github_push_url" <<< "$existing_push_urls"; then
            run git -C "$repo_dir" remote set-url --add --push origin "$github_push_url"
        else
            echo "  = GitHub push already configured"
        fi

        if ! grep -qxF "$codeberg_push_url" <<< "$existing_push_urls"; then
            run git -C "$repo_dir" remote set-url --add --push origin "$codeberg_push_url"
        else
            echo "  = Codeberg push already configured"
        fi
    fi
done < <(find "$ROOT" \( -name node_modules -o -name vendor \) -prune -o \( -name .git -print0 -prune \))

echo "Done. $repo_count GitHub $GITHUB_USER repo(s) processed."
