#!/usr/bin/env bash

# pkgs-helper.sh - Package management helper utilities
# Provides interactive menu for common package manager operations
# Supports: apt (Debian/Ubuntu), brew (macOS), dnf (Fedora/RHEL 8+), zypper (openSUSE)
#
# Usage: ./pkgs-helper.sh
#
# This script provides the following operations:
# - List packages upgradeable from backports repository (apt only)
# - List and optionally purge packages with residual configs (apt only)
# - Run autoremove to clean up unused packages (apt, brew, dnf, zypper)
# - Clean package cache (apt, brew, dnf, zypper)
# - Refresh package index and list outdated packages (all)
# - Upgrade all packages (all)
# - Run system diagnostics (all)
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
    [[ "$DETECTED_PKG_MANAGER" == "apt" ]] || [[ "$DETECTED_PKG_MANAGER" == "brew" ]] || [[ "$DETECTED_PKG_MANAGER" == "dnf" ]] || [[ "$DETECTED_PKG_MANAGER" == "zypper" ]]
}

# Check if the current package manager supports cache cleaning
# Returns: 0 if supported, 1 if not
supports_clean_cache() {
    [[ "$DETECTED_PKG_MANAGER" == "apt" ]] || [[ "$DETECTED_PKG_MANAGER" == "brew" ]] || [[ "$DETECTED_PKG_MANAGER" == "dnf" ]] || [[ "$DETECTED_PKG_MANAGER" == "zypper" ]]
}

# Check if the current package manager supports refresh/outdated listing
# Returns: 0 if supported, 1 if not
supports_refresh_outdated() {
    [[ "$DETECTED_PKG_MANAGER" == "apt" ]] || [[ "$DETECTED_PKG_MANAGER" == "brew" ]] || [[ "$DETECTED_PKG_MANAGER" == "dnf" ]] || [[ "$DETECTED_PKG_MANAGER" == "zypper" ]]
}

# Check if the current package manager supports upgrading all packages
# Returns: 0 if supported, 1 if not
supports_upgrade_all() {
    [[ "$DETECTED_PKG_MANAGER" == "apt" ]] || [[ "$DETECTED_PKG_MANAGER" == "brew" ]] || [[ "$DETECTED_PKG_MANAGER" == "dnf" ]] || [[ "$DETECTED_PKG_MANAGER" == "zypper" ]]
}

# Check if the current package manager supports diagnostics
# Returns: 0 if supported, 1 if not
supports_diagnostics() {
    [[ "$DETECTED_PKG_MANAGER" == "apt" ]] || [[ "$DETECTED_PKG_MANAGER" == "brew" ]] || [[ "$DETECTED_PKG_MANAGER" == "dnf" ]] || [[ "$DETECTED_PKG_MANAGER" == "zypper" ]]
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

# Option 1: Refresh package index and list outdated packages (all)
refresh_and_list_outdated() {
    if ! check_feature_available "Refresh and list outdated" supports_refresh_outdated; then
        return 0
    fi

    print_info "Refreshing package index and listing outdated packages..."
    echo ""

    case "$DETECTED_PKG_MANAGER" in
        apt)
            run_elevated apt update
            echo ""
            apt list --upgradable 2>/dev/null || true
            ;;
        dnf)
            # dnf check-update refreshes and lists in one command
            # Returns exit code 100 if updates available, 0 if none, 1 on error
            run_elevated dnf check-update || [[ $? -eq 100 ]]
            ;;
        zypper)
            run_elevated zypper refresh
            echo ""
            zypper list-updates
            ;;
        brew)
            brew update
            echo ""
            brew outdated
            ;;
    esac
    echo ""

    print_success "Package index refreshed and outdated packages listed."
    echo ""
}

# Option 2: List packages upgradeable from backports (apt only)
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

