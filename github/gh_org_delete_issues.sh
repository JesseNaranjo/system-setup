#!/usr/bin/env bash

# gh_org_delete_issues.sh - Bulk issue management for GitHub organizations
#
# This script provides bulk operations for closing, locking, and optionally
# deleting issues across all repositories in a GitHub organization.
#
# Requirements:
#   - GitHub CLI (gh) authenticated: `gh auth login`
#   - Token must have admin:repo_hook/repo scope for private repos
#   - public_repo scope is sufficient for public repositories
#
# Usage:
#   ./gh_org_delete_issues.sh <org> [options]
#
# Options:
#   --yes                  Execute changes (default is dry-run mode)
#   --lock                 Lock issues after closing (prevents further comments)
#   --include-archived     Include archived repositories
#   --only-open            Process only open issues (default: all issues)
#   --really-delete        Attempt GraphQL deletion (requires special permissions)
#   --match 'regex'        Only process repos matching this regex pattern
#   --exclude 'regex'      Skip repos matching this regex pattern
#   -h, --help             Display this help message
#
# Examples:
#   Dry run (default):     ./gh_org_delete_issues.sh OldCo
#   Execute close:         ./gh_org_delete_issues.sh OldCo --yes
#   Close + lock:          ./gh_org_delete_issues.sh OldCo --yes --lock
#   Only open issues:      ./gh_org_delete_issues.sh OldCo --yes --only-open
#   Attempt deletion:      ./gh_org_delete_issues.sh OldCo --yes --really-delete
#   Filter repos:          ./gh_org_delete_issues.sh OldCo --yes --match '^(svc-|web-)'
#   Exclude repos:         ./gh_org_delete_issues.sh OldCo --yes --exclude '(^infra-|archived-)'
#
# Note: Always run with dry-run first to verify which issues will be affected.

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Print colored output
print_info() {
    echo -e "${BLUE}[ INFO    ]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[ SUCCESS ]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ WARNING ]${NC} $1"
}

print_error() {
    echo -e "${RED}[ ERROR   ]${NC} $1"
}

print_dry_run() {
    echo -e "${CYAN}[DRY-RUN]${NC} $1"
}

# Display help message
show_help() {
    sed -n '3,34p' "$0" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

# Parse command line arguments
ORG="${1:-}"
if [[ -z "${ORG}" || "${ORG}" == "--help" || "${ORG}" == "-h" ]]; then
    show_help
fi
shift || true

# Default configuration
DRY_RUN=1
LOCK_ISSUES=0
INCLUDE_ARCHIVED=0
ONLY_OPEN=0
REALLY_DELETE=0
MATCH_REPO_REGEX=""
EXCLUDE_REPO_REGEX=""

# Global counters
TOTAL_REPOS_PROCESSED=0
TOTAL_ISSUES_FOUND=0
TOTAL_ISSUES_DELETED=0
TOTAL_ISSUES_CLOSED=0
TOTAL_ISSUES_LOCKED=0
TOTAL_ISSUES_FAILED=0

# Self-update configuration
readonly REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/github"
DOWNLOAD_CMD=""

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            DRY_RUN=0
            ;;
        --lock)
            LOCK_ISSUES=1
            ;;
        --include-archived)
            INCLUDE_ARCHIVED=1
            ;;
        --only-open)
            ONLY_OPEN=1
            ;;
        --really-delete)
            REALLY_DELETE=1
            ;;
        --match)
            MATCH_REPO_REGEX="${2:?Missing regex pattern for --match}"
            shift
            ;;
        --exclude)
            EXCLUDE_REPO_REGEX="${2:?Missing regex pattern for --exclude}"
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            print_error "Unknown argument: $1"
            echo ""
            show_help
            ;;
    esac
    shift
done

# ============================================================================
# Self-Update Functionality
# ============================================================================

