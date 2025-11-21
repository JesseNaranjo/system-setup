#!/usr/bin/env bash

# gh_org_delete_repos.sh - Bulk repository deletion for GitHub organizations
#
# This script deletes repositories passed as parameters from a GitHub organization.
# Can also delete all repositories in an organization with filtering options.
#
# Requirements:
#   - GitHub CLI (gh) authenticated: `gh auth login`
#   - Token must have delete_repo scope
#   - User must have admin access to repositories
#
# Usage:
#   ./gh_org_delete_repos.sh <org> <repo1> [repo2 ...] [options]
#   ./gh_org_delete_repos.sh <org> --all [options]
#
# Options:
#   --yes                  Execute changes (default is dry-run mode)
#   --all                  Delete all repositories in the organization
#   --include-archived     Include archived repositories
#   --match 'regex'        Only process repos matching this regex pattern
#   --exclude 'regex'      Skip repos matching this regex pattern
#   -h, --help             Display this help message
#
# Examples:
#   Dry run single repo:   ./gh_org_delete_repos.sh OldCo my-repo
#   Delete single repo:    ./gh_org_delete_repos.sh OldCo my-repo --yes
#   Delete multiple:       ./gh_org_delete_repos.sh OldCo repo1 repo2 repo3 --yes
#   Dry run all repos:     ./gh_org_delete_repos.sh OldCo --all
#   Delete all repos:      ./gh_org_delete_repos.sh OldCo --all --yes
#   Filter repos:          ./gh_org_delete_repos.sh OldCo --all --yes --match '^(svc-|web-)'
#   Exclude repos:         ./gh_org_delete_repos.sh OldCo --all --yes --exclude '(^infra-|archived-)'
#
# Note: Always run with dry-run first to verify which repositories will be deleted.
# WARNING: Repository deletion is PERMANENT and cannot be undone!

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
    sed -n '3,36p' "$0" | sed 's/^# //' | sed 's/^#//'
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
DELETE_ALL=0
INCLUDE_ARCHIVED=0
MATCH_REPO_REGEX=""
EXCLUDE_REPO_REGEX=""
REPO_LIST=()

# Global counters
TOTAL_REPOS_PROCESSED=0
TOTAL_REPOS_DELETED=0
TOTAL_REPOS_FAILED=0

# Self-update configuration
readonly REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/github"
DOWNLOAD_CMD=""

# Parse command line options and repository names
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            DRY_RUN=0
            ;;
        --all)
            DELETE_ALL=1
            ;;
        --include-archived)
            INCLUDE_ARCHIVED=1
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
        --*)
            print_error "Unknown argument: $1"
            echo ""
            show_help
            ;;
        *)
            # Non-option argument is a repository name
            REPO_LIST+=("$1")
            ;;
    esac
    shift
done