# Option 3: Upgrade all packages (all)
upgrade_all_packages() {
    if ! check_feature_available "Upgrade all" supports_upgrade_all; then
        return 0
    fi

    print_info "Upgrading all packages..."
    echo ""

    case "$DETECTED_PKG_MANAGER" in
        apt)
            # apt upgrade prompts by default
            run_elevated apt upgrade
            ;;
        dnf)
            # dnf upgrade prompts by default
            run_elevated dnf upgrade
            ;;
        zypper)
            # zypper update prompts by default
            run_elevated zypper update
            ;;
        brew)
            # brew upgrade is non-interactive, so show outdated first and confirm
            print_info "The following packages will be upgraded:"
            echo ""
            brew outdated
            echo ""
            if prompt_yes_no "→ Proceed with upgrade?" "n"; then
                echo ""
                brew upgrade
            else
                print_info "Skipped upgrade."
                return 0
            fi
            ;;
    esac
    echo ""

    print_success "Package upgrade complete."
    echo ""
}

# Option 4: List packages with residual configs and optionally purge them (apt only)
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

# Option 5: Run autoremove (apt, dnf)
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
        brew)
            brew autoremove
            ;;
    esac
    echo ""

    print_success "Autoremove complete."
    echo ""
}

# Option 6: Clean package cache (apt, dnf)
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
        brew)
            print_info "Preview of files to be cleaned:"
            echo ""
            brew cleanup -n
            echo ""
            if prompt_yes_no "→ Proceed with cleanup?" "n"; then
                echo ""
                brew cleanup --prune=all
            else
                print_info "Skipped cleanup."
                return 0
            fi
            ;;
    esac
    echo ""

    print_success "Package cache cleaned."
    echo ""
}

# Option 7: Run system diagnostics (all)
run_diagnostics() {
    if ! check_feature_available "System diagnostics" supports_diagnostics; then
        return 0
    fi

    print_info "Running system diagnostics..."
    echo ""

    case "$DETECTED_PKG_MANAGER" in
        apt)
            print_info "Checking for broken dependencies..."
            run_elevated apt-get check
            echo ""
            print_info "Checking for unconfigured packages..."
            run_elevated dpkg --audit
            echo ""
            print_info "If issues were found, run: sudo apt --fix-broken install"
            ;;
        dnf)
            # dnf check reports dependency issues, duplicates, and obsoletes
            run_elevated dnf check
            ;;
        zypper)
            # zypper verify checks dependencies without making changes
            run_elevated zypper verify --dry-run
            ;;
        brew)
            brew doctor
            ;;
    esac
    echo ""

    print_success "Diagnostics complete."
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
        print_error "This script supports: apt (Debian/Ubuntu), brew (macOS), dnf (Fedora/RHEL 8+), zypper (openSUSE)"
        exit 1
    fi

    print_info "Package Helper (using ${DETECTED_PKG_MANAGER})"
    echo "            ===================="
    echo ""

    # Main menu loop
    while true; do
        # Display menu with availability indicators
        print_info "Select an operation:"
        print_menu_option "1" "Refresh package index and list outdated" supports_refresh_outdated
        print_menu_option "2" "List packages upgradeable from backports" supports_backports
        print_menu_option "3" "Upgrade all packages" supports_upgrade_all
        print_menu_option "4" "List packages with residual configs (and optionally purge)" supports_residual_configs
        print_menu_option "5" "Run autoremove" supports_autoremove
        print_menu_option "6" "Clean package cache" supports_clean_cache
        print_menu_option "7" "Run system diagnostics" supports_diagnostics
        echo "            8) Exit (or Ctrl+C)"
        echo ""
        read -p "            Enter choice (1-8): " -r choice

        echo ""

        case "$choice" in
            1)
                refresh_and_list_outdated
                ;;
            2)
                list_backports_upgrades
                ;;
            3)
                upgrade_all_packages
                ;;
            4)
                list_residual_configs
                ;;
            5)
                run_autoremove
                ;;
            6)
                clean_cache
                ;;
            7)
                run_diagnostics
                ;;
            8)
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
