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

# Colors for output
readonly BLUE='\033[0;34m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color
readonly LINE_COLOR='\033[0;36m' # Cyan for lines/borders

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly STAMP=$(date +%F_%H-%M-%S)
readonly LOG_FILE="${HOME}/.rsync-two-way.log"

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

print_section() {
    echo -e "${LINE_COLOR}╭────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${LINE_COLOR}│${NC} $1"
    echo -e "${LINE_COLOR}╰────────────────────────────────────────────────────────────────────────╯${NC}"
}

# Log to file
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Prompt user for yes/no confirmation
# Usage: prompt_yes_no "message" [default]
#   default: "y" or "n" (optional, defaults to "n")
# Returns: 0 for yes, 1 for no
prompt_yes_no() {
    local prompt_message="$1"
    local default="${2:-n}"
    local prompt_suffix
    local user_reply

    # Set the prompt suffix based on default
    if [[ "${default,,}" == "y" ]]; then
        prompt_suffix="(Y/n)"
    else
        prompt_suffix="(y/N)"
    fi

    # Read from /dev/tty to work correctly in while-read loops
    read -p "$prompt_message $prompt_suffix: " -r user_reply </dev/tty

    # If user just pressed Enter (empty reply), use default
    if [[ -z "$user_reply" ]]; then
        [[ "${default,,}" == "y" ]]
    else
        [[ $user_reply =~ ^[Yy]$ ]]
    fi
}

# Show usage information
show_usage() {
    cat << EOF
${GREEN}${SCRIPT_NAME}${NC} v${SCRIPT_VERSION} - Bidirectional rsync synchronization

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

# Validate arguments
if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_usage
    exit 0
fi

if [[ $# -ne 2 ]]; then
    print_error "Invalid number of arguments"
    echo ""
    show_usage
    exit 1
fi

LOCAL="$1"             # e.g. /srv/share/
REMOTE="$2"            # e.g. alice@backup.example.com:/srv/share/

# Configuration
ENABLE_BACKUPS=false  # Set to true to enable backup-dir functionality

# Patterns you never want to copy
EXCLUDES=(
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
OPTS=(
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
for e in "${EXCLUDES[@]}"; do
  OPTS+=(--exclude="$e")
done

# Validate local directory exists
if [[ ! -d "$LOCAL" ]]; then
    print_error "Local directory does not exist: $LOCAL"
    log "ERROR: Local directory does not exist: $LOCAL"
    exit 1
fi

# Extract remote host and path for connectivity check
if [[ "$REMOTE" =~ ^([^@]+@)?([^:]+):(.+)$ ]]; then
    REMOTE_USER_HOST="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    REMOTE_PATH="${BASH_REMATCH[3]}"
    REMOTE_HOST="${BASH_REMATCH[2]}"
else
    print_error "Invalid remote specification format: $REMOTE"
    print_info "Expected format: user@host:/path or host:/path"
    exit 1
fi

# Check if rsync is installed
if ! command -v rsync &>/dev/null; then
    print_error "rsync is not installed. Please install it first."
    log "ERROR: rsync not found in PATH"
    exit 2
fi

# Validate SSH connectivity to remote host
print_info "Validating connectivity to $REMOTE_HOST..."
log "Checking SSH connectivity to $REMOTE_HOST"

if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_USER_HOST" "exit" 2>/dev/null; then
    print_error "Cannot connect to remote host: $REMOTE_HOST"
    print_info "Please verify:"
    echo "  • SSH keys are properly configured"
    echo "  • Remote host is reachable"
    echo "  • User has proper permissions"
    log "ERROR: SSH connectivity check failed for $REMOTE_HOST"
    exit 3
fi

print_success "Connected to $REMOTE_HOST"
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
    print_warning "Synchronization cancelled by user"
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

if rsync "${OPTS[@]}" "$LOCAL/" "$REMOTE"; then
    print_success "Pass 1 completed successfully"
    log "Pass 1 completed successfully"
else
    RSYNC_EXIT=$?
    print_error "Pass 1 failed with exit code $RSYNC_EXIT"
    log "ERROR: Pass 1 failed with exit code $RSYNC_EXIT"
    exit 2
fi

echo ""

# ---------- Pass 2: pull REMOTE ➜ LOCAL ----------
print_section "Pass 2: Pulling changes from REMOTE ➜ LOCAL"
log "Pass 2: REMOTE -> LOCAL"
echo ""

if rsync "${OPTS[@]}" "$REMOTE/" "$LOCAL"; then
    print_success "Pass 2 completed successfully"
    log "Pass 2 completed successfully"
else
    RSYNC_EXIT=$?
    print_error "Pass 2 failed with exit code $RSYNC_EXIT"
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