# Validate arguments
if [[ $DELETE_ALL -eq 0 && ${#REPO_LIST[@]} -eq 0 ]]; then
    print_error "Must specify either --all or provide repository names"
    echo ""
    show_help
fi

if [[ $DELETE_ALL -eq 1 && ${#REPO_LIST[@]} -gt 0 ]]; then
    print_error "Cannot use --all with specific repository names"
    echo ""
    show_help
fi

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
    local SCRIPT_FILE="gh_org_delete_repos.sh"
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
    echo -e "${CYAN}╭────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${NC}"
    diff -u --color "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" || true
    echo -e "${CYAN}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${NC}"
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
    echo "Mode:                  $([[ $DRY_RUN -eq 1 ]] && echo "DRY-RUN (no changes)" || echo "EXECUTE (PERMANENT DELETION)")"
    if [[ $DELETE_ALL -eq 1 ]]; then
        echo "Scope:                 ALL REPOSITORIES"
    else
        echo "Scope:                 ${#REPO_LIST[@]} specific repository(ies)"
        for repo in "${REPO_LIST[@]}"; do
            echo "                       - ${repo}"
        done
    fi
    echo "Include archived:      $([[ $INCLUDE_ARCHIVED -eq 1 ]] && echo "YES" || echo "NO")"
    [[ -n "$MATCH_REPO_REGEX" ]] && echo "Include regex:         $MATCH_REPO_REGEX"
    [[ -n "$EXCLUDE_REPO_REGEX" ]] && echo "Exclude regex:         $EXCLUDE_REPO_REGEX"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $DRY_RUN -eq 0 ]]; then
        echo -e "${RED}WARNING: Repository deletion is PERMANENT and cannot be undone!${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
    echo ""
}

# Delete a repository
delete_repository() {
    local repo_name="$1"
    local visibility="$2"

    echo ""
    echo -e "${CYAN}━━━━ [$visibility] $repo_name ━━━━${NC}"

    if [[ $DRY_RUN -eq 1 ]]; then
        print_dry_run "Would delete repository"
        return 0
    fi

    # Attempt to delete the repository
    if gh repo delete "$repo_name" --yes 2>/dev/null; then
        print_success "Repository deleted"
        ((TOTAL_REPOS_DELETED++)) || true
    else
        print_error "Failed to delete repository (check permissions)"
        ((TOTAL_REPOS_FAILED++)) || true
    fi

    # Rate limiting protection
    sleep 0.5
}

# Check if repository should be processed
should_process_repo() {
    local repo_name="$1"
    local is_archived="$2"

    # Apply archive filter
    if [[ "$INCLUDE_ARCHIVED" -eq 0 && "$is_archived" == "true" ]]; then
        return 1
    fi

    # Apply regex filters
    if [[ -n "$MATCH_REPO_REGEX" ]] && ! [[ "$repo_name" =~ $MATCH_REPO_REGEX ]]; then
        return 1
    fi
    if [[ -n "$EXCLUDE_REPO_REGEX" ]] && [[ "$repo_name" =~ $EXCLUDE_REPO_REGEX ]]; then
        return 1
    fi

    return 0
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

    if [[ $DELETE_ALL -eq 1 ]]; then
        print_info "Fetching all repositories from organization: ${ORG}"
        echo ""

        # Get repository list
        local repos_json=$(gh repo list "$ORG" --limit 1000 --json nameWithOwner,isArchived,visibility)
        local repos=$(echo "$repos_json" | jq -r '.[] | @base64')

        if [[ -z "$repos" ]]; then
            print_error "No repositories found or failed to fetch repositories"
            exit 1
        fi

        while IFS= read -r enc; do
            local repo_name is_archived visibility

            repo_name=$(echo "$enc" | base64 --decode | jq -r '.nameWithOwner')
            is_archived=$(echo "$enc" | base64 --decode | jq -r '.isArchived')
            visibility=$(echo "$enc" | base64 --decode | jq -r '.visibility')

            if ! should_process_repo "$repo_name" "$is_archived"; then
                continue
            fi

            ((TOTAL_REPOS_PROCESSED++)) || true
            delete_repository "$repo_name" "$visibility"
        done <<< "$repos"
    else
        # Process specific repositories
        print_info "Processing ${#REPO_LIST[@]} specific repository(ies)"
        echo ""

        for repo in "${REPO_LIST[@]}"; do
            # Construct full repository name
            local full_repo_name="${ORG}/${repo}"

            # Check if repository exists and get details
            local repo_json=$(gh repo view "$full_repo_name" --json nameWithOwner,isArchived,visibility 2>/dev/null || echo "")

            if [[ -z "$repo_json" ]]; then
                echo ""
                echo -e "${CYAN}━━━━ $full_repo_name ━━━━${NC}"
                print_error "Repository not found or access denied"
                ((TOTAL_REPOS_FAILED++)) || true
                continue
            fi

            local repo_name=$(echo "$repo_json" | jq -r '.nameWithOwner')
            local is_archived=$(echo "$repo_json" | jq -r '.isArchived')
            local visibility=$(echo "$repo_json" | jq -r '.visibility')

            if ! should_process_repo "$repo_name" "$is_archived"; then
                echo ""
                echo -e "${CYAN}━━━━ [$visibility] $repo_name ━━━━${NC}"
                print_warning "Skipped (filtered by configuration)"
                continue
            fi

            ((TOTAL_REPOS_PROCESSED++)) || true
            delete_repository "$repo_name" "$visibility"
        done
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}Summary${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Repositories processed:    ${TOTAL_REPOS_PROCESSED}"
    if [[ $DRY_RUN -eq 0 ]]; then
        echo "Repositories deleted:      ${TOTAL_REPOS_DELETED}"
        if [[ $TOTAL_REPOS_FAILED -gt 0 ]]; then
            echo -e "${RED}Repositories failed:       ${TOTAL_REPOS_FAILED}${NC}"
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
