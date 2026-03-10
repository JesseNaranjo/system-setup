#!/usr/bin/env bash
# manage-certificates.sh - TLS certificate lifecycle management for Kubernetes
# Checks certificate expiry via kubeadm, offers renewal, and manages kubeconfig.
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# PKI Guard
# ============================================================================

# Check whether the PKI directory exists; skip the module if it does not
check_pki_directory() {
    if [[ ! -d /etc/kubernetes/pki/ ]]; then
        print_info "No PKI directory found - skipping certificate management"
        return 1
    fi
    return 0
}

# ============================================================================
# Certificate Expiry Check and Renewal
# ============================================================================

# Display certificate expiry information and optionally renew
check_and_renew_certificates() {
    print_info "Checking certificate expiration..."
    kubeadm certs check-expiration

    if prompt_yes_no "Would you like to renew all certificates?" "n"; then
        print_info "Renewing all certificates..."
        kubeadm certs renew all
        print_success "All certificates renewed"

        print_warning "You must restart the control plane for renewed certificates to take effect."
        print_info "Restart control plane pods by moving and restoring their manifests:"
        print_info "  1. mv /etc/kubernetes/manifests/*.yaml /tmp/"
        print_info "  2. Wait for pods to terminate"
        print_info "  3. mv /tmp/kube-*.yaml /tmp/etcd.yaml /etc/kubernetes/manifests/"
        print_info "  4. Wait for pods to restart"
    else
        print_info "Skipped certificate renewal"
    fi
}

# ============================================================================
# Kubeconfig Management
# ============================================================================

# Ensure $HOME/.kube/config is present and up to date
manage_kubeconfig() {
    local admin_conf="/etc/kubernetes/admin.conf"

    if [[ ! -f "$admin_conf" ]]; then
        print_warning "${admin_conf} not found - skipping kubeconfig management"
        return 0
    fi

    # When running under sudo, manage kubeconfig for the invoking user, not root
    local user_home="$HOME"
    local user_id
    user_id="$(id -u):$(id -g)"
    if [[ -n "${SUDO_USER:-}" ]]; then
        user_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
        user_id="$(id -u "${SUDO_USER}"):$(id -g "${SUDO_USER}")"
    fi

    local kube_dir="${user_home}/.kube"
    local kube_config="${kube_dir}/config"

    if [[ ! -f "$kube_config" ]]; then
        # Kubeconfig does not exist yet
        if prompt_yes_no "No kubeconfig found at ${kube_config}. Copy from ${admin_conf}?" "y"; then
            mkdir -p "$kube_dir"
            cp "$admin_conf" "$kube_config"
            chown "${user_id}" "$kube_config"
            print_success "Kubeconfig copied to ${kube_config}"
        else
            print_info "Skipped kubeconfig copy"
        fi
    else
        # Kubeconfig already exists - offer to refresh it
        if prompt_yes_no "Kubeconfig already exists at ${kube_config}. Re-copy from ${admin_conf}?" "n"; then
            backup_file "$kube_config"
            cp "$admin_conf" "$kube_config"
            chown "${user_id}" "$kube_config"
            print_success "Kubeconfig re-copied to ${kube_config}"
        else
            print_info "Skipped kubeconfig re-copy"
        fi
    fi
}

# ============================================================================
# Entry Point
# ============================================================================

main_manage_certificates() {
    detect_environment

    print_info "Managing Kubernetes certificates..."

    check_pki_directory || return 0

    check_and_renew_certificates
    manage_kubeconfig

    print_success "Certificate management complete"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main_manage_certificates "$@"
