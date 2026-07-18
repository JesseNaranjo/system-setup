#!/usr/bin/env bash

# rsync-two-way.sh - Bidirectional directory synchronization using rsync
#
# Usage: ./rsync-two-way.sh LOCAL_DIR REMOTE_SPEC
#        REMOTE_SPEC := user@host:/absolute/path
#
# This script:
# - Performs two-way synchronization between local and remote directories
# - Preserves file attributes, permissions, and timestamps
# - Mirrors deletions between both locations
# - Provides detailed progress reporting and logging
# - Creates automatic backups of overwritten/deleted files (optional)
# - Validates connectivity before sync operations
#
# Exit codes: 0 OK | 1 usage error | 2 rsync error | 3 connectivity error

set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=utils-misc.sh
source "${SCRIPT_DIR}/utils-misc.sh"

# Script metadata
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
STAMP="$(date +%F_%H-%M-%S)"
readonly STAMP
readonly LOG_FILE="${HOME}/.rsync-two-way.log"

# Single-use section-banner helper kept inline (not provided by utils-misc.sh).
print_section() {
    echo -e "${CYAN}╭────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${CYAN}│${NC} $1"
    echo -e "${CYAN}╰────────────────────────────────────────────────────────────────────────╯${NC}"
}

# Log to file
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Show usage information
show_usage() {
    cat << EOF
${GREEN}${SCRIPT_NAME}${NC} - Bidirectional rsync synchronization

${YELLOW}Usage:${NC}
  $SCRIPT_NAME LOCAL_DIR REMOTE_SPEC

${YELLOW}Arguments:${NC}
  LOCAL_DIR     Local directory path (e.g., /home/user/data/)
  REMOTE_SPEC   Remote specification (user@host:/path/to/dir/)

${YELLOW}Examples:${NC}
  $SCRIPT_NAME /srv/share/ alice@backup.example.com:/srv/share/
  $SCRIPT_NAME ~/Documents/ user@192.168.1.100:~/Documents/

${YELLOW}Options:${NC}
  -h, --help    Show this help message

${YELLOW}Features:${NC}
  • Two-way synchronization with automatic conflict resolution
  • Preserves permissions, timestamps, and hard links
  • Optional backup of overwritten/deleted files
  • Detailed progress reporting with itemized changes
  • Automatic connectivity validation
  • Comprehensive logging to ${LOG_FILE}

${YELLOW}Exit Codes:${NC}
  0  Success
  1  Usage error
  2  Rsync error
  3  Connectivity error

EOF
}

