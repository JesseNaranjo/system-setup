#!/usr/bin/env bash

# start-k8s.sh - Start Kubernetes services
# Ensures pre-start configuration and starts crio + kubelet
#
# Usage: sudo ./start-k8s.sh

set -euo pipefail

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Source utilities
# shellcheck source=utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# ============================================================================
# Pre-Start Configuration
# ============================================================================

ensure_swap_off() {
    if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
        print_info "Disabling swap..."
        run_elevated swapoff -a \
            || { print_error "✖ Failed to disable swap"; return 1; }
        print_success "✓ Swap disabled"
    else
        print_success "- Swap already disabled"
    fi
}

ensure_ip_forwarding() {
    local current
    current=$(sysctl -n net.ipv4.conf.all.forwarding 2>/dev/null || echo "0")
    if [[ "$current" != "1" ]]; then
        print_info "Enabling IP forwarding..."
        run_elevated sysctl -w net.ipv4.conf.all.forwarding=1 \
            || { print_error "✖ Failed to enable IP forwarding"; return 1; }
        print_success "✓ IP forwarding enabled"
    else
        print_success "- IP forwarding already enabled"
    fi
}

# ============================================================================
# Service Management
# ============================================================================

start_services() {
    print_info "Enabling and starting cri-o and kubelet services..."
    run_elevated systemctl enable crio.service kubelet.service \
        || { print_error "✖ Failed to enable services"; return 1; }
    run_elevated systemctl start crio.service kubelet.service \
        || { print_error "✖ Failed to start services"; return 1; }
    print_success "✓ Services started"
}

show_status() {
    echo ""
    print_info "Service status:"
    run_elevated systemctl status crio.service kubelet.service --no-pager || true
    echo ""

    print_info "Waiting for cluster to be ready..."
    sleep 5

    print_info "Cluster status:"
    kubectl get all --all-namespaces 2>/dev/null || print_warning "⚠ kubectl not available or cluster not ready"
}

# ============================================================================
# Main
# ============================================================================

main() {
    detect_environment || { print_error "✖ Failed to detect environment"; return 1; }

    if [[ "$DETECTED_OS" != "linux" ]]; then
        print_error "✖ Kubernetes services are only available on Linux"
        exit 1
    fi

    if ! check_privileges "system_config"; then
        print_error "✖ Starting Kubernetes services requires root privileges"
        print_info "Please re-run with: sudo $0"
        exit 1
    fi

    print_info "Starting Kubernetes services..."
    echo ""

    ensure_swap_off || return 1
    ensure_ip_forwarding || return 1
    start_services || return 1
    show_status

    print_success "Kubernetes services started"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
