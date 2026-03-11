#!/usr/bin/env bash
# configure-k8s-repos.sh - Configure Kubernetes and CRI-O APT repositories
# Adds DEB822-format sources files and GPG keys for Kubernetes and CRI-O packages
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# Orchestrator sets K8S_VERSION; provide a default for standalone execution
if [[ -z "${K8S_VERSION:-}" ]]; then
    readonly K8S_VERSION="v1.35"
fi

# ============================================================================
# Prerequisites
# ============================================================================

check_prerequisites() {
    local missing=()

    for cmd in apt curl gpg; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing required commands: ${missing[*]}"
        return 1
    fi
}

# ============================================================================
# Idempotency Check
# ============================================================================

# Check whether a repository is already configured with the expected URI
# Args: name, sources_file, keyring_file, expected_uri
# Returns 0 if fully configured, 1 otherwise
is_repo_configured() {
    local name="$1"
    local sources_file="$2"
    local keyring_file="$3"
    local expected_uri="$4"

    if [[ ! -f "$sources_file" ]]; then
        return 1
    fi

    if [[ ! -f "$keyring_file" ]]; then
        return 1
    fi

    if ! grep -q "$expected_uri" "$sources_file"; then
        return 1
    fi

    return 0
}

# ============================================================================
# Cleanup
# ============================================================================

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
            rm -f "$file"
        fi
    done
}

# ============================================================================
# Repository Setup
# ============================================================================

setup_kubernetes_repo() {
    local keyring_path="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    local sources_path="/etc/apt/sources.list.d/kubernetes.sources"
    local repo_url="https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/"

    if is_repo_configured "Kubernetes" "$sources_path" "$keyring_path" "$repo_url"; then
        print_success "Kubernetes ${K8S_VERSION} repo already configured"
        return 0
    fi

    mkdir -p /etc/apt/keyrings

    print_info "Downloading Kubernetes GPG key..."
    curl -fsSL "${repo_url}Release.key" | gpg --dearmor --yes -o "$keyring_path"
    print_success "Kubernetes GPG key installed: $keyring_path"

    print_info "Creating Kubernetes apt sources file..."
    tee "$sources_path" > /dev/null << EOF
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

    if is_repo_configured "CRI-O" "$sources_path" "$keyring_path" "$repo_url"; then
        print_success "CRI-O ${K8S_VERSION} repo already configured"
        return 0
    fi

    mkdir -p /etc/apt/keyrings

    print_info "Downloading CRI-O GPG key..."
    curl -fsSL "${repo_url}Release.key" | gpg --dearmor --yes -o "$keyring_path"
    print_success "CRI-O GPG key installed: $keyring_path"

    print_info "Creating CRI-O apt sources file..."
    tee "$sources_path" > /dev/null << EOF
Types: deb
URIs: ${repo_url}
Suites: /
Components:
Signed-By: ${keyring_path}
EOF
    print_success "CRI-O sources file created: $sources_path"
}

# ============================================================================
# Entry Point
# ============================================================================

main_configure_k8s_repos() {
    detect_environment

    print_info "Configuring Kubernetes APT repositories..."

    check_prerequisites || return 1
    cleanup_deprecated_files
    setup_kubernetes_repo
    setup_crio_repo

    print_info "Refreshing package lists..."
    apt update

    print_success "Repository configuration complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_k8s_repos "$@"
fi
