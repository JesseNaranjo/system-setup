#!/usr/bin/env bash

# system-configuration-swap.sh - Configure swap memory
# Part of the system-setup suite
#
# This script:
# - Checks if swap is enabled
# - Creates and enables swap file if needed
# - Adds swap entry to /etc/fstab for persistence

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Swap Configuration
# ============================================================================

# Configure swap memory
configure_swap() {
    # Swap configuration is only relevant for Linux systems
    if [[ "$DETECTED_OS" != "linux" ]]; then
        print_info "Swap configuration is only applicable to Linux systems"
        return 0
    fi

    # Check if running inside a container
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        print_info "Detected container environment: Swap configuration is not recommended inside containers"
        return 0
    fi

    print_info "Checking swap configuration..."

    # Check if swap is currently enabled
    local swap_status=$(swapon --show 2>/dev/null)

    if [[ -n "$swap_status" ]]; then
        print_success "- Swap is already enabled:"
        echo "- $swap_status"
        return 0
    fi

    print_info "- Swap is currently disabled"
    echo ""
    print_info "Recommended swap sizes:"
    echo "            • ≤2 GB RAM: 2x RAM"
    echo "            • >2 GB RAM: 1.5x RAM"
    echo ""

    if ! prompt_yes_no "            Would you like to set up swap?" "n"; then
        print_info "- Keeping swap disabled (no changes made)"
        return 0
    fi
    echo ""

    print_info "Configuring swap memory..."

    # Get total RAM in GB
    local ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_gb=$((ram_kb / 1024 / 1024))

    # Calculate swap size based on RAM
    local swap_gb
    if [[ $ram_gb -le 2 ]]; then
        swap_gb=$((ram_gb * 2))
    else
        # 1.5x RAM (using integer math: multiply by 3 and divide by 2)
        swap_gb=$(((ram_gb * 3) / 2))
    fi

    # Convert to MB for dd count
    local swap_mb=$((swap_gb * 1024))

    print_info "- Detected RAM: ${ram_gb} GB"
    print_info "- Calculated swap size: ${swap_gb} GB (${swap_mb} MB)"
    echo ""

    # Set swapfile location in /var
    local swapfile="/var/swapfile"

    print_info "Creating swap file at ${swapfile}..."

    # Create swap file
    if ! dd if=/dev/zero of="$swapfile" bs=1M count="$swap_mb" 2>&1 | grep -v "records in\|records out"; then
        print_error "Failed to create swap file"
        return 1
    fi
    print_success "✓ Swap file created (${swap_gb} GB)"

    # Set correct permissions
    if ! chmod 600 "$swapfile"; then
        print_error "Failed to set permissions on swap file"
        rm -f "$swapfile"
        return 1
    fi
    print_success "✓ Updated permissions on swap file (chmod)"

    # Format as swap
    if ! mkswap "$swapfile" 2>&1 | tail -n 1; then
        print_error "Failed to format swap file"
        rm -f "$swapfile"
        return 1
    fi
    print_success "✓ Formatted swap file (mkswap)"

    # Enable swap
    if ! swapon "$swapfile"; then
        print_error "Failed to enable swap"
        rm -f "$swapfile"
        return 1
    fi
    print_success "✓ Swap enabled successfully"
    echo ""

    # Show current swap status
    print_info "Current swap status:"
    swapon --show || true
    echo ""

    # Check if fstab entry exists
    local fstab_entry="${swapfile} none swap sw 0 0"
    if grep -q "^${swapfile}" /etc/fstab 2>/dev/null; then
        print_info "Swap entry already exists in /etc/fstab"
    else
        print_info "Adding swap entry to /etc/fstab for persistence across reboots..."

        # Backup fstab before modification
        backup_file /etc/fstab

        # Add entry to fstab
        echo "" >> /etc/fstab
        echo "# Swap file - managed by system-setup.sh" >> /etc/fstab
        echo "# Added: $(date)" >> /etc/fstab
        echo "$fstab_entry" >> /etc/fstab

        print_success "✓ Swap entry added to /etc/fstab"
    fi
    echo ""

    print_info "Swap configuration complete"
    print_info "- Swap is automatically activated on reboot"
    print_info "- Swap file: ${swapfile}"
    print_info "- Size: ${swap_gb} GB"
}

# ============================================================================
# Main Execution
# ============================================================================

main_configure_swap() {
    # Detect OS if not already detected
    if [[ -z "$DETECTED_OS" ]]; then
        detect_os
    fi

    # Detect container environment if not already detected
    if [[ "$RUNNING_IN_CONTAINER" == false ]] || [[ "$DETECTED_OS" == "linux" ]]; then
        detect_container
    fi

    configure_swap
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_swap "$@"
fi
