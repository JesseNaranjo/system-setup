#!/usr/bin/env bash

# restore-lxc.sh - Restore an LXC container from a compressed archive
#
# Usage: ./restore-lxc.sh <backup_file> [container_name] [--privileged]
#
# This script:
# - Restores an LXC container from a .tar.7z archive created by backup-lxc.sh
# - Preserves all numeric ownership and permissions using tar --numeric-owner
# - Optionally renames the container during restore
# - Offers to edit the config file before starting the container
# - Works with both unprivileged (default) and privileged containers
#
# Arguments:
#   backup_file     Path to the .tar.7z backup archive (required)
#   container_name  Name for the restored container (default: original name from backup)
#   --privileged    Restore to /var/lib/lxc/ instead of ~/.local/share/lxc/
#
# Note: Requires sudo to restore files with correct ownership in the container's rootfs.

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
# Input Validation
# ============================================================================

show_usage() {
    echo "Usage: ${0##*/} <backup_file> [container_name] [--privileged]"
    echo ""
    echo "Arguments:"
    echo "  backup_file     Path to the .tar.7z backup archive (required)"
    echo "  container_name  Name for the restored container (default: original name from backup)"
    echo "  --privileged    Restore to /var/lib/lxc/ instead of ~/.local/share/lxc/"
    echo ""
    echo "Examples:"
    echo "  ${0##*/} my-container_20241222_120000.tar.7z"
    echo "  ${0##*/} my-container_20241222_120000.tar.7z new-container-name"
    echo "  ${0##*/} my-container_20241222_120000.tar.7z --privileged"
}

