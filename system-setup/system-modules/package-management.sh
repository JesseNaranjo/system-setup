#!/usr/bin/env bash

# package-management.sh - Package installation and management
# Part of the system-setup suite
#
# This script:
# - Checks for required packages
# - Installs packages via apt (Linux) or Homebrew (macOS)
# - Tracks special packages for later configuration

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Package Management Functions
# ============================================================================

# Install packages based on OS
install_packages() {
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ "$DETECTED_OS" == "macos" ]]; then
        # Get dependencies, excluding the requested packages themselves
        local dependencies=$(brew deps "${packages[@]}" 2>/dev/null || true)

        # Get a sorted, unique list of the packages the user actually requested
        local sorted_packages=$(printf "%s\n" "${packages[@]}" | sort -u | tr '\n' ' ')

        echo "Installing:"
        echo "  $sorted_packages"

        if [[ -n "$dependencies" ]]; then
            # Get a sorted, unique list of dependencies
            local sorted_deps=$(printf "%s\n" $dependencies | sort -u)
            echo ""
            echo "Installing dependencies:"
            # Attempt to format into columns if 'column' command is available
            if command -v column &>/dev/null; then
                echo "$sorted_deps" | column | sed 's/^/  /'
            else
                echo "  $(echo "$sorted_deps" | tr '\n' ' ')"
            fi
        fi

        echo ""
        if prompt_yes_no "Continue?" "y"; then
            echo "Installing packages with brew..."
            if brew install "${packages[@]}"; then
                print_success "✓ All packages installed successfully"
                return 0
            fi
        fi
    else
        # apt install will show packages and dependencies to install automatically
        if apt update && apt install "${packages[@]}"; then
            print_success "✓ All packages installed successfully"
            return 0
        fi
    fi

    print_error "Failed to install some packages"
    return 1
}

# Check and optionally install packages
check_and_install_packages() {
    local packages_to_install=()
    local can_install=true

    print_info "Checking for required packages..."
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
                    track_special_packages "$package_name"
                fi
            fi
        fi
    done < <(get_package_list)

    # If there are packages to install and we have privileges, call the installer
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        if [[ "$can_install" == true ]] && ! install_packages "${packages_to_install[@]}"; then
            # Even if installation fails, we return 0 to allow configuration of already-installed packages
            print_error "Package installation failed or was cancelled. Continuing with configuration for any packages that are already present."
        fi
    else
        if [[ "$can_install" == true ]]; then
            print_info "No new packages to install."
        fi
    fi

    echo ""
    return 0
}

# Uninstall packages based on OS
# Uses purge on apt to remove config files, then runs autoremove
uninstall_packages() {
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ "$DETECTED_OS" == "macos" ]]; then
        # Get a sorted, unique list of the packages to remove
        local sorted_packages=$(printf "%s\n" "${packages[@]}" | sort -u | tr '\n' ' ')

        echo "Removing:"
        echo "  $sorted_packages"
        echo ""

        if prompt_yes_no "Continue with removal?" "n"; then
            echo "Removing packages with brew..."
            if brew uninstall "${packages[@]}"; then
                print_success "✓ Packages removed successfully"
                # Clean up orphaned dependencies
                print_info "Running brew autoremove to clean up orphaned dependencies..."
                brew autoremove
                return 0
            fi
        else
            print_info "Package removal cancelled."
            return 0
        fi
    else
        # apt purge will show packages to remove
        echo "Purging (removing with config files):"
        printf "  %s\n" "${packages[@]}"
        echo ""

        if prompt_yes_no "Continue with removal?" "n"; then
            if apt purge -y "${packages[@]}"; then
                print_success "✓ Packages purged successfully"
                # Clean up orphaned dependencies
                print_info "Running apt autoremove to clean up orphaned dependencies..."
                apt autoremove -y
                return 0
            fi
        else
            print_info "Package removal cancelled."
            return 0
        fi
    fi

    print_error "Failed to remove some packages"
    return 1
}

# Check and optionally remove unwanted packages
check_and_remove_packages() {
    local packages_to_remove=()
    local can_remove=true
    local has_removable_packages=false

    # Check if there are any packages in the removal list for this OS
    if [[ -z "$(get_removable_package_list)" ]]; then
        return 0
    fi

    print_info "Checking for packages that can be removed..."
    echo ""

    # Verify package manager availability
    if ! verify_package_manager; then
        print_warning "No supported package manager found on this system."
        return 1
    fi

    # Check if we can remove packages
    if ! check_privileges "package_install"; then
        can_remove=false
        print_warning "Cannot remove packages without root privileges (will only detect installed packages)"
        echo ""
    fi

    # Identify installed packages from the removal list
    while IFS=':' read -r display_name package_name; do
        if is_package_installed "$package_name"; then
            has_removable_packages=true
            print_warning "$display_name is installed (candidate for removal)"
            if [[ "$can_remove" == true ]]; then
                if prompt_yes_no "            - Would you like to remove $display_name?" "n"; then
                    packages_to_remove+=("$package_name")
                fi
            fi
        else
            print_success "$display_name is not installed"
        fi
    done < <(get_removable_package_list)

    # If there are packages to remove and we have privileges, call the uninstaller
    if [[ ${#packages_to_remove[@]} -gt 0 ]]; then
        if [[ "$can_remove" == true ]] && ! uninstall_packages "${packages_to_remove[@]}"; then
            print_error "Package removal failed or was cancelled."
        fi
    else
        if [[ "$can_remove" == true ]] && [[ "$has_removable_packages" == false ]]; then
            print_info "No packages to remove."
        elif [[ "$can_remove" == true ]]; then
            print_info "No packages selected for removal."
        fi
    fi

    echo ""
    return 0
}

# ============================================================================
# Main Execution
# ============================================================================

main_manage_packages() {
    detect_environment

    check_and_install_packages
    check_and_remove_packages
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_manage_packages "$@"
fi
