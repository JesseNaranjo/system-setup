#!/usr/bin/env bash
# configure-networking.sh - Configure sysctl settings for Kubernetes networking
# Sets kernel parameters required by Kubernetes (IP forwarding, bridge netfilter)
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# ============================================================================
# Sysctl Settings
# ============================================================================

if [[ -z "${SYSCTL_SETTINGS+x}" ]]; then
    readonly SYSCTL_SETTINGS=(
        "net.ipv4.ip_forward|1|IPv4 forwarding"
        "net.bridge.bridge-nf-call-iptables|1|bridge netfilter for iptables"
        "net.bridge.bridge-nf-call-ip6tables|1|bridge netfilter for ip6tables"
    )
fi
if [[ -z "${SYSCTL_CONF+x}" ]]; then
    readonly SYSCTL_CONF="/etc/sysctl.d/k8s.conf"
fi

# ============================================================================
# Sysctl Management
# ============================================================================

# Apply a single sysctl setting if not already correct
# Args: key, value, description
apply_sysctl_setting() {
    local key="$1"
    local value="$2"
    local description="$3"

    local current_value
    current_value="$(sysctl -n "$key" 2>/dev/null || echo "")"

    if [[ "$current_value" == "$value" ]]; then
        print_success "- $description already set ($key = $value)"
        return 0
    fi

    print_info "Setting $description ($key = $value)..."
    sysctl -w "${key}=${value}" >/dev/null
    print_success "- $description applied ($key = $value)"
}

# Build the expected content for the persistence file
build_sysctl_conf_content() {
    local content=""
    for entry in "${SYSCTL_SETTINGS[@]}"; do
        local key="${entry%%|*}"
        local remainder="${entry#*|}"
        local value="${remainder%%|*}"
        if [[ -n "$content" ]]; then
            content+=$'\n'
        fi
        content+="${key} = ${value}"
    done
    echo "$content"
}

# Ensure sysctl settings are persisted to disk
# Returns: 0 if file already correct, 1 if file was created/updated
persist_sysctl_settings() {
    local expected_content
    expected_content="$(build_sysctl_conf_content)"

    if [[ -f "$SYSCTL_CONF" ]]; then
        local current_content
        current_content="$(cat "$SYSCTL_CONF")"
        if [[ "$current_content" == "$expected_content" ]]; then
            print_success "- Persistence file $SYSCTL_CONF already correct"
            return 0
        fi
        print_info "Updating persistence file $SYSCTL_CONF..."
        backup_file "$SYSCTL_CONF"
    else
        print_info "Creating persistence file $SYSCTL_CONF..."
    fi

    echo "$expected_content" > "$SYSCTL_CONF"
    print_success "- Persistence file $SYSCTL_CONF written"
    return 1
}

# ============================================================================
# Entry Point
# ============================================================================

main_configure_networking() {
    detect_environment

    print_info "Configuring Kubernetes networking..."

    # Warn if br_netfilter module is not loaded (required for bridge-nf-call settings)
    local lsmod_output
    lsmod_output="$(lsmod 2>/dev/null || cat /proc/modules 2>/dev/null || true)"
    if [[ -n "$lsmod_output" ]] && ! echo "$lsmod_output" | grep -q br_netfilter; then
        print_warning "br_netfilter kernel module is not loaded; bridge-nf-call settings may fail"
    fi

    # Apply each sysctl setting
    for entry in "${SYSCTL_SETTINGS[@]}"; do
        local key="${entry%%|*}"
        local remainder="${entry#*|}"
        local value="${remainder%%|*}"
        local description="${remainder#*|}"
        apply_sysctl_setting "$key" "$value" "$description"
    done

    # Persist settings and reload if file was created/updated
    if ! persist_sysctl_settings; then
        print_info "Reloading sysctl configuration..."
        sysctl --system >/dev/null 2>&1
        print_success "- Sysctl configuration reloaded"
    fi

    print_success "Kubernetes networking configuration complete"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main_configure_networking "$@"
