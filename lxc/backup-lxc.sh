#!/usr/bin/env bash

# backup-lxc.sh - Backup an LXC container to a compressed archive
#
# Usage: ./backup-lxc.sh <container_name> [backup_dir] [--privileged] [--compression=small|balanced|fast]
#
# This script:
# - Backs up an LXC container's config and rootfs to a single .tar.7z archive
# - Preserves all numeric ownership and permissions using tar --numeric-owner
# - Supports three compression presets: fast, balanced, small (default: small)
# - Stops the container before backup if running (with confirmation)
# - Works with both unprivileged (default) and privileged containers
#
# Arguments:
#   container_name  Name of the container to backup (required)
#   backup_dir      Directory to store the backup (default: current directory)
#   --privileged    Backup from /var/lib/lxc/ instead of ~/.local/share/lxc/
#   --compression   Compression level: fast, balanced, or small (default: small)
#
# Compression presets:
#   fast     - Quick compression, larger files     (-mx=3, -md=32m)
#   balanced - Moderate compression and speed      (-mx=5, -md=128m)
#   small    - Maximum compression, slower         (-mx=9, -md=1536m)
#
# Output: <container>_<YYYYMMDD_HHMMSS>.tar.7z
#
# Note: Requires sudo to read all files in the container's rootfs.

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
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

# Prompt user for yes/no confirmation
# Usage: prompt_yes_no "message" [default]
#   default: "y" or "n" (optional, defaults to "n")
# Returns: 0 for yes, 1 for no
prompt_yes_no() {
    local prompt_message="$1"
    local default="${2:-n}"
    local prompt_suffix
    local user_reply

    if [[ "${default,,}" == "y" ]]; then
        prompt_suffix="(Y/n)"
    else
        prompt_suffix="(y/N)"
    fi

    read -p "$prompt_message $prompt_suffix: " -r user_reply </dev/tty

    if [[ -z "$user_reply" ]]; then
        [[ "${default,,}" == "y" ]]
    else
        [[ $user_reply =~ ^[Yy]$ ]]
    fi
}

# ============================================================================
# Compression Presets
# ============================================================================

# Compression preset: fast (quick, larger files)
readonly COMPRESS_FAST="-t7z -m0=lzma2 -mx=3 -md=32m -mfb=32 -mmf=hc4 -ms=on -mmt"

# Compression preset: balanced (moderate compression and speed)
readonly COMPRESS_BALANCED="-t7z -m0=lzma2 -mx=5 -md=128m -mfb=64 -mmf=bt4 -ms=on -mmt"

# Compression preset: small (maximum compression, slower)
readonly COMPRESS_SMALL="-t7z -m0=lzma2 -mx=9 -md=1536m -mfb=273 -mmf=bt4 -ms=on -mmt"

# ============================================================================
# Input Validation
# ============================================================================

show_usage() {
    echo "Usage: ${0##*/} <container_name> [backup_dir] [--privileged] [--compression=small|balanced|fast]"
    echo ""
    echo "Arguments:"
    echo "  container_name  Name of the container to backup (required)"
    echo "  backup_dir      Directory to store the backup (default: current directory)"
    echo "  --privileged    Backup from /var/lib/lxc/ instead of ~/.local/share/lxc/"
    echo "  --compression   Compression level: fast, balanced, or small (default: small)"
    echo ""
    echo "Examples:"
    echo "  ${0##*/} my-container"
    echo "  ${0##*/} my-container /backups --compression=fast"
    echo "  ${0##*/} my-container --privileged --compression=balanced"
}

check_required_tools() {
    for tool in tar 7z; do
        if ! command -v "$tool" &>/dev/null; then
            print_error "$tool is required but not installed"
            echo ""
            echo "Install with: sudo apt install $( [[ "$tool" == "7z" ]] && echo "7zip" || echo "$tool" )"
            exit 69  # EX_UNAVAILABLE
        fi
    done
}

# ============================================================================
# Main Function
# ============================================================================