# Detect available download command (curl or wget)
detect_download_cmd() {
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
        return 0
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
        return 0
    else
        DOWNLOAD_CMD=""
        print_warning "Neither 'curl' nor 'wget' found - self-update disabled"
        print_info "Install curl or wget to enable automatic updates"
        return 1
    fi
}

# Download script from remote repository
download_script() {
    local script_file="$1"
    local output_file="$2"
    local http_status=""

    print_info "Fetching ${script_file}..."
    echo "            ▶ ${REMOTE_BASE}/${script_file}..."

    if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
        http_status=$(curl -H 'Cache-Control: no-cache, no-store' -o "${output_file}" -w "%{http_code}" -fsSL "${REMOTE_BASE}/${script_file}" 2>/dev/null || echo "000")
        if [[ "$http_status" == "200" ]]; then
            # Validate that we got a script, not an error page
            # Check first 10 lines for shebang to handle files with leading comments/blank lines
            if head -n 10 "${output_file}" | grep -q "^#!/"; then
                return 0
            else
                print_error "✖ Invalid content received (not a script)"
                return 1
            fi
        elif [[ "$http_status" == "429" ]]; then
            print_error "✖ Rate limited by GitHub (HTTP 429)"
            return 1
        elif [[ "$http_status" != "000" ]]; then
            print_error "✖ HTTP ${http_status} error"
            return 1
        else
            print_error "✖ Download failed"
            return 1
        fi
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        if wget --no-cache --no-cookies -O "${output_file}" -q "${REMOTE_BASE}/${script_file}" 2>/dev/null; then
            # Validate that we got a script, not an error page
            # Check first 10 lines for shebang to handle files with leading comments/blank lines
            if head -n 10 "${output_file}" | grep -q "^#!/"; then
                return 0
            else
                print_error "✖ Invalid content received (not a script)"
                return 1
            fi
        else
            print_error "✖ Download failed"
            return 1
        fi
    fi

    return 1
}

# Check for script updates and restart if updated
self_update() {
    local SCRIPT_FILE="gh_org_delete_issues.sh"
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
    local TEMP_SCRIPT_FILE="$(mktemp)"

    if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
        rm -f "${TEMP_SCRIPT_FILE}"
        echo ""
        return 1
    fi

    # Compare versions
    if diff -q "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
        print_success "- Script is already up-to-date"
        rm -f "${TEMP_SCRIPT_FILE}"
        return 0
    fi

    # Show diff
    echo ""
    echo -e "${LINE_COLOR}╭────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${NC}"
    diff -u --color "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" || true
    echo -e "${LINE_COLOR}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${NC}"
    echo ""

    read -p "→ Overwrite and restart with updated ${SCRIPT_FILE}? [Y/n] " -n 1 -r
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        echo ""
        chmod +x "${TEMP_SCRIPT_FILE}"
        mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"
        print_success "✓ Updated ${SCRIPT_FILE} - restarting..."
        echo ""
        export scriptUpdated=1
        exec "${LOCAL_SCRIPT}" "$@"
        exit 0
    else
        print_warning "⚠ Skipped update - continuing with local version"
        rm -f "${TEMP_SCRIPT_FILE}"
    fi
    echo ""
}

# ============================================================================
# GitHub Authentication
# ============================================================================

# Verify GitHub CLI authentication
verify_gh_auth() {
    print_info "Verifying GitHub CLI authentication..."
    if ! gh auth status >/dev/null 2>&1; then
        print_error "GitHub CLI not authenticated"
        echo ""
        echo "Please run: gh auth login"
        exit 1
    fi
    print_success "GitHub CLI authenticated"
}

