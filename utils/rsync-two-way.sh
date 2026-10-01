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
# - Refuses a LOCAL_DIR, or a REMOTE_SPEC user or host, that begins with '-'
#   (option-injection guard, exit 1)
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

# ssh destination (user@host or host) and the host after its last '@', split
# out of REMOTE_SPEC by validate_sync_args.
REMOTE_USER_HOST=""
REMOTE_HOST=""

# Single-use section-banner helper kept inline (not provided by utils-misc.sh).
print_section() {
    echo -e "${CYAN}╭────────────────────────────────────────────────────────────────────────╮${NC}"
    printf '%b│%b %s\n' "$CYAN" "$NC" "$1"
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

# Validate LOCAL_DIR and REMOTE_SPEC, then split REMOTE_SPEC into the ssh
# destination and the host after its last '@'. main calls it before ssh or
# rsync runs (check_for_updates has already fetched this script by then).
# Usage: validate_sync_args "local_dir" "remote_spec"
# Sets: REMOTE_USER_HOST, REMOTE_HOST
# Returns: 0 on success, 1 on a usage error (message already printed)
validate_sync_args() {
    local local_dir="$1"
    local remote_spec="$2"

    # Option-injection guard. Quoting stops word splitting, not option parsing:
    # a token that begins with '-' is read as an option by the command it
    # reaches. LOCAL_DIR is an rsync positional in both passes, and rsync's man
    # page documents no `--` end-of-options marker, so check the shape instead
    # (the same defense rsync-over-tunnel.sh uses in resolve_transfer_path).
    if [[ "$local_dir" == -* ]]; then
        print_error "✖ Refusing a local directory that begins with '-' (option-injection guard): $local_dir"
        print_info "Pass './$local_dir' or an absolute path instead"
        return 1
    fi

    if [[ ! -d "$local_dir" ]]; then
        print_error "✖ Local directory does not exist: $local_dir"
        log "ERROR: Local directory does not exist: $local_dir"
        return 1
    fi

    if [[ ! "$remote_spec" =~ ^([^@]+@)?([^:]+):(.+)$ ]]; then
        print_error "✖ Invalid remote specification format: $remote_spec"
        print_info "Expected format: user@host:/path or host:/path"
        return 1
    fi
    REMOTE_USER_HOST="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    # The host is what follows the LAST '@', where ssh and rsync split a destination.
    REMOTE_HOST="${REMOTE_USER_HOST##*@}"

    # The same guard on the remote side. REMOTE_USER_HOST is ssh's destination
    # in main's connectivity check, which runs before the confirmation prompt,
    # and it begins with the same character as REMOTE_SPEC, the rsync
    # positional. REMOTE_HOST is checked on its own because a bare host that
    # begins with '-' is an ssh option wherever rsync's remote-shell command
    # line places it. A guard on the host alone misses '-oProxyCommand=x@host:/p':
    # the host is clean, but ssh parses the whole destination as an option.
    if [[ "$REMOTE_USER_HOST" == -* || "$REMOTE_HOST" == -* ]]; then
        print_error "✖ Refusing a remote user or host that begins with '-' (option-injection guard): $remote_spec"
        return 1
    fi

    return 0
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

    # Validate both arguments and set REMOTE_USER_HOST / REMOTE_HOST
    validate_sync_args "$LOCAL" "$REMOTE" || exit 1

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
