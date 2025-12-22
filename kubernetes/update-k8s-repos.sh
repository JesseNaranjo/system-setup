#!/usr/bin/env bash
set -euo pipefail

# Kubernetes version to install
readonly K8S_VERSION=v1.35

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

print_info() { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }
print_error() { echo -e "${RED}[ ERROR   ]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[ WARNING ]${NC} $1"; }

cleanup_deprecated_files() {
    local deprecated_files=(
        "/etc/apt/sources.list.d/kubernetes.list"
        "/etc/apt/sources.list.d/kubernetes.list.bak"
        "/etc/apt/sources.list.d/cri-o.list"
        "/etc/apt/sources.list.d/cri-o.list.bak"
    )

    for file in "${deprecated_files[@]}"; do
        if [[ -f "$file" ]]; then
            print_info "Removing deprecated file: $file"
            sudo rm -f "$file"
        fi
    done
}

setup_kubernetes_repo() {
    local keyring_path="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    local sources_path="/etc/apt/sources.list.d/kubernetes.sources"
    local repo_url="https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/"

    print_info "Downloading Kubernetes GPG key..."
    curl -fsSL "${repo_url}Release.key" | sudo gpg --dearmor --yes -o "$keyring_path"
    print_success "Kubernetes GPG key installed: $keyring_path"

    print_info "Creating Kubernetes apt sources file..."
    sudo tee "$sources_path" > /dev/null << EOF
Types: deb
URIs: ${repo_url}
Suites: /
Components:
Signed-By: ${keyring_path}
EOF
    print_success "Kubernetes sources file created: $sources_path"
}

setup_crio_repo() {
    local keyring_path="/etc/apt/keyrings/cri-o-apt-keyring.gpg"
    local sources_path="/etc/apt/sources.list.d/cri-o.sources"
    local repo_url="https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${K8S_VERSION}/deb/"

    print_info "Downloading CRI-O GPG key..."
    curl -fsSL "${repo_url}Release.key" | sudo gpg --dearmor --yes -o "$keyring_path"
    print_success "CRI-O GPG key installed: $keyring_path"

    print_info "Creating CRI-O apt sources file..."
    sudo tee "$sources_path" > /dev/null << EOF
Types: deb
URIs: ${repo_url}
Suites: /
Components:
Signed-By: ${keyring_path}
EOF
    print_success "CRI-O sources file created: $sources_path"
}

main() {
    print_info "Setting up Kubernetes ${K8S_VERSION} apt repositories..."

    # Ensure keyrings directory exists
    sudo mkdir -p /etc/apt/keyrings

    cleanup_deprecated_files
    setup_kubernetes_repo
    setup_crio_repo

    print_success "Kubernetes apt repositories configured successfully!"
    print_info "Run 'sudo apt update' to refresh package lists."
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