# Generate timestamp in ISO8601 format
timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Display current configuration
display_configuration() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}Configuration:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Organization:          ${ORG}"
    echo "Mode:                  $([[ $DRY_RUN -eq 1 ]] && echo "DRY-RUN (no changes)" || echo "EXECUTE (will make changes)")"
    echo "Lock after close:      $([[ $LOCK_ISSUES -eq 1 ]] && echo "YES" || echo "NO")"
    echo "Include archived:      $([[ $INCLUDE_ARCHIVED -eq 1 ]] && echo "YES" || echo "NO")"
    echo "Only open issues:      $([[ $ONLY_OPEN -eq 1 ]] && echo "YES" || echo "NO")"
    echo "Attempt deletion:      $([[ $REALLY_DELETE -eq 1 ]] && echo "YES" || echo "NO")"
    [[ -n "$MATCH_REPO_REGEX" ]] && echo "Include regex:         $MATCH_REPO_REGEX"
    [[ -n "$EXCLUDE_REPO_REGEX" ]] && echo "Exclude regex:         $EXCLUDE_REPO_REGEX"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Process issues in a repository
process_repository() {
    local repo_name="$1"
    local visibility="$2"
    local state_arg="$3"

    echo ""
    echo -e "${CYAN}━━━━ [$visibility] $repo_name ━━━━${NC}"

    # Get issue list
    local issues=$(gh issue list -R "$repo_name" --state "$state_arg" --limit 2000 --json number,title,state | jq -c '.[]')

    if [[ -z "$issues" || "$issues" == "null" ]]; then
        print_info "No issues found"
        return 0
    fi

    local issues_count=$(echo "$issues" | wc -l | tr -d ' ')
    print_info "Found $issues_count issue(s)"
    ((TOTAL_ISSUES_FOUND += issues_count)) || true
    echo ""

    while IFS= read -r issue; do
        process_issue "$repo_name" "$issue"
    done <<< "$issues"
}

# Process a single issue
process_issue() {
    local repo_name="$1"
    local issue="$2"
    local num
    local title

    num=$(echo "$issue" | jq -r '.number')
    title=$(echo "$issue" | jq -r '.title' | tr '\n' ' ' | cut -c1-100)

    echo "  Issue #${num}: ${title}"

    if [[ $DRY_RUN -eq 1 ]]; then
        if [[ $REALLY_DELETE -eq 1 ]]; then
            print_dry_run "    Would attempt delete via GraphQL; else close (lock=$LOCK_ISSUES)"
        else
            print_dry_run "    Would close (lock=$LOCK_ISSUES)"
        fi
        return 0
    fi

    # Try deletion if requested
    if [[ $REALLY_DELETE -eq 1 ]] && attempt_delete_issue "$repo_name" "$num"; then
        return 0
    fi

    # Close the issue
    close_issue "$repo_name" "$num"

    # Lock the issue if requested
    if [[ $LOCK_ISSUES -eq 1 ]]; then
        lock_issue "$repo_name" "$num"
    fi

    # Gentle pacing to avoid secondary rate limits
    sleep 0.2
}

