# GitHub Organization Management Scripts

This directory contains scripts for bulk operations on GitHub organizations. The scripts provide tools for migrating repositories between organizations and performing bulk cleanup operations.

## Script Overview

| Script | Description | Mode |
|--------|-------------|------|
| `gh_org_copy.sh` | Copy organization repositories without forking | Self-update |
| `gh_org_delete_issues.sh` | Bulk close/lock/delete issues across repos | Dry-run default |
| `gh_org_delete_repos.sh` | Bulk delete repositories | Dry-run default |
| `gh_org_copy-backup.sh` | Backup version of org copy script | Legacy |

## Quick Start

### Organization Migration

```bash
# Copy all repositories from OldOrg to NewOrg
SRC_ORG="OldOrg" DST_ORG="NewOrg" ./gh_org_copy.sh

# With custom throttle (seconds between API calls)
SRC_ORG="OldOrg" DST_ORG="NewOrg" THROTTLE=2 ./gh_org_copy.sh
```

### Bulk Issue Management

```bash
# Dry run - see what would be affected
./gh_org_delete_issues.sh MyOrg

# Execute close operations
./gh_org_delete_issues.sh MyOrg --yes

# Close and lock issues
./gh_org_delete_issues.sh MyOrg --yes --lock
```

### Bulk Repository Deletion

```bash
# Dry run - see what would be deleted
./gh_org_delete_repos.sh MyOrg --all

# Delete specific repositories
./gh_org_delete_repos.sh MyOrg repo1 repo2 --yes

# Delete all repositories (PERMANENT!)
./gh_org_delete_repos.sh MyOrg --all --yes
```

## Script Details

### gh_org_copy.sh

Comprehensive organization migration tool that copies repositories without forking:

- Mirrors git refs (branches/tags) and Git LFS objects
- Copies wiki repositories
- Recreates labels and milestones
- Copies issues with comments
- Archives PRs as issues with review comments, reviews, and issue comments
- Copies discussions with comments via GraphQL (best-effort category mapping)
- Self-updating from repository

```bash
SRC_ORG="OldOrg" DST_ORG="NewOrg" ./gh_org_copy.sh
```

**Environment Variables:**

| Variable | Description | Default |
|----------|-------------|---------|
| `SRC_ORG` | Source organization name | Required |
| `DST_ORG` | Destination organization name | Required |
| `WORKDIR` | Working directory for clones | `/tmp/org-copy-...` |
| `THROTTLE` | Seconds between API calls | `1.5` |
| `LABEL_ARCHIVED_PR` | Label for archived PRs | `archived-pr` |

**Required Token Scopes:**

| Scope | Source Org | Dest Org |
|-------|------------|----------|
| `repo` | Yes | Yes |
| `read:discussion` | Yes | - |
| `write:discussion` | - | Yes |
| `admin:org` | - | Yes |

### gh_org_delete_issues.sh

Bulk issue management for closing, locking, and optionally deleting issues across all repositories in an organization.

```bash
./gh_org_delete_issues.sh <org> [options]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--yes` | Execute changes (default is dry-run) |
| `--lock` | Lock issues after closing |
| `--include-archived` | Include archived repositories |
| `--only-open` | Process only open issues |
| `--really-delete` | Attempt GraphQL deletion (requires special permissions) |
| `--match 'regex'` | Only process repos matching pattern |
| `--exclude 'regex'` | Skip repos matching pattern |

**Examples:**

```bash
# Dry run (default)
./gh_org_delete_issues.sh OldCo

# Execute close operations
./gh_org_delete_issues.sh OldCo --yes

# Close and lock
./gh_org_delete_issues.sh OldCo --yes --lock

# Only open issues
./gh_org_delete_issues.sh OldCo --yes --only-open

# Filter by repo pattern
./gh_org_delete_issues.sh OldCo --yes --match '^(svc-|web-)'

# Exclude repos
./gh_org_delete_issues.sh OldCo --yes --exclude '(^infra-|archived-)'
```

### gh_org_delete_repos.sh

Bulk repository deletion tool with safety features.

```bash
./gh_org_delete_repos.sh <org> <repo1> [repo2 ...] [options]
./gh_org_delete_repos.sh <org> --all [options]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--yes` | Execute deletion (default is dry-run) |
| `--all` | Delete all repositories |
| `--include-archived` | Include archived repositories |
| `--match 'regex'` | Only process repos matching pattern |
| `--exclude 'regex'` | Skip repos matching pattern |

**Examples:**

```bash
# Dry run single repo
./gh_org_delete_repos.sh OldCo my-repo

# Delete single repo
./gh_org_delete_repos.sh OldCo my-repo --yes

# Delete multiple repos
./gh_org_delete_repos.sh OldCo repo1 repo2 repo3 --yes

# Dry run all repos
./gh_org_delete_repos.sh OldCo --all

# Delete all repos (PERMANENT!)
./gh_org_delete_repos.sh OldCo --all --yes

# Filter repos
./gh_org_delete_repos.sh OldCo --all --yes --match '^(svc-|web-)'
```

## Common Features

### Self-Update

The main scripts (`gh_org_copy.sh`, `gh_org_delete_issues.sh`, `gh_org_delete_repos.sh`) include self-update functionality:

- Checks for updates from the repository on startup
- Shows diff before updating
- Prompts for confirmation before overwriting
- Restarts automatically after update

### Dry-Run Mode

Deletion scripts default to dry-run mode for safety:

- Shows what would be affected without making changes
- Use `--yes` to execute actual changes
- Always run dry-run first to verify

### Regex Filtering

Repository filtering supports regex patterns:

```bash
# Include only repos starting with 'svc-' or 'web-'
--match '^(svc-|web-)'

# Exclude repos containing 'infra' or 'archived'
--exclude '(infra|archived)'
```

## Dependencies

- **gh** - GitHub CLI (≥ 2.30 for org copy)
- **jq** - JSON processor
- **git** - Version control
- **git-lfs** - Large File Storage (optional, for LFS objects)
- **curl** or **wget** - For self-update functionality

## Authentication

All scripts require GitHub CLI authentication:

```bash
gh auth login
```

Ensure your token has the required scopes for the operations you need to perform.

## Safety Notes

- **Deletion is permanent** - Repository deletion cannot be undone
- **Always dry-run first** - Verify affected items before executing
- **Test with small subset** - For org migration, test with a few repos first
- **Check token scopes** - Ensure proper permissions before running
- **Rate limits** - Scripts include throttling to avoid GitHub API limits
