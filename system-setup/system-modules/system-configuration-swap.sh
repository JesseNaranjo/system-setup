#!/usr/bin/env bash

# system-configuration-swap.sh - Configure swap memory
# Part of the system-setup suite
#
# This script:
# - Checks if swap is enabled
# - Creates and enables swap file if needed
# - Adds swap entry to /etc/fstab for persistence

set -euo pipefail

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

# Constants
readonly LEGACY_SWAPFILE="/var/swapfile"
readonly SWAPFILE="/var/swapfile1"

# Create swap file using fallocate (fast) or dd (fallback)
# Arguments: $1=swapfile path, $2=size in GB, $3=size in MB, $4=method (optional: "dd" to force dd)
# Returns: 0 on success, 1 on failure
create_swap_file() {
    local swapfile="$1"
    local swap_gb="$2"
    local swap_mb="$3"
    local method="${4:-}"

    if [[ "$method" != "dd" ]]; then
        # Try fallocate first (much faster)
        if run_elevated fallocate -l "${swap_gb}G" "$swapfile" 2>/dev/null; then
            print_success "✓ Swap file created with fallocate (${swap_gb} GB)"
        else
            print_info "fallocate not supported on this filesystem, falling back to dd..."
            method="dd"
        fi
    fi

    if [[ "$method" == "dd" ]]; then
        if ! run_elevated dd if=/dev/zero of="$swapfile" bs=1M count="$swap_mb" status=progress 2>&1; then
            print_error "Failed to create swap file"
            return 1
        fi
        print_success "✓ Swap file created with dd (${swap_gb} GB)"
    fi

    # Set correct permissions
    if ! run_elevated chmod 600 "$swapfile"; then
        print_error "Failed to set permissions on swap file"
        run_elevated rm -f "$swapfile"
        return 1
    fi
    print_success "✓ Updated permissions on swap file (chmod 600)"

    # Set correct ownership
    if ! run_elevated chown root:root "$swapfile"; then
        print_error "Failed to set ownership on swap file"
        run_elevated rm -f "$swapfile"
        return 1
    fi
    print_success "✓ Updated ownership on swap file (chown root:root)"

    return 0
}

# Format and enable swap file
# Arguments: $1=swapfile path, $2=size in GB, $3=size in MB
# Returns: 0 on success, 1 on failure
format_and_enable_swap() {
    local swapfile="$1"
    local swap_gb="$2"
    local swap_mb="$3"
    local retrying="${4:-}"

    # Format as swap
    if ! run_elevated mkswap "$swapfile" 2>&1 | tail -n 1; then
        if [[ "$retrying" == "true" ]]; then
            print_error "Failed to format swap file on retry"
            run_elevated rm -f "$swapfile"
            return 1
        fi

        print_warning "mkswap failed, possibly due to file holes from fallocate"
        print_info "Recreating swap file with dd..."

        # Remove the problematic file and recreate with dd
        run_elevated rm -f "$swapfile"
        if ! create_swap_file "$swapfile" "$swap_gb" "$swap_mb" "dd"; then
            return 1
        fi

        # Retry mkswap
        format_and_enable_swap "$swapfile" "$swap_gb" "$swap_mb" "true"
        return $?
    fi
    print_success "✓ Formatted swap file (mkswap)"

    # Enable swap
    if ! run_elevated swapon "$swapfile"; then
        print_error "Failed to enable swap"
        run_elevated rm -f "$swapfile"
        return 1
    fi
    print_success "✓ Swap enabled successfully"

    return 0
}

# Update fstab swap entry from old path to new path
# Arguments: $1=old path, $2=new path
# Returns: 0 on success, 1 on failure
update_fstab_swap_entry() {
    local old_path="$1"
    local new_path="$2"
    local temp_file

    # Check if old entry exists in fstab
    if ! grep -E "^\s*${old_path}\s+" /etc/fstab &>/dev/null; then
        # No need to output a message if no entry found
        return 0
    fi

    print_info "Updating fstab entry from ${old_path} to ${new_path}..."

    # Backup fstab before modification
    backup_file /etc/fstab

    # Create temp file and update entry
    temp_file=$(mktemp)
    if ! awk -v old="$old_path" -v new="$new_path" '
        $1 ~ "^" old "$" { gsub(old, new, $1) }
        { print }
    ' /etc/fstab > "$temp_file"; then
        print_error "Failed to update fstab entry"
        print_error "Backup saved at: /etc/fstab.backup.*"
        rm -f "$temp_file"
        return 1
    fi

    # Move temp file to fstab
    if ! run_elevated mv "$temp_file" /etc/fstab; then
        print_error "Failed to write updated fstab"
        print_error "Backup saved at: /etc/fstab.backup.*"
        rm -f "$temp_file"
        return 1
    fi

    # Restore permissions on fstab
    run_elevated chmod 644 /etc/fstab
    run_elevated chown root:root /etc/fstab

    print_success "✓ Updated fstab entry"
    return 0
}

