#!/usr/bin/env bash
set -euo pipefail

# Bulk close/lock (and optionally attempt delete) all issues in all repos of an org.
# Requirements:
#   - GitHub CLI (gh) authenticated: `gh auth login`
#   - Token must have admin:repo_hook/repo scope for private repos; public_repo is enough for public
# Usage:
#   ./org-issues-nuke.sh <org> [--yes] [--lock] [--include-archived] [--only-open] [--really-delete] [--match 'regex'] [--exclude 'regex']
#
# Examples:
#   Dry run (default):   ./org-issues-nuke.sh OldCo
#   Execute close:       ./org-issues-nuke.sh OldCo --yes
#   Close + lock:        ./org-issues-nuke.sh OldCo --yes --lock
#   Only open issues:    ./org-issues-nuke.sh OldCo --yes --only-open
#   Attempt deletion:    ./org-issues-nuke.sh OldCo --yes --really-delete
#   Filter repos:        ./org-issues-nuke.sh OldCo --yes --match '^(svc-|web-)'
#   Exclude repos:       ./org-issues-nuke.sh OldCo --yes --exclude '(^infra-|archived-)'

ORG="${1:-}"
if [[ -z "${ORG}" || "${ORG}" == "--help" || "${ORG}" == "-h" ]]; then
  sed -n '2,60p' "$0"
  exit 1
fi
shift || true

DRY_RUN=1
LOCK_ISSUES=0
INCLUDE_ARCHIVED=0
ONLY_OPEN=0
REALLY_DELETE=0
MATCH_REPO_REGEX=""
EXCLUDE_REPO_REGEX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) DRY_RUN=0 ;;
    --lock) LOCK_ISSUES=1 ;;
    --include-archived) INCLUDE_ARCHIVED=1 ;;
    --only-open) ONLY_OPEN=1 ;;
    --really-delete) REALLY_DELETE=1 ;;
    --match) MATCH_REPO_REGEX="${2:?}"; shift ;;
    --exclude) EXCLUDE_REPO_REGEX="${2:?}"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

# Verify gh auth early
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

echo "Org: ${ORG}"
echo "Dry run: $([[ $DRY_RUN -eq 1 ]] && echo YES || echo NO)"
echo "Lock after close: $([[ $LOCK_ISSUES -eq 1 ]] && echo YES || echo NO)"
echo "Include archived repos: $([[ $INCLUDE_ARCHIVED -eq 1 ]] && echo YES || echo NO)"
echo "Only open issues: $([[ $ONLY_OPEN -eq 1 ]] && echo YES || echo NO)"
echo "Attempt GraphQL deletion: $([[ $REALLY_DELETE -eq 1 ]] && echo YES || echo NO)"
[[ -n "$MATCH_REPO_REGEX" ]] && echo "Match include regex: $MATCH_REPO_REGEX"
[[ -n "$EXCLUDE_REPO_REGEX" ]] && echo "Match exclude regex: $EXCLUDE_REPO_REGEX"
echo

# Get repos
REPOS_JSON=$(gh repo list "$ORG" --limit 1000 --json nameWithOwner,isArchived,visibility)
REPOS=$(echo "$REPOS_JSON" | jq -r '.[] | @base64')

num_repos=0
while IFS= read -r enc; do
  repo_name=$(echo "$enc" | base64 --decode | jq -r '.nameWithOwner')
  is_archived=$(echo "$enc" | base64 --decode | jq -r '.isArchived')
  visibility=$(echo "$enc" | base64 --decode | jq -r '.visibility')

  # Archive filter
  if [[ "$INCLUDE_ARCHIVED" -eq 0 && "$is_archived" == "true" ]]; then
    continue
  fi

  # Regex filters
  if [[ -n "$MATCH_REPO_REGEX" ]] && ! [[ "$repo_name" =~ $MATCH_REPO_REGEX ]]; then
    continue
  fi
  if [[ -n "$EXCLUDE_REPO_REGEX" ]] && [[ "$repo_name" =~ $EXCLUDE_REPO_REGEX ]]; then
    continue
  fi

  ((num_repos++)) || true

  echo "=== [$visibility] $repo_name ==="

  # Build issue list
  state_arg=$([[ $ONLY_OPEN -eq 1 ]] && echo "open" || echo "all")
  ISSUES=$(gh issue list -R "$repo_name" --state "$state_arg" --limit 2000 --json number,title,state | jq -c '.[]')

  if [[ -z "$ISSUES" || "$ISSUES" == "null" ]]; then
    echo "No issues."
    continue
  fi

  issues_count=$(echo "$ISSUES" | wc -l | tr -d ' ')
  echo "Found $issues_count issue(s)."

  while IFS= read -r issue; do
    num=$(echo "$issue" | jq -r '.number')
    title=$(echo "$issue" | jq -r '.title' | tr '\n' ' ' | cut -c1-120)
    echo "- #$num \"$title\""

    if [[ $DRY_RUN -eq 1 ]]; then
      if [[ $REALLY_DELETE -eq 1 ]]; then
        echo "  DRY-RUN: would attempt delete via GraphQL; else close (and lock=$LOCK_ISSUES)."
      else
        echo "  DRY-RUN: would close (and lock=$LOCK_ISSUES)."
      fi
      continue
    fi

    # Try deletion (if requested)
    if [[ $REALLY_DELETE -eq 1 ]]; then
      # Get node ID for the issue via GraphQL
      owner="${repo_name%%/*}"
      name="${repo_name##*/}"
      node_id=$(gh api graphql -f query='
        query($owner:String!, $name:String!, $number:Int!) {
          repository(owner:$owner, name:$name) { issue(number:$number) { id } }
        }' -F owner="$owner" -F name="$name" -F number="$num" --jq '.data.repository.issue.id' || echo "")

      if [[ -n "$node_id" && "$node_id" != "null" ]]; then
        # Attempt delete
        if gh api graphql -f query='
          mutation($issueId:ID!) { deleteIssue(input:{issueId:$issueId}) { clientMutationId } }
        ' -F issueId="$node_id" >/dev/null 2>&1; then
          echo "  Deleted via GraphQL."
          # Go to next issue
          continue
        else
          echo "  Delete failed or not permitted; will close instead."
        fi
      else
        echo "  Could not resolve node id; will close instead."
      fi
    fi

    # Close the issue
    close_reason="not_planned"   # other option: completed
    if gh issue close "$num" -R "$repo_name" --reason "$close_reason" -c "Bulk cleanup $(ts)"; then
      echo "  Closed."
    else
      echo "  Close failed!" >&2
      continue
    fi

    # Optional lock (prevents further comments/edits)
    if [[ $LOCK_ISSUES -eq 1 ]]; then
      if gh api -X PUT "repos/${repo_name}/issues/${num}/lock" -f lock_reason="resolved" >/dev/null 2>&1; then
        echo "  Locked."
      else
        echo "  Lock failed (insufficient perms or already locked)."
      fi
    fi

    # Gentle pacing to avoid secondary rate limits
    sleep 0.2
  done <<< "$ISSUES"

  echo
done <<< "$REPOS"

echo "Processed $num_repos repo(s)."
echo "Done."
