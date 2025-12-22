#!/usr/bin/env bash

# pkgs-helper.sh - Package management helper utilities
# Provides interactive menu for common package manager operations
# Supports: apt (Debian/Ubuntu), dnf (Fedora/RHEL 8+), zypper (openSUSE)
#
# Usage: ./pkgs-helper.sh
#
# This script provides the following operations:
# - List packages upgradeable from backports repository (apt only)
# - List and optionally purge packages with residual configs (apt only)
# - Run autoremove to clean up unused packages (apt, dnf)
# - Clean package cache (apt, dnf, zypper)
#
# Note: This script is downloaded/updated by system-setup.sh but runs independently.

set -euo pipefail

# Get the directory where this script is located
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Feature Support Detection
# ============================================================================

# Check if the current package manager supports backports listing
# Returns: 0 if supported, 1 if not
supports_backports() {
    [[ "$DETECTED_PKG_MANAGER" == "apt" ]]
}

# Check if the current package manager supports residual config management
# Returns: 0 if supported, 1 if not
supports_residual_configs() {
    [[ "$DETECTED_PKG_MANAGER" == "apt" ]]
}

# Check if the current package manager supports autoremove
# Returns: 0 if supported, 1 if not
supports_autoremove() {
    [[ "$DETECTED_PKG_MANAGER" == "apt" ]] || [[ "$DETECTED_PKG_MANAGER" == "dnf" ]] || [[ "$DETECTED_PKG_MANAGER" == "zypper" ]]
}

# Check if the current package manager supports cache cleaning
# Returns: 0 if supported, 1 if not
supports_clean_cache() {
    [[ "$DETECTED_PKG_MANAGER" == "apt" ]] || [[ "$DETECTED_PKG_MANAGER" == "dnf" ]] || [[ "$DETECTED_PKG_MANAGER" == "zypper" ]]
}

# ============================================================================
# Helper Functions
# ============================================================================

# Get the release codename from /etc/os-release (apt/Debian-specific)
# Returns: codename via stdout
get_release_codename() {
    local release=$(grep "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [[ -z "$release" ]]; then
        release=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    fi
    echo "$release"
}

# Print a menu option with availability status
# Usage: print_menu_option <number> <description> <support_function>
print_menu_option() {
    local number="$1"
    local description="$2"
    local support_func="$3"

    if $support_func; then
        echo "            ${number}) ${description}"
    else
        echo "            ${number}) (Not Available) ${description}"
    fi
}

# Check feature availability and print message if not supported
# Usage: check_feature_available <feature_name> <support_function>
# Returns: 0 if available, 1 if not (prints message)
check_feature_available() {
    local feature_name="$1"
    local support_func="$2"

    if ! $support_func; then
        print_warning "${feature_name} is not available for ${DETECTED_PKG_MANAGER}."
        echo ""
        return 1
    fi
    return 0
}

# ============================================================================
# Menu Option Functions
# ============================================================================

# Option 1: List packages upgradeable from backports (apt only)
list_backports_upgrades() {
    if ! check_feature_available "Backports listing" supports_backports; then
        return 0
    fi

    print_info "Listing packages upgradeable from backports..."
    echo ""

    # Check if aptitude is installed
    if ! command -v aptitude &>/dev/null; then
        print_error "aptitude is not installed. Please install it with: sudo apt install aptitude"
        return 1
    fi

    local release=$(get_release_codename)

    if [[ -z "$release" ]]; then
        print_error "Could not determine release codename from /etc/os-release"
        return 1
    fi

    print_info "Release: ${release}"
    print_info "Searching for upgradeable packages in ${release}-backports..."
    echo ""

    aptitude -t "${release}-backports" search '~U' || true
    echo ""

    print_success "Backports search complete."
    echo ""
}

# Option 2: List packages with residual configs and optionally purge them (apt only)
list_residual_configs() {
    if ! check_feature_available "Residual config management" supports_residual_configs; then
        return 0
    fi

    print_info "Listing packages with residual configuration files..."
    echo ""

    # Capture the output of apt list '~c'
    local output=$(apt list '~c' 2>/dev/null) || true

    # Check if there are any results (filter out the "Listing..." header line)
    local packages=$(echo "$output" | grep -v "^Listing" | grep -v "^$" || true)

    if [[ -z "$packages" ]]; then
        print_success "No packages with residual configuration files found."
        echo ""
        return 0
    fi

    # Display the packages
    echo "$output"
    echo ""

    # Prompt user to purge
    if prompt_yes_no "→ Do you want to purge these residual configuration files?" "n"; then
        echo ""
        print_info "Purging residual configuration files..."
        run_elevated apt purge '~c'
        echo ""
        print_success "Residual configuration files purged."
    else
        print_info "Skipped purging residual configuration files."
    fi
    echo ""
}

# Option 3: Run autoremove (apt, dnf)
run_autoremove() {
    if ! check_feature_available "Autoremove" supports_autoremove; then
        return 0
    fi

    print_info "Running autoremove to clean up unused packages..."
    echo ""

    case "$DETECTED_PKG_MANAGER" in
        apt)
            run_elevated apt autoremove
            ;;
        dnf)
            run_elevated dnf autoremove
            ;;
        zypper)
            run_elevated zypper packages --unneeded
            ;;
    esac
    echo ""

    print_success "Autoremove complete."
    echo ""
}

# Option 4: Clean package cache (apt, dnf)
clean_cache() {
    if ! check_feature_available "Cache cleaning" supports_clean_cache; then
        return 0
    fi

    print_info "Cleaning package cache..."
    echo ""

    case "$DETECTED_PKG_MANAGER" in
        apt)
            run_elevated apt clean
            ;;
        dnf)
            run_elevated dnf clean all
            ;;
        zypper)
            run_elevated zypper clean --all
            ;;
    esac
    echo ""

    print_success "Package cache cleaned."
    echo ""
}

# ============================================================================
# Main Function
# ============================================================================

main() {
    # Detect OS and package manager
    detect_os
    detect_package_manager

    # Verify we have a supported package manager
    if [[ "$DETECTED_PKG_MANAGER" == "unknown" ]]; then
        print_error "No supported package manager found."
        print_error "This script supports: apt (Debian/Ubuntu), dnf (Fedora/RHEL 8+), zypper (openSUSE)"
        exit 1
    fi

    print_info "Package Helper (using ${DETECTED_PKG_MANAGER})"
    echo "            ===================="
    echo ""

    # Main menu loop
    while true; do
        # Display menu with availability indicators
        print_info "Select an operation:"
        print_menu_option "1" "List packages upgradeable from backports" supports_backports
        print_menu_option "2" "List packages with residual configs (and optionally purge)" supports_residual_configs
        print_menu_option "3" "Run autoremove" supports_autoremove
        print_menu_option "4" "Clean package cache" supports_clean_cache
        echo "            5) Exit (or Ctrl+C)"
        echo ""
        read -p "            Enter choice (1-5): " -r choice

        echo ""

        case "$choice" in
            1)
                list_backports_upgrades
                ;;
            2)
                list_residual_configs
                ;;
            3)
                run_autoremove
                ;;
            4)
                clean_cache
                ;;
            5)
                print_info "Exiting."
                exit 0
                ;;
            *)
                print_error "Invalid choice. Please try again."
                echo ""
                ;;
        esac
    done
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