main() {
    check_required_tools

    # Parse arguments
    local CONTAINER_NAME=""
    local BACKUP_DIR="."
    local PRIVILEGED=false
    local COMPRESSION_LEVEL="small"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --privileged)
                PRIVILEGED=true
                shift
                ;;
            --compression=*)
                COMPRESSION_LEVEL="${1#*=}"
                if [[ ! "$COMPRESSION_LEVEL" =~ ^(fast|balanced|small)$ ]]; then
                    print_error "Invalid compression level: $COMPRESSION_LEVEL"
                    echo "Valid options: fast, balanced, small"
                    exit 64  # EX_USAGE
                fi
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                show_usage
                exit 64  # EX_USAGE
                ;;
            *)
                if [[ -z "$CONTAINER_NAME" ]]; then
                    CONTAINER_NAME="$1"
                else
                    BACKUP_DIR="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$CONTAINER_NAME" ]]; then
        print_error "Missing required container name argument"
        echo ""
        show_usage
        exit 64  # EX_USAGE
    fi

    # Set compression options based on level
    local COMPRESS_OPTS
    case "$COMPRESSION_LEVEL" in
        fast)
            COMPRESS_OPTS="$COMPRESS_FAST"
            ;;
        balanced)
            COMPRESS_OPTS="$COMPRESS_BALANCED"
            ;;
        small)
            COMPRESS_OPTS="$COMPRESS_SMALL"
            ;;
    esac

    # ========================================================================
    # Path Configuration
    # ========================================================================

    local LXC_PATH
    if [[ "$PRIVILEGED" == true ]]; then
        LXC_PATH="/var/lib/lxc"
    else
        LXC_PATH="${HOME}/.local/share/lxc"
    fi

    local CONTAINER_PATH="${LXC_PATH}/${CONTAINER_NAME}"

    # Get the directory where this script is located
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # ========================================================================
    # Validation
    # ========================================================================

    # Verify container exists
    if [[ ! -d "$CONTAINER_PATH" ]]; then
        print_error "Container '${CONTAINER_NAME}' not found at ${CONTAINER_PATH}"
        exit 66  # EX_NOINPUT
    fi

    # Verify backup directory exists or create it
    if [[ ! -d "$BACKUP_DIR" ]]; then
        print_info "Creating backup directory: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
    fi

    # Resolve backup directory to absolute path
    BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

    # ========================================================================
    # Perform Backup
    # ========================================================================

    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_FILE="${BACKUP_DIR}/${CONTAINER_NAME}_${TIMESTAMP}.tar.7z"

    print_info "Backing up container: ${CONTAINER_NAME}"
    print_info "Container path: ${CONTAINER_PATH}"
    print_info "Backup file: ${BACKUP_FILE}"
    print_info "Compression: ${COMPRESSION_LEVEL}"
    echo ""

    # Check if container is running
    if lxc-info -n "${CONTAINER_NAME}" -s 2>/dev/null | grep -q "RUNNING"; then
        print_warning "Container '${CONTAINER_NAME}' is currently running"
        if prompt_yes_no "Stop the container before backup?" "y"; then
            print_info "Stopping container..."
            if [[ -x "${SCRIPT_DIR}/stop-lxc.sh" ]]; then
                "${SCRIPT_DIR}/stop-lxc.sh" "$CONTAINER_NAME"
            else
                lxc-stop --name "$CONTAINER_NAME"
            fi
            echo ""
        else
            print_warning "Backing up a running container may result in inconsistent data"
            if ! prompt_yes_no "Continue anyway?" "n"; then
                print_info "Backup cancelled by user"
                exit 75  # EX_TEMPFAIL
            fi
        fi
    fi

    # Perform backup
    print_info "Creating backup archive (this may take a while)..."
    print_info "Using sudo to read all rootfs files..."
    echo ""

    # Use tar to archive with numeric ownership, pipe to 7z for compression
    # We cd to LXC_PATH and archive the container directory by name to get clean paths
    if sudo tar --xattrs --xattrs-include='*' --acls --numeric-owner -cvf - -C "$LXC_PATH" "$CONTAINER_NAME" | \
       7z a -si $COMPRESS_OPTS "$BACKUP_FILE"; then
        echo ""
        local BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        print_success "Backup completed successfully!"
        print_info "File: ${BACKUP_FILE}"
        print_info "Size: ${BACKUP_SIZE}"
    else
        print_error "Backup failed"
        # Clean up partial backup file if it exists
        [[ -f "$BACKUP_FILE" ]] && rm -f "$BACKUP_FILE"
        exit 74  # EX_IOERR
    fi
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
