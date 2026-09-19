# Repository mirroring

Bash scripts to replicate all of your personal GitHub repositories (excluding forks and organization repositories - private and archived ones included) to one or more destinations: [Codeberg](https://codeberg.org), [rickub](https://rickub.com), or any Forgejo-compatible instance.

The remote repository is automatically created on the destination if it doesn't exist yet, then synchronized via a full Git mirror (all branches + tags).

GitHub releases (metadata and assets, where supported) are also synchronized.

## Requirements

- [`gh`](https://cli.github.com/) authenticated (`gh auth login`)
- `git`, `curl`, `jq`

## Configuration

```sh
cp .env.example .env
```

Fill in `.env`:

- `CODEBERG_TOKEN` - Codeberg API token with the `repository` scope
  (create one at https://codeberg.org/user/settings/applications)
- `CODEBERG_USER` - your Codeberg username
- `RICKUB_TOKEN` - rickub personal access token (create one at https://rickub.com/settings/tokens, Full access required)
- `RICKUB_USER` - your rickub username (handle)
- `GITHUB_TOKEN` - optional, otherwise the script uses `gh auth token`
- `GITHUB_USER` - your GitHub username (used by `bin/configure-git-remote-mirroring.sh`)

## Usage

### Sync to one or more destinations

```sh
# Dry run, without changing anything (auto-detects all configured destinations)
./bin/sync-github-repo.sh --dry-run

# Real test limited to 2 repositories
./bin/sync-github-repo.sh --limit 2

# Full synchronization (auto-detects all configured destinations)
./bin/sync-github-repo.sh

# Sync only to Codeberg
./bin/sync-github-repo.sh --dest=codeberg

# Sync to both Codeberg and rickub in a single pass
./bin/sync-github-repo.sh --dest=codeberg --dest=rickub

# Synchronize only specific repositories (can be repeated)
./bin/sync-github-repo.sh --repo owner/repo1 --repo owner/repo2
```

If `--dest` is not specified, the script auto-detects all destinations whose tokens and usernames are present in `.env`.

The script is **re-runnable**: repositories already present on the destination are not recreated, only their content is updated (branches + tags).

If a GitHub repository is archived, the corresponding Codeberg repository is unarchived for the duration of the update and re-archived afterward (an archived repository refuses pushes).

If it is already archived on the Codeberg side for another reason, it is also unarchived before syncing.

The rickub destination does not manage archiving (not supported by the rickub API).

If one or more repositories fail, the script continues with the remaining ones and prints a final summary (non-zero exit code if any failures occurred).

### Release synchronization

GitHub releases are replicated to each destination after the repository's mirror push:

- release metadata (name, body, prerelease flag) is created or updated to match GitHub.
- draft releases are skipped.
- release assets are downloaded from GitHub and re-uploaded to destinations that support it (Codeberg); assets already present (matched by name) are skipped.
- releases present on the destination but no longer on GitHub are deleted, as are their orphaned assets (where supported).

This is controlled via two environment variables in `.env` (both default to `true`):

- `SYNC_RELEASES` - enable/disable release metadata synchronization entirely.
- `SYNC_RELEASE_ASSETS` - enable/disable asset synchronization (has no effect if `SYNC_RELEASES=false`, or for destinations that don't support assets like rickub).

#### Destination-specific notes

| Feature | Codeberg | rickub |
|---|---|---|
| Archive management | yes | no |
| Release assets | yes | no |
| Auth scheme | `token` | `Bearer` |

To add a new destination, add a profile in `load_dest_profile()` inside `bin/sync-github-repo.sh` and the corresponding env vars to `.env.example`.

## Configuring local clones to push to both remotes

Once repositories are mirrored on Codeberg, `bin/configure-git-remote-mirroring.sh` recursively scans a local directory for Git repositories whose `origin` remote points to a GitHub repository owned by `GITHUB_USER` (`git@github.com:${GITHUB_USER}/<repo>.git`, read from `.env`), and adds an extra push URL pointing to the corresponding Codeberg mirror (`ssh://git@codeberg.org/${GITHUB_USER}/<repo>.git`).

Once configured, a single `git push` on `origin` pushes to both GitHub and Codeberg.
`node_modules` and `vendor` directories are skipped during the scan.

```sh
# Show the actions without executing them
./bin/configure-git-remote-mirroring.sh --dry-run [directory]

# Apply the configuration (defaults to the current directory)
./bin/configure-git-remote-mirroring.sh [directory]
```

The script is **re-runnable**: it only adds a push URL if it isn't already configured for the repository.
