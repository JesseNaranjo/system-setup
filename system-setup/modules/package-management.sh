#!/usr/bin/env bash

# package-management.sh - Package installation and management
# Part of the system-setup suite
#
# This script:
# - Checks for required packages
# - Installs packages via apt (Linux) or Homebrew (macOS)
# - Tracks special packages for later configuration

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Package Management Functions
# ============================================================================

# Get package definitions for the given OS
get_package_list() {
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # macOS packages (brew)
        echo "7-zip:sevenzip"
        echo "ca-certificates:ca-certificates"
        echo "Git:git"
        echo "htop:htop"
        echo "Nano Editor:nano"
        echo "Ollama:ollama"
        echo "Screen (GNU):screen"
    else
        # Linux packages (apt)
        echo "7-zip:7zip"
        echo "aptitude:aptitude"
        echo "ca-certificates:ca-certificates"
        echo "cURL:curl"
        echo "Git:git"
        echo "htop:htop"
        echo "Nano Editor:nano"
        echo "OpenSSH Server:openssh-server"
        echo "Screen (GNU):screen"
    fi
}

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
        return 1
    fi

    # Check if we can install packages
    if ! check_privileges "package_install"; then
        can_install=false
        print_warning "Cannot install packages without root privileges (will only detect installed packages)"
        echo ""
    fi

    # Identify all missing packages
    while IFS=: read -r display_name package; do
        if is_package_installed "$package"; then
            print_success "$display_name is already installed"
            track_special_packages "$package"
        else
            print_warning "$display_name is not installed"
            if [[ "$can_install" == true ]]; then
                if prompt_yes_no "          - Would you like to install $display_name?" "n"; then
                    packages_to_install+=("$package")
                    track_special_packages "$package"
                fi
            fi
        fi
    done < <(get_package_list)

    # If there are packages to install and we have privileges, call the installer
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        if [[ "$can_install" == true ]] &&  ! install_packages "${packages_to_install[@]}"; then
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

# ============================================================================
# Main Execution
# ============================================================================

main() {
    # Detect OS if not already detected
    if [[ -z "$DETECTED_OS" ]]; then
        detect_os
    fi

    check_and_install_packages
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
