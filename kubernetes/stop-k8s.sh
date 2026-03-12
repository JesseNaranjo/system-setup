#!/usr/bin/env bash

# stop-k8s.sh - Stop Kubernetes services
# Stops and disables crio + kubelet, re-enables swap
#
# Usage: sudo ./stop-k8s.sh

set -euo pipefail

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Source utilities
# shellcheck source=utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# ============================================================================
# Service Management
# ============================================================================

stop_services() {
    print_info "Stopping and disabling kubelet and cri-o services..."
    # || true: systemctl returns non-zero if services are already stopped or not loaded
    run_elevated systemctl disable kubelet.service crio.service --now || true
    print_success "Services stopped and disabled"
}

# ============================================================================
# Post-Stop Configuration
# ============================================================================

restore_swap() {
    print_info "Re-enabling swap..."
    if run_elevated swapon -a 2>/dev/null; then
        print_success "Swap re-enabled"
    else
        print_warning "No swap devices found to enable"
    fi
}

disable_ip_forwarding() {
    local current
    current=$(sysctl -n net.ipv4.conf.all.forwarding 2>/dev/null || echo "0")
    if [[ "$current" != "0" ]]; then
        print_info "Disabling IP forwarding..."
        run_elevated sysctl -w net.ipv4.conf.all.forwarding=0 \
            || { print_error "Failed to disable IP forwarding"; return 1; }
        print_success "IP forwarding disabled"
    else
        print_success "IP forwarding already disabled"
    fi
}

show_status() {
    echo ""
    print_info "Service status:"
    run_elevated systemctl status crio.service kubelet.service --no-pager || true
}

# ============================================================================
# Main
# ============================================================================

main() {
    detect_environment || { print_error "Failed to detect environment"; return 1; }

    if [[ "$DETECTED_OS" != "linux" ]]; then
        print_error "Kubernetes services are only available on Linux"
        exit 1
    fi

    if ! check_privileges "system_config"; then
        print_error "Stopping Kubernetes services requires root privileges"
        print_info "Please re-run with: sudo $0"
        exit 1
    fi

    print_info "Stopping Kubernetes services..."
    echo ""

    stop_services
    restore_swap
    disable_ip_forwarding || return 1
    show_status

    print_success "Kubernetes services stopped"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
