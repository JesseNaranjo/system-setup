#!/usr/bin/env bash

# system-setup.sh - System configuration and package management orchestrator
# Implements configurations from nano.md, screen-gnu.md, and shell.md
#
# Usage: ./system-setup.sh
#
# This script orchestrates multiple focused configuration modules:
# - APT sources modernization
# - Package management (apt/Homebrew)
# - System configuration (nano, screen, shell)
# - Swap memory setup
# - Container static IP configuration
# - OpenSSH server socket configuration
# - /etc/issue network interface display
#
# The script automatically detects Linux vs macOS and configures appropriately.
# It provides options for user-specific or system-wide installation.

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Self-Update Functionality
# ============================================================================

# List of all scripts to download/update
get_script_list() {
    echo "system-setup.sh"
    echo "utils.sh"
    echo "modules/modernize-apt-sources.sh"
    echo "modules/package-management.sh"
    echo "modules/system-configuration.sh"
    echo "modules/system-configuration-swap.sh"
    echo "modules/configure-container-static-ip.sh"
    echo "modules/system-configuration-openssh-server.sh"
    echo "modules/system-configuration-issue.sh"
}

# Download and check for updates on all scripts
self_update() {
    local REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/system-setup"
    local updated_count=0
    local failed_count=0

    # Check for curl or wget availability
    DOWNLOAD_CMD=""
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
    else
        # Display large error message if neither curl nor wget is available
        echo ""
        echo -e "${YELLOW}╔═════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║                                                                             ║${NC}"
        echo -e "${YELLOW}║                      ⚠️   SELF-UPDATE NOT AVAILABLE  ⚠️                       ║${NC}"
        echo -e "${YELLOW}║                                                                             ║${NC}"
        echo -e "${YELLOW}║        Neither 'curl' nor 'wget' is installed on this system.               ║${NC}"
        echo -e "${YELLOW}║        Self-updating functionality requires one of these tools.             ║${NC}"
        echo -e "${YELLOW}║                                                                             ║${NC}"
        echo -e "${YELLOW}║        To enable self-updating, please install one of the following:        ║${NC}"
        echo -e "${YELLOW}║          • curl  (recommended)                                              ║${NC}"
        echo -e "${YELLOW}║          • wget                                                             ║${NC}"
        echo -e "${YELLOW}║                                                                             ║${NC}"
        echo -e "${YELLOW}║        Installation commands:                                               ║${NC}"
        echo -e "${YELLOW}║          macOS:    brew install curl                                        ║${NC}"
        echo -e "${YELLOW}║          Debian:   apt install curl                                         ║${NC}"
        echo -e "${YELLOW}║          RHEL:     yum install curl                                         ║${NC}"
        echo -e "${YELLOW}║                                                                             ║${NC}"
        echo -e "${YELLOW}║        Continuing with local version of the scripts...                      ║${NC}"
        echo -e "${YELLOW}║                                                                             ║${NC}"
        echo -e "${YELLOW}╚═════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        return 0
    fi

    # Check each script for updates
    while IFS= read -r script_path; do
        local SCRIPT_FILE="$script_path"
        local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
        local TEMP_SCRIPT_FILE="$(mktemp)"

        # Ensure the local directory exists
        local script_dir=$(dirname "$LOCAL_SCRIPT")
        mkdir -p "$script_dir"

        echo "▶ Fetching ${REMOTE_BASE}/${SCRIPT_FILE}..."

        DOWNLOAD_SUCCESS=false
        if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
            if curl -H 'Cache-Control: no-cache, no-store' -o "${TEMP_SCRIPT_FILE}" -fsSL "${REMOTE_BASE}/${SCRIPT_FILE}"; then
                DOWNLOAD_SUCCESS=true
            fi
        elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
            if wget --no-cache --no-cookies -O "${TEMP_SCRIPT_FILE}" -q "${REMOTE_BASE}/${SCRIPT_FILE}"; then
                DOWNLOAD_SUCCESS=true
            fi
        fi

        if [[ "$DOWNLOAD_SUCCESS" == true ]]; then
            # Check if local file exists and compare
            if [[ -f "$LOCAL_SCRIPT" ]]; then
                if diff -u "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
                    echo -e "${GREEN}  ✓ ${SCRIPT_FILE} is already up-to-date${NC}"
                    rm -f "${TEMP_SCRIPT_FILE}"
                else
                    echo -e "${YELLOW}  ⚠ Updates found for ${SCRIPT_FILE}${NC}"
                    ((updated_count++)) || true
                    # Store temp file for later processing
                    mv "${TEMP_SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}.${SCRIPT_FILE//\//_}"
                fi
            else
                # New file, doesn't exist locally
                echo -e "${YELLOW}  + New file: ${SCRIPT_FILE}${NC}"
                ((updated_count++)) || true
                mv "${TEMP_SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}.${SCRIPT_FILE//\//_}"
            fi
        else
            echo -e "${RED}  ✖ Download failed — skipping ${SCRIPT_FILE}${NC}"
            rm -f "${TEMP_SCRIPT_FILE}"
            ((failed_count++)) || true
        fi
    done < <(get_script_list)

    echo ""

    # If there are updates, ask user if they want to apply them
    if [[ $updated_count -gt 0 ]]; then
        echo -e "${YELLOW}Found updates for $updated_count script(s)${NC}"
        echo ""

        if prompt_yes_no "Would you like to view the changes and apply updates?" "y"; then
            echo ""
            # Show diffs and apply updates
            while IFS= read -r script_path; do
                local SCRIPT_FILE="$script_path"
                local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
                local TEMP_FILE="/tmp/$(basename "$(mktemp)").${SCRIPT_FILE//\//_}"

                if [[ -f "$TEMP_FILE" ]]; then
                    echo -e "${LINE_COLOR}╭───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╮${NC}"

                    if [[ -f "$LOCAL_SCRIPT" ]]; then
                        diff -u --color "${LOCAL_SCRIPT}" "${TEMP_FILE}" || true
                    else
                        echo -e "${GREEN}New file${NC}"
                        cat "${TEMP_FILE}"
                    fi

                    echo -e "${LINE_COLOR}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${NC}"
                    echo ""

                    if prompt_yes_no "Apply this update?" "y"; then
                        chmod +x "$TEMP_FILE"
                        mv -f "$TEMP_FILE" "$LOCAL_SCRIPT"
                        echo -e "${GREEN}  ✓ Updated ${SCRIPT_FILE}${NC}"
                    else
                        rm -f "$TEMP_FILE"
                        echo -e "${YELLOW}  - Skipped ${SCRIPT_FILE}${NC}"
                    fi
                    echo ""
                fi
            done < <(get_script_list)

            echo -e "${GREEN}Update process complete${NC}"
            echo ""

            if prompt_yes_no "Restart system-setup.sh with the updated version?" "y"; then
                echo ""
                export scriptUpdated=1
                exec "${SCRIPT_DIR}/system-setup.sh" "$@"
                exit 0
            fi
        else
            # Clean up temp files
            while IFS= read -r script_path; do
                local SCRIPT_FILE="$script_path"
                local TEMP_FILE="/tmp/$(basename "$(mktemp)").${SCRIPT_FILE//\//_}"
                rm -f "$TEMP_FILE"
            done < <(get_script_list)

            echo ""
            echo -e "${YELLOW}→ Running local unmodified copies...${NC}"
            echo ""
        fi
    elif [[ $failed_count -eq 0 ]]; then
        echo -e "${GREEN}All scripts are up-to-date${NC}"
        echo ""
    fi
}