main() {
    # Help fast-path — before any network/self-update work. Preserves the
    # original "no args -> usage, exit 0" behavior.
    if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_usage
        exit 0
    fi

    sweep_stale_temps '~*.tmp.??????'
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    if [[ $# -ne 2 ]]; then
        print_error "✖ Invalid number of arguments"
        echo ""
        show_usage
        exit 1
    fi

    local LOCAL="$1"             # e.g. /srv/share/
    local REMOTE="$2"            # e.g. alice@backup.example.com:/srv/share/

    # Configuration
    local ENABLE_BACKUPS=false  # Set to true to enable backup-dir functionality

    # Patterns you never want to copy
    local EXCLUDES=(
      ".DS_Store"
      "Thumbs.db"
      ".Spotlight-V100"
      ".Trashes"
      ".TemporaryItems"
      ".fseventsd"
      "desktop.ini"
      # ".git/"              # Uncomment to exclude Git repositories
      ".svn/"
      ".~lock.*"
      "*.swp"
      "*.tmp"
      "*~"
    )

    # Core rsync switches (see man rsync)
    local OPTS=(
      --archive           # -a: recurse; preserve mode, owner, times, links…
      --verbose           # -v: verbose output
      --human-readable    # -h: human-readable numbers
      --hard-links        # preserve hard links
      --delete            # mirror deletions
      --update            # do NOT overwrite newer files on receiver
      --partial           # keep temp files if transfer interrupted
      --inplace           # update destination files in-place
      --itemize-changes   # output a change-summary for all updates
      --compress          # compress file data during transfer
      --stats             # give some file-transfer stats
    )

    # Add backup options if enabled
    if [[ "$ENABLE_BACKUPS" == true ]]; then
      OPTS+=(
        --backup
        --backup-dir=".$STAMP.bak"
      )
    fi

    # Add excludes to options
    local e
    for e in "${EXCLUDES[@]}"; do
      OPTS+=(--exclude="$e")
    done

    # Validate local directory exists
    if [[ ! -d "$LOCAL" ]]; then
        print_error "✖ Local directory does not exist: $LOCAL"
        log "ERROR: Local directory does not exist: $LOCAL"
        exit 1
    fi

    # Extract remote host and path for connectivity check
    local REMOTE_USER_HOST REMOTE_HOST
    if [[ "$REMOTE" =~ ^([^@]+@)?([^:]+):(.+)$ ]]; then
        REMOTE_USER_HOST="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        REMOTE_HOST="${BASH_REMATCH[2]}"
    else
        print_error "✖ Invalid remote specification format: $REMOTE"
        print_info "Expected format: user@host:/path or host:/path"
        exit 1
    fi

    # Check if rsync is installed
    if ! command -v rsync &>/dev/null; then
        print_error "✖ rsync is not installed. Please install it first."
        log "ERROR: rsync not found in PATH"
        exit 2
    fi

    # Validate SSH connectivity to remote host
    print_info "Validating connectivity to $REMOTE_HOST..."
    log "Checking SSH connectivity to $REMOTE_HOST"

    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_USER_HOST" "exit" 2>/dev/null; then
        print_error "✖ Cannot connect to remote host: $REMOTE_HOST"
        print_info "Please verify:"
        echo "  • SSH keys are properly configured"
        echo "  • Remote host is reachable"
        echo "  • User has proper permissions"
        log "ERROR: SSH connectivity check failed for $REMOTE_HOST"
        exit 3
    fi

    print_success "✓ Connected to $REMOTE_HOST"
    log "SSH connectivity verified for $REMOTE_HOST"

    # Display sync configuration
    echo ""
    print_section "Synchronization Configuration"
    echo -e "${BLUE}Local Directory:${NC}  $LOCAL"
    echo -e "${BLUE}Remote Location:${NC} $REMOTE"
    echo -e "${BLUE}Backup Enabled:${NC}  $ENABLE_BACKUPS"
    echo -e "${BLUE}Excludes:${NC}        ${#EXCLUDES[@]} pattern(s)"
    echo -e "${BLUE}Log File:${NC}        $LOG_FILE"
    echo ""

    # Prompt user to continue
    if ! prompt_yes_no "            → Continue with synchronization?" "y"; then
        print_warning "⚠ Synchronization cancelled by user"
        log "Synchronization cancelled by user"
        exit 0
    fi

    echo ""

    # Log sync start
    log "=========================================="
    log "Starting two-way sync: $LOCAL <-> $REMOTE"
    log "Backup enabled: $ENABLE_BACKUPS"

    # ---------- Pass 1: push LOCAL ➜ REMOTE ----------
    print_section "Pass 1: Pushing changes from LOCAL ➜ REMOTE"
    log "Pass 1: LOCAL -> REMOTE"
    echo ""

    local RSYNC_EXIT
    if rsync "${OPTS[@]}" "$LOCAL/" "$REMOTE"; then
        print_success "✓ Pass 1 completed successfully"
        log "Pass 1 completed successfully"
    else
        RSYNC_EXIT=$?
        print_error "✖ Pass 1 failed with exit code $RSYNC_EXIT"
        log "ERROR: Pass 1 failed with exit code $RSYNC_EXIT"
        exit 2
    fi

    echo ""

    # ---------- Pass 2: pull REMOTE ➜ LOCAL ----------
    print_section "Pass 2: Pulling changes from REMOTE ➜ LOCAL"
    log "Pass 2: REMOTE -> LOCAL"
    echo ""

    if rsync "${OPTS[@]}" "$REMOTE/" "$LOCAL"; then
        print_success "✓ Pass 2 completed successfully"
        log "Pass 2 completed successfully"
    else
        RSYNC_EXIT=$?
        print_error "✖ Pass 2 failed with exit code $RSYNC_EXIT"
        log "ERROR: Pass 2 failed with exit code $RSYNC_EXIT"
        exit 2
    fi

    echo ""
    print_section "Synchronization Complete"
    print_success "Two-way sync completed successfully at $(date '+%Y-%m-%d %H:%M:%S')"

    if [[ "$ENABLE_BACKUPS" == true ]]; then
        print_info "Backup directory: .$STAMP.bak (on both local and remote)"
    fi

    echo ""
    log "Two-way sync completed successfully"
    log "=========================================="

    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
