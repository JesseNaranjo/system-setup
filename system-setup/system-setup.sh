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
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

readonly REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/system-setup"

# List of module scripts to download/update (excludes system-setup.sh and utils.sh)
get_script_list() {
    echo "system-modules/configure-container-static-ip.sh"
    echo "system-modules/migrate-to-systemd-networkd.sh"
    echo "system-modules/modernize-apt-sources.sh"
    echo "system-modules/package-management.sh"
    echo "system-modules/system-configuration-issue.sh"
    echo "system-modules/system-configuration-openssh-server.sh"
    echo "system-modules/system-configuration-swap.sh"
    echo "system-modules/system-configuration.sh"
}

# ============================================================================
# Self-Update Functionality
# ============================================================================

# Detect available download command (curl or wget)
# Sets global DOWNLOAD_CMD variable
detect_download_cmd() {
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
        return 0
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
        return 0
    else
        DOWNLOAD_CMD=""
        # Display large error message if neither curl nor wget is available
        echo ""
        echo -e "            ${YELLOW}╔═════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║                        ⚠️   UPDATES NOT AVAILABLE  ⚠️                         ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║        Neither 'curl' nor 'wget' is installed on this system.               ║${NC}"
        echo -e "            ${YELLOW}║        Self-updating functionality requires one of these tools.             ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║        To enable self-updating, please install one of the following:        ║${NC}"
        echo -e "            ${YELLOW}║          • curl  (recommended)                                              ║${NC}"
        echo -e "            ${YELLOW}║          • wget                                                             ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║        Installation commands:                                               ║${NC}"
        echo -e "            ${YELLOW}║          macOS:    brew install curl                                        ║${NC}"
        echo -e "            ${YELLOW}║          Debian:   apt install curl                                         ║${NC}"
        echo -e "            ${YELLOW}║          RHEL:     yum install curl                                         ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║        Continuing with local version of the scripts...                      ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}╚═════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        return 1
    fi
}

# Download a script file from the remote repository
# Args: $1 = script filename (relative path), $2 = output file path
# Returns: 0 on success, 1 on failure
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

# Check for updates to system-setup.sh and utils.sh
# Will restart system-setup.sh if either file is updated
self_update() {
    local setup_updated=false
    local utils_updated=false
    local any_updated=false

    # Check system-setup.sh
    local SETUP_FILE="system-setup.sh"
    local LOCAL_SETUP="${SCRIPT_DIR}/${SETUP_FILE}"
    local TEMP_SETUP="$(mktemp)"

    if download_script "${SETUP_FILE}" "${TEMP_SETUP}"; then
        if diff -u "${LOCAL_SETUP}" "${TEMP_SETUP}" > /dev/null 2>&1; then
            print_success "- ${SETUP_FILE} is already up-to-date"
            rm -f "${TEMP_SETUP}"
            echo ""
        else
            echo ""
            echo -e "${CYAN}╭────────────────────────────────────────────────── Δ detected in ${SETUP_FILE} ──────────────────────────────────────────────────╮${NC}"
            diff -u --color "${LOCAL_SETUP}" "${TEMP_SETUP}" || true
            echo -e "${CYAN}╰───────────────────────────────────────────────────────── ${SETUP_FILE} ─────────────────────────────────────────────────────────╯${NC}"
            echo ""

            if prompt_yes_no "→ Overwrite ${SETUP_FILE} with updated version?" "y"; then
                echo ""
                chmod +x "${TEMP_SETUP}"
                mv -f "${TEMP_SETUP}" "${LOCAL_SETUP}"
                print_success "✓ Updated ${SETUP_FILE}"
                setup_updated=true
                any_updated=true
            else
                print_warning "⚠ Skipped ${SETUP_FILE} update"
                rm -f "${TEMP_SETUP}"
            fi
            echo ""
        fi
    else
        rm -f "${TEMP_SETUP}"
        echo ""
    fi

    # Check utils.sh
    local UTILS_FILE="utils.sh"
    local LOCAL_UTILS="${SCRIPT_DIR}/${UTILS_FILE}"
    local TEMP_UTILS="$(mktemp)"

    if download_script "${UTILS_FILE}" "${TEMP_UTILS}"; then
        if diff -u "${LOCAL_UTILS}" "${TEMP_UTILS}" > /dev/null 2>&1; then
            print_success "- ${UTILS_FILE} is already up-to-date"
            rm -f "${TEMP_UTILS}"
            echo ""
        else
            echo ""
            echo -e "${CYAN}╭────────────────────────────────────────────────── Δ detected in ${UTILS_FILE} ──────────────────────────────────────────────────╮${NC}"
            diff -u --color "${LOCAL_UTILS}" "${TEMP_UTILS}" || true
            echo -e "${CYAN}╰───────────────────────────────────────────────────────── ${UTILS_FILE} ─────────────────────────────────────────────────────────╯${NC}"
            echo ""

            if prompt_yes_no "→ Overwrite ${UTILS_FILE} with updated version?" "y"; then
                echo ""
                mv -f "${TEMP_UTILS}" "${LOCAL_UTILS}"
                print_success "✓ Updated ${UTILS_FILE}"
                utils_updated=true
                any_updated=true
            else
                print_warning "⚠ Skipped ${UTILS_FILE} update"
                rm -f "${TEMP_UTILS}"
            fi
            echo ""
        fi
    else
        rm -f "${TEMP_UTILS}"
        echo ""
    fi

    # Restart if either file was updated
    if [[ "$any_updated" == true ]]; then
        if [[ "$setup_updated" == true && "$utils_updated" == true ]]; then
            print_success "✓ Both ${SETUP_FILE} and ${UTILS_FILE} were updated - restarting..."
        elif [[ "$setup_updated" == true ]]; then
            print_success "✓ ${SETUP_FILE} was updated - restarting..."
        else
            print_success "✓ ${UTILS_FILE} was updated - restarting..."
        fi
        echo ""
        export scriptUpdated=1
        exec "${LOCAL_SETUP}" "$@"
        exit 0
    fi
}

