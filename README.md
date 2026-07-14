# Codeberg mirroring

Bash script to replicate all of your personal GitHub repositories (excluding forks and organization repositories — private and archived ones included) to [Codeberg](https://codeberg.org).

The remote repository is automatically created on Codeberg if it doesn't exist yet, then synchronized via a full Git mirror (all branches + tags).

## Requirements

- [`gh`](https://cli.github.com/) authenticated (`gh auth login`)
- `git`, `curl`, `jq`

## Configuration

```sh
cp .env.example .env
```

Fill in `.env`:

- `CODEBERG_TOKEN` — Codeberg API token with the `repository` scope
  (create one at https://codeberg.org/user/settings/applications)
- `CODEBERG_USER` — your Codeberg username
- `GITHUB_TOKEN` — optional, otherwise the script uses `gh auth token`
- `GITHUB_USER` — your GitHub username (used by `bin/configure-git-remote-mirroring.sh`)

## Usage

```sh
# Dry run, without changing anything
./bin/sync-github-to-codeberg.sh --dry-run

# Real test limited to 2 repositories
./bin/sync-github-to-codeberg.sh --limit 2

# Full synchronization
./bin/sync-github-to-codeberg.sh
```

The script is **re-runnable**: repositories already present on Codeberg are not recreated, only their content is updated (branches + tags).

If a GitHub repository is archived, the corresponding Codeberg repository is unarchived for the duration of the update and re-archived afterward (an archived repository refuses pushes).

If it is already archived on the Codeberg side for another reason, it is also unarchived before syncing.

If one or more repositories fail, the script continues with the remaining ones and prints a final summary (non-zero exit code if any failures occurred).

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
