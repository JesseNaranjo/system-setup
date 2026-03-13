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

readonly SYSCTL_SETTINGS=(
    "net.ipv4.ip_forward|1|IPv4 forwarding"
    "net.bridge.bridge-nf-call-iptables|1|bridge netfilter for iptables"
    "net.bridge.bridge-nf-call-ip6tables|1|bridge netfilter for ip6tables"
)
readonly SYSCTL_CONF="/etc/sysctl.d/k8s.conf"

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
    sysctl -w "${key}=${value}" >/dev/null \
        || { print_error "Failed to set ${key}=${value}"; return 1; }
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
# Sets SYSCTL_FILE_CHANGED=true if file was created/updated
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

    echo "$expected_content" > "$SYSCTL_CONF" \
        || { print_error "Failed to write $SYSCTL_CONF"; return 1; }
    print_success "- Persistence file $SYSCTL_CONF written"
    SYSCTL_FILE_CHANGED=true
    return 0
}

# ============================================================================
# Entry Point
# ============================================================================

main_configure_networking() {
    detect_environment || { print_error "Failed to detect environment"; return 1; }

    print_info "Configuring Kubernetes networking..."

    # Check br_netfilter availability (required for bridge-nf-call settings)
    local br_netfilter_available=true
    if ! is_module_available "br_netfilter"; then
        br_netfilter_available=false
        if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
            print_warning "br_netfilter not available in container — skipping bridge netfilter settings"
        else
            print_warning "br_netfilter kernel module is not loaded; bridge-nf-call settings may fail"
        fi
    fi

    # Apply each sysctl setting
    for entry in "${SYSCTL_SETTINGS[@]}"; do
        local key="${entry%%|*}"
        local remainder="${entry#*|}"
        local value="${remainder%%|*}"
        local description="${remainder#*|}"

        # Skip bridge-nf-call settings when br_netfilter is not available
        if [[ "$br_netfilter_available" == false ]] && [[ "$key" == net.bridge.* ]]; then
            print_info "- Skipped $description (br_netfilter not available)"
            continue
        fi

        apply_sysctl_setting "$key" "$value" "$description" || return 1
    done

    # Persist settings and reload if file was created/updated
    local SYSCTL_FILE_CHANGED=false
    persist_sysctl_settings || return 1
    if [[ "$SYSCTL_FILE_CHANGED" == true ]]; then
        # Skip reload without br_netfilter — persisted settings include
        # net.bridge.* which can't be applied at runtime, and individual
        # settings were already applied above
        if [[ "$br_netfilter_available" == false ]]; then
            print_info "Skipping sysctl reload (br_netfilter unavailable — settings applied individually)"
        else
            print_info "Reloading sysctl configuration..."
            sysctl --system >/dev/null 2>&1 \
                || { print_error "Failed to reload sysctl configuration"; return 1; }
            print_success "- Sysctl configuration reloaded"
        fi
    fi

    print_success "Kubernetes networking configuration complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_networking "$@"
fi
