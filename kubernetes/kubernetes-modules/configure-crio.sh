#!/usr/bin/env bash
# configure-crio.sh - Configure CRI-O container runtime for Kubernetes
# Cleans up stale drop-in configuration and ensures CRI-O service is running
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# ============================================================================
# Configuration
# ============================================================================

readonly CRIO_CONF_DIR="/etc/crio/crio.conf.d"

# ============================================================================
# CRI-O Configuration
# ============================================================================

# Clean up stale drop-in from previous versions of this script.
# The package-provided 10-crio.conf handles runtime configuration;
# our old 10-k8s.conf overrode defaults and caused runc-not-found failures.
cleanup_stale_dropin() {
    local stale_conf="${CRIO_CONF_DIR}/10-k8s.conf"
    if [[ -f "$stale_conf" ]]; then
        print_info "Removing stale drop-in: ${stale_conf}"
        rm -f "$stale_conf" \
            || { print_warning "⚠ Failed to remove ${stale_conf}"; return 0; }
        print_success "- Removed stale ${stale_conf}"
    fi
}

# Warn if the package-provided drop-in is missing.
# CRI-O ships 10-crio.conf with runtime paths, conmon config, and signature policy.
# Without it, CRI-O may lack essential configuration.
check_package_dropin() {
    local package_conf="${CRIO_CONF_DIR}/10-crio.conf"
    if [[ ! -f "$package_conf" ]]; then
        print_warning "⚠ Package-provided ${package_conf} not found — CRI-O may lack essential runtime configuration"
    fi
}

# Verify CRI-O socket path exists (informational only)
check_crio_socket() {
    if [[ ! -S /var/run/crio/crio.sock ]]; then
        print_warning "⚠ CRI-O socket not found at /var/run/crio/crio.sock (CRI-O may still be initializing)"
    fi
}

# Enable and start CRI-O service if not already running
ensure_crio_service() {
    if systemctl is-active --quiet crio; then
        print_success "- crio.service is already running"
        return 0
    fi

    print_info "Enabling and starting crio.service..."
    systemctl enable --now crio \
        || { print_error "✖ Failed to enable/start crio.service"; return 1; }
    print_success "- crio.service enabled and started"
}

# Validate CRI-O with crictl if available (informational, not blocking)
validate_crio() {
    if ! command -v crictl &>/dev/null; then
        print_info "crictl not available, skipping CRI-O validation"
        return 0
    fi

    if crictl info &>/dev/null; then
        print_success "- CRI-O validated via crictl info"
    else
        print_warning "⚠ crictl info returned an error (CRI-O may still be initializing)"
    fi
}

# ============================================================================
# Entry Point
# ============================================================================

main_configure_crio() {
    detect_environment || { print_error "✖ Failed to detect environment"; return 1; }

    print_info "Configuring CRI-O container runtime..."

    # Guard: skip if CRI-O is not installed
    if ! command -v crio &>/dev/null; then
        print_warning "⚠ CRI-O is not installed, skipping configuration"
        return 0
    fi

    cleanup_stale_dropin
    check_package_dropin
    ensure_crio_service || return 1
    check_crio_socket
    validate_crio || print_warning "⚠ CRI-O validation failed, continuing"

    print_success "CRI-O container runtime configuration complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_for_updates "${BASH_SOURCE[0]}" "$@"
    main_configure_crio "$@"
fi
