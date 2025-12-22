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

readonly MINIKUBE_BASE_URL="https://storage.googleapis.com/minikube/releases/latest"

main() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Please run: sudo $0"
        return 1
    fi

    local arch=$(dpkg --print-architecture)

    if [[ "$arch" != "amd64" && "$arch" != "arm64" ]]; then
        print_error "Unsupported architecture: $arch (only amd64 and arm64 are currently supported)"
        return 1
    fi

    local deb_url="${MINIKUBE_BASE_URL}/minikube_latest_${arch}.deb"
    local deb_path=$(mktemp --suffix=.deb)
    trap 'rm -f "${deb_path}"' EXIT

    print_info "Downloading minikube for ${arch} to ${deb_path}..."
    if ! curl -fsSL -o "${deb_path}" "${deb_url}"; then
        print_error "Failed to download minikube from ${deb_url}"
        return 1
    fi

    print_info "Installing minikube..."
    if apt install -y "${deb_path}"; then
        print_success "Minikube installed/updated successfully!"
    else
        print_error "Minikube installation failed"
        return 1
    fi
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