# Update all module scripts (system-modules/*)
# Downloads each module script and prompts user to replace if different
# Continues processing all modules even if some downloads fail
# Returns: 1 if any downloads failed, 0 otherwise
update_modules() {
    local uptodate_count=0
    local updated_count=0
    local skipped_count=0
    local failed_count=0

    print_info "Checking for module updates..."
    echo ""

    # Check each module script for updates
    while IFS= read -r script_path; do
        local SCRIPT_FILE="$script_path"
        local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
        local TEMP_SCRIPT_FILE="$(mktemp)"

        # Ensure the local directory exists
        local script_dir="$(dirname "$LOCAL_SCRIPT")"
        mkdir -p "$script_dir"

        if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
            echo "            (skipping ${SCRIPT_FILE})"
            ((failed_count++)) || true
            rm -f "${TEMP_SCRIPT_FILE}"
            echo ""
            continue
        fi

        # Create file if it doesn't exist
        if [[ ! -f "${LOCAL_SCRIPT}" ]]; then
            touch "${LOCAL_SCRIPT}"
        fi

        # Compare and handle differences
        if diff -u "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
            print_success "- ${SCRIPT_FILE} is already up-to-date"
            ((uptodate_count++)) || true
            rm -f "${TEMP_SCRIPT_FILE}"
            echo ""
        else
            echo ""
            echo -e "${CYAN}╭────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${NC}"
            diff -u --color "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" || true
            echo -e "${CYAN}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${NC}"
            echo ""

            if prompt_yes_no "→ Overwrite local ${SCRIPT_FILE} with remote copy?" "y"; then
                echo ""
                chmod +x "${TEMP_SCRIPT_FILE}"
                mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"
                print_success "✓ Replaced ${SCRIPT_FILE}"
                ((updated_count++)) || true
            else
                print_warning "⚠ Skipped ${SCRIPT_FILE}"
                ((skipped_count++)) || true
                rm -f "${TEMP_SCRIPT_FILE}"
            fi
            echo ""
        fi
    done < <(get_script_list)

    # Display final statistics
    echo ""
    echo "============================================================================"
    print_info "Module Update Summary"
    echo "============================================================================"
    echo -e "${BLUE}Up-to-date:${NC}  ${uptodate_count} file(s)"
    echo -e "${GREEN}Updated:${NC}     ${updated_count} file(s)"
    echo -e "${YELLOW}Skipped:${NC}     ${skipped_count} file(s)"
    echo -e "${RED}Failed:${NC}      ${failed_count} file(s)"
    echo "============================================================================"
    echo ""

    if [[ $failed_count -gt 0 ]]; then
        return 1
    fi
}

# ============================================================================
# Main Orchestration
# ============================================================================

