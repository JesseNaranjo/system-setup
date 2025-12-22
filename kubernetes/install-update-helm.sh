#!/usr/bin/env bash
set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

print_info() { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }
print_error() { echo -e "${RED}[ ERROR   ]${NC} $1"; }

readonly HELM_INSTALL_URL="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"

main() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Please run: sudo $0"
        return 1
    fi

    local install_script_path=$(mktemp)
    trap 'rm -f "${install_script_path}"' EXIT

    print_info "Downloading Helm install script to ${install_script_path}..."
    if ! curl -fsSL -o "${install_script_path}" "${HELM_INSTALL_URL}"; then
        print_error "Failed to download Helm install script"
        return 1
    fi

    print_info "Executing Helm install script..."
    chmod 755 "${install_script_path}"
    if "${install_script_path}"; then
        print_success "Helm installed/updated successfully!"
    else
        print_error "Helm installation failed"
        return 1
    fi
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
