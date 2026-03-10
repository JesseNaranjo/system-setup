#!/usr/bin/env bash
# configure-crio.sh - Configure CRI-O container runtime for Kubernetes
# Creates drop-in configuration and ensures CRI-O service is running
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# ============================================================================
# Configuration
# ============================================================================

if [[ -z "${CRIO_CONF_DIR+x}" ]]; then
    readonly CRIO_CONF_DIR="/etc/crio/crio.conf.d"
fi
if [[ -z "${CRIO_K8S_CONF+x}" ]]; then
    readonly CRIO_K8S_CONF="${CRIO_CONF_DIR}/10-k8s.conf"
fi

# ============================================================================
# CRI-O Configuration
# ============================================================================

# Expected content for the Kubernetes drop-in config
build_crio_conf_content() {
    cat <<'EOF'
[crio.runtime]
default_runtime = "runc"

[crio.runtime.runtimes.runc]
runtime_type = "oci"
EOF
}

# Check if the drop-in config exists with correct content
# Returns: 0 if correctly configured, 1 otherwise
is_crio_configured() {
    if [[ ! -f "$CRIO_K8S_CONF" ]]; then
        return 1
    fi

    local expected_content
    expected_content="$(build_crio_conf_content)"

    local current_content
    current_content="$(cat "$CRIO_K8S_CONF")"

    [[ "$current_content" == "$expected_content" ]]
}

# Create the drop-in configuration directory and file
create_crio_dropin() {
    if is_crio_configured; then
        print_success "- CRI-O Kubernetes drop-in already configured at ${CRIO_K8S_CONF}"
        return 0
    fi

    print_info "Creating CRI-O drop-in configuration at ${CRIO_K8S_CONF}..."

    # Ensure the drop-in directory exists
    if [[ ! -d "$CRIO_CONF_DIR" ]]; then
        mkdir -p "$CRIO_CONF_DIR"
    fi

    local content
    content="$(build_crio_conf_content)"
    echo "$content" > "$CRIO_K8S_CONF"

    print_success "- CRI-O drop-in configuration created at ${CRIO_K8S_CONF}"
}

# Verify CRI-O socket path exists (informational only)
check_crio_socket() {
    if [[ ! -S /var/run/crio/crio.sock ]]; then
        print_warning "CRI-O socket not found at /var/run/crio/crio.sock (may appear after service starts)"
    fi
}

# Enable and start CRI-O service if not already running
ensure_crio_service() {
    if systemctl is-active --quiet crio; then
        print_success "- crio.service is already running"
        return 0
    fi

    print_info "Enabling and starting crio.service..."
    systemctl enable --now crio
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
        print_warning "crictl info returned an error (CRI-O may still be initializing)"
    fi
}

# ============================================================================
# Entry Point
# ============================================================================

main_configure_crio() {
    detect_environment

    print_info "Configuring CRI-O container runtime..."

    # Guard: skip if CRI-O is not installed
    if ! command -v crio &>/dev/null; then
        print_warning "CRI-O is not installed, skipping configuration"
        return 0
    fi

    create_crio_dropin
    check_crio_socket
    ensure_crio_service
    validate_crio

    print_success "CRI-O container runtime configuration complete"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main_configure_crio "$@"