# ============================================================================
# Main Orchestration
# ============================================================================

main() {
    # Only run self-update if not already updated in this session
    if [[ ${scriptUpdated:-0} -eq 0 ]]; then
        self_update "$@"
    fi

    print_info "System Setup and Configuration Script (Idempotent Mode)"
    echo "          ======================================================="

    if [[ $# -ne 0 && $1 == "--debug" ]]; then
        DEBUG_MODE=true
        print_debug "- DEBUG MODE ENABLED"
    fi

    detect_os
    echo "          - Detected OS: $DETECTED_OS"

    if [[ "$DETECTED_OS" == "unknown" ]]; then
        print_error "Unknown operating system. This script supports Linux and macOS."
        exit 1
    fi

    # Detect if running in a container (sets RUNNING_IN_CONTAINER global variable)
    detect_container
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        echo "          - Running inside a container environment"

        # Offer to configure static IP for containers
        echo ""
        "${SCRIPT_DIR}/modules/configure-container-static-ip.sh"
    fi
    echo ""

    # Step 1: Modernize APT sources (Linux only)
    if [[ "$DETECTED_OS" == "linux" ]]; then
        "${SCRIPT_DIR}/modules/modernize-apt-sources.sh"
        echo ""
    fi

    # Step 2: Package Management
    print_info "Step 1: Package Management"
    print_info "---------------------------"
    if ! "${SCRIPT_DIR}/modules/package-management.sh"; then
        print_error "Package management failed. Continuing with configuration for installed packages..."
    fi
    echo ""

    # Get user preferences for configuration scope
    print_info "Step 2: Configuration"
    print_info "---------------------"
    print_info "This script will configure:"
    if [[ "$NANO_INSTALLED" == true ]]; then
        echo "          ✓ nano editor settings"
    else
        echo "          ✗ nano editor (not installed, will be skipped)"
    fi
    if [[ "$SCREEN_INSTALLED" == true ]]; then
        echo "          ✓ GNU screen settings"
    else
        echo "          ✗ GNU screen (not installed, will be skipped)"
    fi
    if [[ "$OPENSSH_SERVER_INSTALLED" == true ]]; then
        echo "          ✓ OpenSSH Server (socket-based activation option)"
    else
        echo "          ✗ OpenSSH Server (not installed, will be skipped)"
    fi
    echo "          ✓ Shell aliases and configurations"
    echo ""

    print_info "The script will only add or update configurations that are missing or different."
    print_info "Existing configurations matching the desired values will be left unchanged."
    echo ""

    # Ask for scope (user vs system) for all components
    print_info "Choose configuration scope:"
    echo "          1) User-specific - nano/screen/shell for current user"
    echo "          2) System-wide (root) - nano/screen system-wide, /etc/issue, shell all users, swap, SSH socket"
    echo "          Ctrl+C to cancel configuration and exit"
    echo ""
    read -p "          Enter choice (1-2): " -r scope_choice

    local scope
    case "$scope_choice" in
        1) scope="user" ;;
        2) scope="system" ;;
        *)
            print_error "Invalid choice. Aborting."
            exit 1
            ;;
    esac

    # Verify privileges for system-wide configuration on Linux
    if [[ "$scope" == "system" ]]; then
        if ! check_privileges "system_config"; then
            echo ""
            print_error "System-wide configuration requires root privileges on Linux"
            print_info "Please re-run the script with: sudo $0"
            exit 1
        fi
    fi

    print_info "Using scope: $scope"
    echo ""

    # Step 3: System Configuration (nano, screen, shell)
    "${SCRIPT_DIR}/modules/system-configuration.sh" "$scope"
    echo ""

    # Step 4: Swap configuration (system scope only, Linux only)
    if [[ "$scope" == "system" ]]; then
        "${SCRIPT_DIR}/modules/system-configuration-swap.sh"
        echo ""
    fi

    # Step 5: Static IP configuration (containers only, already done above if in container)
    # Skip here as it was already offered at the beginning

    # Step 6: OpenSSH Server configuration (system scope only, Linux only)
    if [[ "$scope" == "system" ]]; then
        if [[ "$OPENSSH_SERVER_INSTALLED" == true ]]; then
            "${SCRIPT_DIR}/modules/system-configuration-openssh-server.sh"
        else
            print_info "Skipping OpenSSH Server configuration (not installed)"
        fi
        echo ""
    fi

    # Step 7: /etc/issue configuration (system scope only, Linux only)
    if [[ "$scope" == "system" ]]; then
        "${SCRIPT_DIR}/modules/system-configuration-issue.sh"
        echo ""
    fi

    print_success "Setup complete!"
    echo ""

    print_summary
    echo ""

    print_info "The script made only necessary changes to bring your configuration up to date."
    print_info "You may need to restart your terminal or source your shell configuration file for all changes to take effect."
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
