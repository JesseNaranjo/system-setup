#!/usr/bin/env bash
# configure-swap.sh - Disable swap for Kubernetes
# Kubernetes requires swap to be disabled. This module turns off active swap,
# comments out swap entries in /etc/fstab, and masks swap.target via systemd.
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# ============================================================================
# Swap Disable
# ============================================================================

# Turn off any active swap partitions/files
disable_active_swap() {
    if [[ -n "$(swapon --show --noheadings)" ]]; then
        print_info "Active swap detected, disabling..."
        swapoff -a || { print_error "✖ Failed to disable swap"; return 1; }
        print_success "✓ Active swap disabled"
    else
        print_success "- Swap is already off"
    fi
}

# ============================================================================
# /etc/fstab Cleanup
# ============================================================================

# Comment out swap entries in /etc/fstab so swap does not re-enable on reboot
clean_fstab_swap() {
    local fstab="/etc/fstab"

    if [[ ! -f "$fstab" ]]; then
        print_warning "⚠ /etc/fstab not found, skipping fstab cleanup"
        return 0
    fi

    # Look for uncommented lines containing "swap"
    if grep -v '^\s*#' "$fstab" | grep -q 'swap'; then
        print_warning "⚠ Found active swap entries in $fstab"
        if prompt_yes_no "Comment out swap entries in $fstab?" "n"; then
            backup_file "$fstab"
            sed -i '/swap/ s/^/#/' "$fstab" \
                || { print_error "✖ Failed to comment out swap in $fstab"; return 1; }
            print_success "✓ Swap entries in $fstab commented out"
        else
            print_info "Skipped commenting out swap entries in $fstab"
        fi
    else
        print_success "- No active swap entries in $fstab"
    fi
}

# ============================================================================
# swap.target Masking
# ============================================================================

# Mask swap.target so systemd does not re-enable swap
mask_swap_target() {
    local swap_state
    swap_state="$(systemctl is-enabled swap.target 2>/dev/null || true)"

    if [[ "$swap_state" == "masked" ]]; then
        print_success "- swap.target is already masked"
        return 0
    fi

    print_warning "⚠ swap.target is not masked (current state: ${swap_state:-unknown})"
    if prompt_yes_no "Mask swap.target via systemctl?" "n"; then
        systemctl mask swap.target \
            || { print_error "✖ Failed to mask swap.target"; return 1; }
        print_success "✓ swap.target masked"
    else
        print_info "Skipped masking swap.target"
    fi
}

# ============================================================================
# Entry Point
# ============================================================================

main_configure_swap() {
    detect_environment || { print_error "✖ Failed to detect environment"; return 1; }

    # Check if running inside a container
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        print_info "Container environment detected — swap cannot be managed from inside a container"
        print_container_swap_info
        print_success "Swap configuration complete (container mode)"
        return 0
    fi

    print_info "Configuring swap..."

    disable_active_swap || return 1
    clean_fstab_swap || return 1
    mask_swap_target || return 1

    print_success "Swap configuration complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_swap "$@"
fi
