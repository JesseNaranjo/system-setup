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
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Print colored output
print_error()   { printf '%b[ ERROR   ]%b %s\n' "$RED" "$NC" "$1" >&2; if [[ -t 2 ]]; then printf '\a' >&2; sleep 2; fi; }
print_info()    { printf '%b[ INFO    ]%b %s\n' "$BLUE" "$NC" "$1"; }
print_success() { printf '%b[ SUCCESS ]%b %s\n' "$GREEN" "$NC" "$1"; }
print_warning() { printf '%b[ WARNING ]%b %s\n' "$YELLOW" "$NC" "$1"; }

print_dry_run() { printf '%b[ DRY-RUN ]%b %s\n' "$CYAN" "$NC" "$1"; }

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
readonly SCRIPT_FILE="gh_org_delete_repos.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
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
            print_error "✖ Unknown argument: $1"
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
    print_error "✖ Must specify either --all or provide repository names"
    echo ""
    show_help
fi

if [[ $DELETE_ALL -eq 1 && ${#REPO_LIST[@]} -gt 0 ]]; then
    print_error "✖ Cannot use --all with specific repository names"
    echo ""
    show_help
fi

# ============================================================================
# Self-Update Functionality
# ============================================================================

TEMP_FILES=()

# cleanup runs on normal exit, SIGINT, SIGTERM. Hoisted to file scope so the
# trap is wired the moment the script is loaded — a top-level guard that exits
# before main still reaps tracked temps.
cleanup() {
    local f
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup EXIT

# Defense-in-depth: at startup, reap any same-FS temp files (e.g., from a
# prior SIGKILL / power-loss / interrupted self-update) older than a normal
# run window. The EXIT trap above handles in-flight cleanup; this function
# handles what the trap couldn't fire for. TTY-aware so cron/ssh -T runs
# don't block on the prompt.
sweep_stale_temps() {
    local pattern="$1"
    local stale_files=()
    local f   # bash is dynamically scoped: an undeclared loop var leaks to the caller
    while IFS= read -r -d '' f; do
        stale_files+=("$f")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name "$pattern" -type f -mmin +10 -print0 2>/dev/null)

    [[ ${#stale_files[@]} -eq 0 ]] && return 0

    print_warning "⚠ Found ${#stale_files[@]} stale temp file(s) from a prior interrupted run:"
    for f in "${stale_files[@]}"; do
        print_warning "  - $f"
    done

    # `[[ -r /dev/tty ]]` only checks file permissions; under setsid the device
    # is world-readable but `open(2)` fails with ENXIO, so a subsequent
    # `read </dev/tty` aborts under set -e. Probe with a no-op stdin redirect
    # to detect actual openability.
    if { : </dev/tty; } 2>/dev/null; then
        # `|| true` swallows EOF (Ctrl+D) so set -e doesn't abort mid-cleanup.
        read -p "Press any key to delete and continue, Ctrl+C to abort: " -n 1 -r </dev/tty || true
        echo ""
    else
        print_warning "⚠ Non-interactive context — deleting and continuing without prompt."
    fi

    for f in "${stale_files[@]}"; do
        rm -f "$f" || true
    done
    print_success "✓ Cleaned up ${#stale_files[@]} stale temp file(s)"
}

# Strip every ANSI escape sequence except SGR colour.
# Defends against terminal injection: the diff preview renders the CONTENT of a
# file just downloaded, and a hostile file could otherwise repaint the screen
# over the default-yes overwrite prompt that follows — drawing a fake "no
# changes detected" line and turning one keypress into acceptance. The
# expressions run in this order, and the order matters:
#   1. OSC strings (\e]…) terminated by BEL or by ST (ESC \) — set-title and
#      friends.
#   2. The other ST-terminated string types: DCS (\eP), SOS (\eX), PM (\e^),
#      APC (\e_). Their payloads are consumed raw by a terminal.
#   3. CSI sequences (\e[…) whose final byte is NOT `m` — cursor moves
#      (\e[A, \e[2K, \e[H, …) and mode toggles (\e[?25l, …) go, while SGR
#      colour (\e[31m, \e[1;32m, \e[0m) survives, which is the point of the box.
#   4. A CSI truncated by end-of-line, which would otherwise swallow the start
#      of the next line as its parameters.
#   5. Every remaining ESC not followed by `[` — the two-byte forms. This is
#      the class the first version missed, and it held the worst of them:
#      \ec (RIS) resets and clears the entire terminal, \e7/\e8 save and
#      restore the cursor, \eM scrolls. Runs after 1-2 so it cannot eat the
#      introducer of a string sequence those are still matching.
#   6. A bare ESC at end of line.
# Uses literal ESC/BEL bytes from bash $'…' so the regexes are portable between
# GNU sed and BSD sed (which lacks \xNN support).
_sanitize_ansi() {
    local esc=$'\033' bel=$'\007'
    sed -E -e "s/${esc}\\][^${esc}${bel}]*(${bel}|${esc}\\\\)//g" \
           -e "s/${esc}[P^_X][^${esc}]*${esc}\\\\//g" \
           -e "s/${esc}\\[[0-9;?]*[^0-9;?m]//g" \
           -e "s/${esc}\\[[0-9;?]*$//" \
           -e "s/${esc}[^[]//g" \
           -e "s/${esc}$//"
}

# Render a unified diff between two files inside a labeled box. Pages through
# `less -RFX` when stdout is a TTY (-R passes ANSI through, -F exits if content
# fits one screen, -X skips alt-screen so output stays in scrollback); falls
# back to inline `diff` when piped or `less` is missing. The diff is the content
# of a file just downloaded, so it is untrusted and goes through _sanitize_ansi
# before it reaches the terminal.
show_diff_box() {
    local local_file="$1"
    local temp_file="$2"
    local label="$3"
    echo ""
    echo -e "${CYAN}╭────────────────────── Δ detected in ${label} ──────────────────────╮${NC}"
    # Probe for --color rather than assuming it: macOS 26's diff supports it, but
    # older BSD/macOS diff did not, and there it errors into an empty box.
    # "${arr[@]+"${arr[@]}"}" rather than a bare "${diff_color[@]}": the two are
    # equivalent from bash 4.4 on, but the guarded form is the repo-wide way of
    # expanding a possibly-empty array under `set -u` and every other site uses it.
    local diff_color=()
    diff --color=always /dev/null /dev/null >/dev/null 2>&1 && diff_color=(--color=always)
    if [[ -t 1 ]] && command -v less &>/dev/null; then
        diff -u "${diff_color[@]+"${diff_color[@]}"}" "${local_file}" "${temp_file}" | _sanitize_ansi | less -RFX || true
    else
        diff -u "${diff_color[@]+"${diff_color[@]}"}" "${local_file}" "${temp_file}" | _sanitize_ansi || true
    fi
    echo -e "${CYAN}╰─────────────────────────── ${label} ───────────────────────────────╯${NC}"
    echo ""
}

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
        print_warning "⚠ Neither 'curl' nor 'wget' found - self-update disabled"
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
        http_status=$(curl -H 'Cache-Control: no-cache, no-store' \
            --max-time 15 \
            -o "${output_file}" -w "%{http_code}" -sSL \
            "${REMOTE_BASE}/${script_file}" 2>/dev/null || true)
        [[ -z "$http_status" ]] && http_status="000"
        case "$http_status" in
            200) ;;
            429) print_error "✖ Rate limited by GitHub (HTTP 429)"; rm -f "${output_file}"; return 1 ;;
            000) print_error "✖ Download failed (network/timeout)"; rm -f "${output_file}"; return 1 ;;
            *)   print_error "✖ HTTP ${http_status} error"; rm -f "${output_file}"; return 1 ;;
        esac
        # Validate that we got a script, not an error page.
        # Stricter than the previous first-ten-lines shebang grep, which
        # accepted a shebang on ANY of the first 10 lines - so an HTML 4xx page
        # that merely mentions a shebang in a code snippet no longer passes.
        # Also reject CRLF - `exec` would fail with `bash\r: not found`, after
        # the file has already replaced the original on disk. `|| true` lets an
        # empty file reach the explicit checks below rather than blowing up under
        # set -e.
        local first_line
        IFS= read -r first_line < "${output_file}" || true
        if [[ "$first_line" != "#!"* ]]; then
            print_error "✖ Invalid content (no shebang on line 1)"
            rm -f "${output_file}"
            return 1
        fi
        if [[ "$first_line" == *$'\r' ]]; then
            print_error "✖ Invalid content (CRLF line endings)"
            rm -f "${output_file}"
            return 1
        fi
        return 0
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        local wget_exit=0
        wget --no-cache --no-cookies \
            --timeout=15 \
            -O "${output_file}" -q "${REMOTE_BASE}/${script_file}" 2>/dev/null \
            || wget_exit=$?
        [[ "$wget_exit" -ne 0 ]] && { print_error "✖ Download failed (wget exit ${wget_exit})"; rm -f "${output_file}"; return 1; }
        # Validate that we got a script, not an error page.
        # Stricter than the previous first-ten-lines shebang grep, which
        # accepted a shebang on ANY of the first 10 lines - so an HTML 4xx page
        # that merely mentions a shebang in a code snippet no longer passes.
        # Also reject CRLF - `exec` would fail with `bash\r: not found`, after
        # the file has already replaced the original on disk. `|| true` lets an
        # empty file reach the explicit checks below rather than blowing up under
        # set -e.
        local first_line
        IFS= read -r first_line < "${output_file}" || true
        if [[ "$first_line" != "#!"* ]]; then
            print_error "✖ Invalid content (no shebang on line 1)"
            rm -f "${output_file}"
            return 1
        fi
        if [[ "$first_line" == *$'\r' ]]; then
            print_error "✖ Invalid content (CRLF line endings)"
            rm -f "${output_file}"
            return 1
        fi
        return 0
    fi

    return 1
}

# Check for script updates and restart if updated
self_update() {
    local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
    local TEMP_SCRIPT_FILE
    TEMP_SCRIPT_FILE=$(mktemp "${SCRIPT_DIR}/~${SCRIPT_FILE}.tmp.XXXXXX")
    TEMP_FILES+=("$TEMP_SCRIPT_FILE")

    if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
        rm -f "$TEMP_SCRIPT_FILE"
        echo ""
        return 1
    fi

    # Compare versions
    if diff -q "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
        print_success "- Script is already up-to-date"
        rm -f "$TEMP_SCRIPT_FILE"
        return 0
    fi

    show_diff_box "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" "${SCRIPT_FILE}"

    # Non-interactive context (cron, systemd, ssh -T, CI, setsid): bare `read
    # </dev/tty` would fail under `set -e` and silently auto-accept the default.
    # Use the `{ : </dev/tty; }` open(2) probe, NOT `[[ -r /dev/tty ]]` — the
    # latter stays true under setsid while open() fails with ENXIO. Skip update and
    # continue with the unchanged local version instead.
    { : </dev/tty; } 2>/dev/null || { rm -f "$TEMP_SCRIPT_FILE"; print_info "Non-interactive — skipping self-update"; return 0; }
    read -p "→ Overwrite and restart with updated ${SCRIPT_FILE}? [Y/n] " -n 1 -r </dev/tty
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        echo ""
        chmod +x "${TEMP_SCRIPT_FILE}"
        if ! mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"; then
            rm -f "$TEMP_SCRIPT_FILE"
            print_error "✖ Failed to install update — keeping local version"
            return 1
        fi
        print_success "✓ Updated ${SCRIPT_FILE} - restarting..."
        echo ""
        export GH_SCRIPTS_UPDATED=1
        exec "${LOCAL_SCRIPT}" "$@"
    else
        print_warning "⚠ Skipped update - continuing with local version"
        rm -f "$TEMP_SCRIPT_FILE"
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
        print_error "✖ GitHub CLI not authenticated"
        echo ""
        echo "Please run: gh auth login"
        exit 1
    fi
    print_success "✓ GitHub CLI authenticated"
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
        print_success "✓ Repository deleted"
        ((TOTAL_REPOS_DELETED++)) || true
    else
        print_error "✖ Failed to delete repository (check permissions)"
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
    sweep_stale_temps '~*.tmp.??????'

    # Check for updates if download tool available
    # The guard is compared as a STRING: `[[ $v -eq 0 ]]` evaluates both operands
    # as arithmetic, so a `$(…)` smuggled in through the environment would be
    # executed right here.
    if detect_download_cmd && [[ -z "${GH_SCRIPTS_UPDATED:-}" ]]; then
        # `|| true`: self_update returns 1 when the download fails or the install
        # mv fails. Both are non-fatal by design — it prints "keeping local version"
        # and the tool is expected to carry on — but a bare call under
        # `set -euo pipefail` would abort here instead.
        self_update "$@" || true
        echo ""
    fi

    # One-shot: consumed so the gh/git children of this run do not inherit it.
    unset GH_SCRIPTS_UPDATED

    verify_gh_auth
    display_configuration

    if [[ $DELETE_ALL -eq 1 ]]; then
        print_info "Fetching all repositories from organization: ${ORG}"
        echo ""

        # Get repository list
        local repos_json=$(gh repo list "$ORG" --limit 1000 --json nameWithOwner,isArchived,visibility)
        local repos=$(echo "$repos_json" | jq -r '.[] | @base64')

        if [[ -z "$repos" ]]; then
            print_error "✖ No repositories found or failed to fetch repositories"
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
                print_error "✖ Repository not found or access denied"
                ((TOTAL_REPOS_FAILED++)) || true
                continue
            fi

            local repo_name=$(echo "$repo_json" | jq -r '.nameWithOwner')
            local is_archived=$(echo "$repo_json" | jq -r '.isArchived')
            local visibility=$(echo "$repo_json" | jq -r '.visibility')

            if ! should_process_repo "$repo_name" "$is_archived"; then
                echo ""
                echo -e "${CYAN}━━━━ [$visibility] $repo_name ━━━━${NC}"
                print_warning "⚠ Skipped (filtered by configuration)"
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