check_required_tools() {
    for tool in tar 7z nano; do
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
    local BACKUP_FILE=""
    local CONTAINER_NAME=""
    local PRIVILEGED=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --privileged)
                PRIVILEGED=true
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
                if [[ -z "$BACKUP_FILE" ]]; then
                    BACKUP_FILE="$1"
                else
                    CONTAINER_NAME="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$BACKUP_FILE" ]]; then
        print_error "Missing required backup file argument"
        echo ""
        show_usage
        exit 64  # EX_USAGE
    fi

    # Verify backup file exists
    if [[ ! -f "$BACKUP_FILE" ]]; then
        print_error "Backup file not found: ${BACKUP_FILE}"
        exit 66  # EX_NOINPUT
    fi

    # Resolve backup file to absolute path
    BACKUP_FILE="$(cd "$(dirname "$BACKUP_FILE")" && pwd)/$(basename "$BACKUP_FILE")"

    # ========================================================================
    # Path Configuration
    # ========================================================================

    local LXC_PATH
    if [[ "$PRIVILEGED" == true ]]; then
        LXC_PATH="/var/lib/lxc"
    else
        LXC_PATH="${HOME}/.local/share/lxc"
    fi

    # Get the directory where this script is located
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # ========================================================================
    # Detect Original Container Name from Archive
    # ========================================================================

    print_info "Inspecting backup archive..."

    # List the first entry in the tar archive to get the container directory name
    # The archive structure is: <container_name>/config, <container_name>/rootfs/...
    # We pipe the tar from 7z and list its contents, extracting the top-level directory
    local ORIGINAL_NAME=$(7z x -so "$BACKUP_FILE" 2>/dev/null | tar -tf - 2>/dev/null | head -1 | cut -d'/' -f1)

    if [[ -z "$ORIGINAL_NAME" ]]; then
        print_error "Could not determine container name from backup archive"
        print_info "The archive may be corrupted or in an unexpected format"
        exit 65  # EX_DATAERR
    fi

    print_info "Original container name: ${ORIGINAL_NAME}"

    # Use original name if no override specified
    if [[ -z "$CONTAINER_NAME" ]]; then
        CONTAINER_NAME="$ORIGINAL_NAME"
    fi

    local CONTAINER_PATH="${LXC_PATH}/${CONTAINER_NAME}"

    # ========================================================================
    # Pre-restore Checks
    # ========================================================================

    print_info "Target container name: ${CONTAINER_NAME}"
    print_info "Target path: ${CONTAINER_PATH}"
    echo ""

    # Check if container already exists
    if [[ -d "$CONTAINER_PATH" ]]; then
        print_warning "Container '${CONTAINER_NAME}' already exists at ${CONTAINER_PATH}"

        # Check if it's running
        if lxc-info -n "${CONTAINER_NAME}" -s 2>/dev/null | grep -q "RUNNING"; then
            print_warning "Container is currently running"
            if prompt_yes_no "Stop the container?" "y"; then
                print_info "Stopping container..."
                if [[ -x "${SCRIPT_DIR}/stop-lxc.sh" ]]; then
                    "${SCRIPT_DIR}/stop-lxc.sh" "$CONTAINER_NAME"
                else
                    lxc-stop --name "$CONTAINER_NAME"
                fi
            else
                print_error "Cannot restore over a running container"
                exit 75  # EX_TEMPFAIL
            fi
        fi

        if prompt_yes_no "Delete existing container and restore from backup?" "n"; then
            print_info "Removing existing container..."
            sudo rm -rf "$CONTAINER_PATH"
        else
            print_info "Restore cancelled by user"
            exit 75  # EX_TEMPFAIL
        fi
    fi

    # Ensure LXC directory exists
    if [[ ! -d "$LXC_PATH" ]]; then
        print_info "Creating LXC directory: $LXC_PATH"
        mkdir -p "$LXC_PATH"
    fi

    # ========================================================================
    # Restore Container
    # ========================================================================

    print_info "Extracting backup archive (this may take a while)..."
    print_info "Using sudo to restore files with correct ownership..."
    echo ""

    # Create a temporary directory for extraction if we need to rename
    local TEMP_DIR=""
    local EXTRACT_PATH="$LXC_PATH"

    if [[ "$CONTAINER_NAME" != "$ORIGINAL_NAME" ]]; then
        TEMP_DIR=$(mktemp -d)
        EXTRACT_PATH="$TEMP_DIR"
        print_info "Extracting to temporary directory for rename..."
    fi

    # Extract: 7z outputs to stdout, tar extracts with numeric ownership
    if 7z x -so "$BACKUP_FILE" | sudo tar --xattrs --xattrs-include='*' --acls --numeric-owner -xvf - -C "$EXTRACT_PATH"; then
        echo ""
        print_success "Archive extracted successfully"
    else
        print_error "Extraction failed"
        [[ -n "$TEMP_DIR" ]] && sudo rm -rf "$TEMP_DIR"
        exit 74  # EX_IOERR
    fi

    # Handle rename if needed
    if [[ "$CONTAINER_NAME" != "$ORIGINAL_NAME" ]]; then
        print_info "Renaming container from '${ORIGINAL_NAME}' to '${CONTAINER_NAME}'..."

        # Move the extracted directory to final location with new name
        sudo mv "${TEMP_DIR}/${ORIGINAL_NAME}" "$CONTAINER_PATH"

        # Update lxc.uts.name and lxc.rootfs.path in config file
        local CONFIG_FILE="${CONTAINER_PATH}/config"
        if [[ -f "$CONFIG_FILE" ]]; then
            print_info "Updating container name and rootfs path in config..."
            sudo sed -i "s/^lxc\.uts\.name\s*=.*/lxc.uts.name = ${CONTAINER_NAME}/" "$CONFIG_FILE"
            sudo sed -i "s|/${ORIGINAL_NAME}/rootfs|/${CONTAINER_NAME}/rootfs|g" "$CONFIG_FILE"
        fi

        # Clean up temp directory
        sudo rm -rf "$TEMP_DIR"
    fi

    # ========================================================================
    # Post-restore Configuration
    # ========================================================================

    local CONFIG_FILE="${CONTAINER_PATH}/config"

    echo ""
    print_success "Container restored to: ${CONTAINER_PATH}"
    echo ""

    # Offer to edit config
    if [[ -f "$CONFIG_FILE" ]]; then
        if prompt_yes_no "Edit the container config file before starting?" "n"; then
            print_info "Opening config in nano..."
            sudo nano "$CONFIG_FILE"
        fi
    fi

    # Offer to start container
    echo ""
    if prompt_yes_no "Start the container now?" "n"; then
        print_info "Starting container..."
        if [[ -x "${SCRIPT_DIR}/start-lxc.sh" ]]; then
            "${SCRIPT_DIR}/start-lxc.sh" "$CONTAINER_NAME"
        else
            lxc-start --name "$CONTAINER_NAME"
            print_success "Container '${CONTAINER_NAME}' started"
        fi
    else
        print_info "Container restored but not started"
        print_info "Start with: ./start-lxc.sh ${CONTAINER_NAME}"
    fi
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
