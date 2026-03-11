#!/usr/bin/env bash
# install-update-helm.sh - Install or update Helm using the official installer script
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

readonly HELM_INSTALL_URL="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"

# Verify that curl is available for downloading the installer
check_prerequisites() {
    if ! command -v curl &>/dev/null; then
        print_error "curl is required but not installed"
        return 1
    fi
}

main_install_update_helm() {
    detect_environment

    check_prerequisites || return 1

    if command -v helm &>/dev/null; then
        local current_version
        current_version="$(helm version --short 2>/dev/null || echo "unknown")"
        print_info "Current Helm version: ${current_version}"
    else
        print_info "Helm is not currently installed"
    fi

    local install_script_path
    install_script_path="$(mktemp)"

    print_info "Downloading Helm install script to ${install_script_path}..."
    if ! curl -fsSL -o "${install_script_path}" "${HELM_INSTALL_URL}"; then
        rm -f "${install_script_path}"
        print_error "Failed to download Helm install script"
        return 1
    fi

    print_info "Executing Helm install script..."
    chmod 755 "${install_script_path}"
    if "${install_script_path}"; then
        rm -f "${install_script_path}"
        print_success "Helm installed/updated successfully"
    else
        rm -f "${install_script_path}"
        print_error "Helm installation failed"
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_install_update_helm "$@"
fi
