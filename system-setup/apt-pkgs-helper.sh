#!/usr/bin/env bash

# apt-pkgs-helper.sh - APT package management helper utilities
# Provides interactive menu for common apt/aptitude operations
#
# Usage: ./apt-pkgs-helper.sh
#
# This script provides the following operations:
# - List packages upgradeable from backports repository
# - List and optionally purge packages with residual configs
# - Run apt autoremove to clean up unused packages
#
# Note: This script is downloaded/updated by system-setup.sh but runs independently.

set -euo pipefail

# Get the directory where this script is located
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Helper Functions
# ============================================================================

# Get the release codename from /etc/os-release
# Returns: codename via stdout
get_release_codename() {
    local release=$(grep "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [[ -z "$release" ]]; then
        release=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    fi
    echo "$release"
}

# ============================================================================
# Menu Option Functions
# ============================================================================

# Option 1: List packages upgradeable from backports
list_backports_upgrades() {
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

# Option 2: List packages with residual configs and optionally purge them
list_residual_configs() {
    print_info "Listing packages with residual configuration files..."
    echo ""

    # Capture the output of apt list '~c'
    local output=$(apt list '~c' 2>/dev/null) || true

    # Check if there are any results (filter out the "Listing..." header line)
    local packages=$(echo "$output" | grep -v "^Listing" | grep -v "^$" || true)

    if [[ -z "$packages" ]]; then
        print_success "No packages with residual configuration files found."
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

# Option 3: Run apt autoremove
run_autoremove() {
    print_info "Running apt autoremove to clean up unused packages..."
    echo ""

    run_elevated apt autoremove
    echo ""

    print_success "Autoremove complete."
    echo ""
}

# ============================================================================
# Main Function
# ============================================================================

main() {
    # Detect OS
    detect_os

    # Verify we're on Linux
    if [[ "$DETECTED_OS" != "linux" ]]; then
        print_error "This script is designed for Linux systems with apt/aptitude."
        print_error "Detected OS: $DETECTED_OS"
        exit 1
    fi

    print_info "APT Package Helper"
    echo "            ===================="
    echo ""

    # Display menu
    print_info "Select an operation:"
    echo "            1) List packages upgradeable from backports"
    echo "            2) List packages with residual configs (and optionally purge)"
    echo "            3) Run apt autoremove"
    echo "            Ctrl+C to cancel and exit"
    echo ""
    read -p "            Enter choice (1-3): " -r choice

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
        *)
            print_error "Invalid choice. Aborting."
            echo ""
            exit 1
            ;;
    esac
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