# Migrate legacy /var/swapfile to /var/swapfile1
# Returns: 0 on success or no migration needed, 1 on failure
migrate_legacy_swapfile() {
    # Check if legacy swapfile exists
    if [[ ! -f "$LEGACY_SWAPFILE" ]]; then
        return 0
    fi

    print_info "Found legacy swap file at ${LEGACY_SWAPFILE}"

    # Check if legacy swap is currently active
    local was_active=false
    if swapon --show 2>/dev/null | grep -q "$LEGACY_SWAPFILE"; then
        was_active=true
        print_info "- Legacy swap file is currently active"
    else
        print_info "- Legacy swap file is not currently active"
    fi
    echo ""

    if ! prompt_yes_no "            Would you like to rename ${LEGACY_SWAPFILE} to ${SWAPFILE}?" "y"; then
        print_warning "Declining migration will result in two swap files if you proceed with setup"
        return 0
    fi
    echo ""

    print_info "Migrating legacy swap file..."

    # Disable swap if active
    if [[ "$was_active" == true ]]; then
        print_info "Disabling legacy swap file..."
        if ! run_elevated swapoff "$LEGACY_SWAPFILE"; then
            print_error "Failed to disable legacy swap file"
            print_error "Swap may be in use by processes. Please free up swap and try again."
            return 1
        fi
        print_success "✓ Disabled legacy swap file"
    fi

    # Rename the file
    if ! run_elevated mv "$LEGACY_SWAPFILE" "$SWAPFILE"; then
        print_error "Failed to rename swap file"
        # Try to re-enable swap if it was active
        if [[ "$was_active" == true ]]; then
            run_elevated swapon "$LEGACY_SWAPFILE" 2>/dev/null || true
        fi
        return 1
    fi
    print_success "✓ Renamed ${LEGACY_SWAPFILE} to ${SWAPFILE}"

    # Verify and set permissions
    if ! run_elevated chmod 600 "$SWAPFILE"; then
        print_error "Failed to verify permissions on swap file"
        return 1
    fi
    print_success "✓ Verified permissions (chmod 600)"

    # Verify and set ownership
    if ! run_elevated chown root:root "$SWAPFILE"; then
        print_error "Failed to verify ownership on swap file"
        return 1
    fi
    print_success "✓ Verified ownership (chown root:root)"

    # Update fstab entry
    if ! update_fstab_swap_entry "$LEGACY_SWAPFILE" "$SWAPFILE"; then
        print_warning "Failed to update fstab, swap file was renamed but fstab needs manual update"
    fi

    # Re-enable swap if it was previously active
    if [[ "$was_active" == true ]]; then
        print_info "Re-enabling swap..."
        if ! run_elevated swapon "$SWAPFILE"; then
            print_error "Failed to re-enable swap at ${SWAPFILE}"
            return 1
        fi
        print_success "✓ Swap re-enabled at ${SWAPFILE}"
    fi
    echo ""

    print_success "Migration complete"
    return 0
}

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

    # Check for conflict: both legacy and new swapfile exist
    if [[ -f "$LEGACY_SWAPFILE" ]] && [[ -f "$SWAPFILE" ]]; then
        print_warning "Both ${LEGACY_SWAPFILE} and ${SWAPFILE} exist"
        print_warning "Please manually resolve this conflict before running swap configuration"
        print_info "You may want to:"
        echo "            • Remove one of the swap files"
        echo "            • Or disable and delete the legacy swap file"
        return 1
    fi

    # Offer to migrate legacy swapfile if it exists
    if ! migrate_legacy_swapfile; then
        return 1
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

    # Use the constant for swapfile location
    local swapfile="$SWAPFILE"

    print_info "Creating swap file at ${swapfile}..."

    # Create swap file using helper function
    if ! create_swap_file "$swapfile" "$swap_gb" "$swap_mb"; then
        return 1
    fi

    # Format and enable swap using helper function
    if ! format_and_enable_swap "$swapfile" "$swap_gb" "$swap_mb"; then
        return 1
    fi
    echo ""

    # Show current swap status
    print_info "Current swap status:"
    swapon --show || true
    echo ""

    # Check if fstab entry exists
    local fstab_entry="${swapfile} none swap sw 0 0"
    if grep -E "^\s*${swapfile}\s+" /etc/fstab &>/dev/null; then
        print_info "Swap entry already exists in /etc/fstab"
    else
        print_info "Adding swap entry to /etc/fstab for persistence across reboots..."

        # Backup fstab before modification
        backup_file /etc/fstab

        # Add entry to fstab
        {
            echo ""
            echo "# Swap file - managed by system-setup.sh"
            echo "# Added: $(date)"
            echo "$fstab_entry"
        } | run_elevated tee -a /etc/fstab > /dev/null

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
    detect_environment

    configure_swap
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_swap "$@"
fi