main() {
    # Detect download command (curl or wget) for update functionality
    if detect_download_cmd; then
        # Only run self-update if not already updated in this session
        if [[ ${scriptUpdated:-0} -eq 0 ]]; then
            self_update "$@"
        fi

        # Always check for module updates (not skipped by scriptUpdated) if download cmd available
        update_modules
    fi

    print_info "System Setup and Configuration Script (Idempotent Mode)"
    echo "            ======================================================="

    if [[ $# -ne 0 && $1 == "--debug" ]]; then
        DEBUG_MODE=true
        print_debug "- DEBUG MODE ENABLED"
    fi

    detect_os
    echo "            - Detected OS: $DETECTED_OS"

    if [[ "$DETECTED_OS" == "unknown" ]]; then
        print_error "Unknown operating system. This script supports Linux and macOS."
        exit 1
    fi

    # Detect if running in a container (sets RUNNING_IN_CONTAINER global variable)
    detect_container
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        echo "            - Running inside a container environment"
    fi
    echo ""

    # Network migration from ifupdown to systemd-networkd (Linux only, before container static IP)
    if [[ "$DETECTED_OS" == "linux" ]]; then
        source "${SCRIPT_DIR}/system-modules/migrate-to-systemd-networkd.sh"
        main_migrate_to_systemd_networkd
        echo ""
    fi

    # Offer to configure static IP for containers
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        source "${SCRIPT_DIR}/system-modules/configure-container-static-ip.sh"
        main_configure_container_static_ip
        echo ""
    fi

    # Step 1: Modernize APT sources (Linux only)
    if [[ "$DETECTED_OS" == "linux" ]]; then
        source "${SCRIPT_DIR}/system-modules/modernize-apt-sources.sh"
        main_modernize_apt_sources
        echo ""
    fi

    # Step 2: Package Management
    print_info "Step 1: Package Management"
    print_info "---------------------------"
    source "${SCRIPT_DIR}/system-modules/package-management.sh"
    if ! main_manage_packages; then
        print_error "Package management failed. Continuing with configuration for installed packages..."
    fi
    echo ""

    # Get user preferences for configuration scope
    print_info "Step 2: Configuration"
    print_info "---------------------"
    print_info "This script will configure:"
    if [[ "$NANO_INSTALLED" == true ]]; then
        echo "            ✓ nano editor settings"
    else
        echo "            ✖ nano editor (not installed, will be skipped)"
    fi
    if [[ "$SCREEN_INSTALLED" == true ]]; then
        echo "            ✓ GNU screen settings"
    else
        echo "            ✖ GNU screen (not installed, will be skipped)"
    fi
    if [[ "$OPENSSH_SERVER_INSTALLED" == true ]]; then
        echo "            ✓ OpenSSH Server (socket-based activation option)"
    else
        echo "            ✖ OpenSSH Server (not installed, will be skipped)"
    fi
    echo "            ✓ Shell aliases and configurations"
    echo ""

    print_info "The script will only add or update configurations that are missing or different."
    print_info "Existing configurations matching the desired values will be left unchanged."
    echo ""

    # Ask for scope (user vs system) for all components
    print_info "Choose configuration scope:"
    echo "            1) User-specific - nano/screen/shell for current user"
    echo "            2) System-wide (root) - nano/screen system-wide, /etc/issue, shell all users, swap, SSH socket"
    echo "            Ctrl+C to cancel configuration and exit"
    echo ""
    read -p "            Enter choice (1-2): " -r scope_choice

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
    source "${SCRIPT_DIR}/system-modules/system-configuration.sh"
    main_configure_system "$scope"
    echo ""

    # Step 4: Swap configuration (system scope only, Linux only)
    if [[ "$scope" == "system" ]]; then
        source "${SCRIPT_DIR}/system-modules/system-configuration-swap.sh"
        main_configure_swap
        echo ""
    fi

    # Step 5: Static IP configuration (containers only, already done above if in container)
    # Skip here as it was already offered at the beginning

    # Step 6: OpenSSH Server configuration (system scope only, Linux only)
    if [[ "$scope" == "system" ]]; then
        if [[ "$OPENSSH_SERVER_INSTALLED" == true ]]; then
            source "${SCRIPT_DIR}/system-modules/system-configuration-openssh-server.sh"
            main_configure_openssh_server
        else
            print_info "Skipping OpenSSH Server configuration (not installed)"
        fi
        echo ""
    fi

    # Step 7: /etc/issue configuration (system scope only, Linux only)
    if [[ "$scope" == "system" ]]; then
        source "${SCRIPT_DIR}/system-modules/system-configuration-issue.sh"
        main_configure_issue
        echo ""
    fi

    print_success "Setup complete!"
    print_session_summary
    echo ""

    print_info "The script made only necessary changes to bring your configuration up to date."
    print_info "You may need to restart your terminal or source your shell configuration file for all changes to take effect."
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