# Attempt to delete an issue via GraphQL
attempt_delete_issue() {
    local repo_name="$1"
    local num="$2"
    local owner="${repo_name%%/*}"
    local name="${repo_name##*/}"
    local node_id

    # Get node ID for the issue
    node_id=$(gh api graphql -f query='
        query($owner:String!, $name:String!, $number:Int!) {
            repository(owner:$owner, name:$name) {
                issue(number:$number) { id }
            }
        }' \
        -F owner="$owner" \
        -F name="$name" \
        -F number="$num" \
        --jq '.data.repository.issue.id' 2>/dev/null || echo "")

    if [[ -z "$node_id" || "$node_id" == "null" ]]; then
        print_warning "    Could not resolve node ID; will close instead"
        return 1
    fi

    # Attempt deletion
    if gh api graphql -f query='
        mutation($issueId:ID!) {
            deleteIssue(input:{issueId:$issueId}) {
                clientMutationId
            }
        }' \
        -F issueId="$node_id" >/dev/null 2>&1; then
        print_success "    Deleted via GraphQL"
        ((TOTAL_ISSUES_DELETED++)) || true
        return 0
    else
        print_warning "    Delete failed or not permitted; will close instead"
        return 1
    fi
}

# Close an issue
close_issue() {
    local repo_name="$1"
    local num="$2"
    local close_reason="not_planned"  # other option: completed

    if gh issue close "$num" -R "$repo_name" --reason "$close_reason" -c "Bulk cleanup $(timestamp)" 2>/dev/null; then
        print_success "    Closed"
        ((TOTAL_ISSUES_CLOSED++)) || true
    else
        print_error "    Close failed"
        ((TOTAL_ISSUES_FAILED++)) || true
        return 1
    fi
}

# Lock an issue
lock_issue() {
    local repo_name="$1"
    local num="$2"

    if gh api -X PUT "repos/${repo_name}/issues/${num}/lock" -f lock_reason="resolved" >/dev/null 2>&1; then
        print_success "    Locked"
        ((TOTAL_ISSUES_LOCKED++)) || true
    else
        print_warning "    Lock failed (insufficient permissions or already locked)"
    fi
}

# Main execution function
main() {
    # Check for updates if download tool available
    if detect_download_cmd && [[ ${scriptUpdated:-0} -eq 0 ]]; then
        self_update "$@"
        echo ""
    fi

    verify_gh_auth
    display_configuration

    print_info "Fetching repositories from organization: ${ORG}"
    echo ""

    # Get repository list
    local repos_json=$(gh repo list "$ORG" --limit 1000 --json nameWithOwner,isArchived,visibility)
    local repos=$(echo "$repos_json" | jq -r '.[] | @base64')

    if [[ -z "$repos" ]]; then
        print_error "No repositories found or failed to fetch repositories"
        exit 1
    fi

    local num_repos=0
    local state_arg=$([[ $ONLY_OPEN -eq 1 ]] && echo "open" || echo "all")

    while IFS= read -r enc; do
        local repo_name is_archived visibility

        repo_name=$(echo "$enc" | base64 --decode | jq -r '.nameWithOwner')
        is_archived=$(echo "$enc" | base64 --decode | jq -r '.isArchived')
        visibility=$(echo "$enc" | base64 --decode | jq -r '.visibility')

        # Apply archive filter
        if [[ "$INCLUDE_ARCHIVED" -eq 0 && "$is_archived" == "true" ]]; then
            continue
        fi

        # Apply regex filters
        if [[ -n "$MATCH_REPO_REGEX" ]] && ! [[ "$repo_name" =~ $MATCH_REPO_REGEX ]]; then
            continue
        fi
        if [[ -n "$EXCLUDE_REPO_REGEX" ]] && [[ "$repo_name" =~ $EXCLUDE_REPO_REGEX ]]; then
            continue
        fi

        ((num_repos++)) || true
        ((TOTAL_REPOS_PROCESSED++)) || true

        process_repository "$repo_name" "$visibility" "$state_arg"
    done <<< "$repos"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}Summary${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Repositories processed:    ${TOTAL_REPOS_PROCESSED}"
    echo "Issues found:              ${TOTAL_ISSUES_FOUND}"
    if [[ $DRY_RUN -eq 0 ]]; then
        echo "Issues deleted:            ${TOTAL_ISSUES_DELETED}"
        echo "Issues closed:             ${TOTAL_ISSUES_CLOSED}"
        echo "Issues locked:             ${TOTAL_ISSUES_LOCKED}"
        if [[ $TOTAL_ISSUES_FAILED -gt 0 ]]; then
            echo -e "${RED}Issues failed:             ${TOTAL_ISSUES_FAILED}${NC}"
        fi
    else
        echo -e "${CYAN}Mode:                      DRY-RUN (no changes made)${NC}"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ $DRY_RUN -eq 0 ]]; then
        print_success "Operation complete!"
    else
        print_info "Dry-run complete. Use --yes to execute changes."
    fi
    echo ""
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
