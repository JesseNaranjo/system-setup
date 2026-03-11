#!/usr/bin/env bash

# install-k8s-packages.sh - Kubernetes package installation and management
# Part of the kubernetes-setup suite
#
# This script:
# - Checks for required Kubernetes packages
# - Installs packages via apt
# - Tracks special packages for later configuration

set -euo pipefail

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source utilities
# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# ============================================================================
# Package Installation Functions
# ============================================================================

# Install packages via apt
install_packages() {
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    if apt install -y "${packages[@]}"; then
        print_success "All packages installed successfully"
        return 0
    fi

    print_error "Failed to install some packages"
    return 1
}

# Check and optionally install packages
check_and_install_packages() {
    local packages_to_install=()
    local can_install=true

    print_info "Checking for required Kubernetes packages..."
    echo ""

    # Verify package manager availability
    if ! verify_package_manager; then
        print_warning "No supported package manager found on this system."
        return 1
    fi

    # Check if we can install packages
    if ! check_privileges "package_install"; then
        can_install=false
        print_warning "Cannot install packages without root privileges (will only detect installed packages)"
        echo ""
    fi

    # Identify all missing packages
    while IFS=':' read -r display_name package_name; do
        if is_package_installed "$package_name"; then
            print_success "$display_name is already installed"
            track_special_packages "$package_name"
        else
            print_warning "$display_name is not installed"
            if [[ "$can_install" == true ]]; then
                if prompt_yes_no "            - Would you like to install $display_name?" "n"; then
                    packages_to_install+=("$package_name")
                fi
            fi
        fi
    done < <(get_package_list)

    # If there are packages to install and we have privileges, call the installer
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        if [[ "$can_install" == true ]]; then
            if install_packages "${packages_to_install[@]}"; then
                # Track newly installed packages after confirmed successful installation
                invalidate_package_cache
                for package_name in "${packages_to_install[@]}"; do
                    if is_package_installed "$package_name"; then
                        track_special_packages "$package_name"
                    fi
                done
            else
                # Even if installation fails, we return 0 to allow configuration of already-installed packages
                print_error "Package installation failed or was cancelled. Continuing with configuration for any packages that are already present."
            fi
        fi
    else
        if [[ "$can_install" == true ]]; then
            print_info "No new packages to install."
        fi
    fi

    echo ""
    return 0
}

# ============================================================================
# Main Execution
# ============================================================================

main_install_k8s_packages() {
    detect_environment

    check_and_install_packages
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_install_k8s_packages "$@"
fi
