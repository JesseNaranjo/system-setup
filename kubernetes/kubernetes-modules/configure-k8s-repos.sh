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
    # gpg can be installed interactively; apt and curl are hard requirements
    if ! command -v gpg &>/dev/null; then
        print_warning "gpg not found; required for APT repository key management"
        if prompt_yes_no "Install gpg?" "y"; then
            apt install -y gpg || { print_error "Failed to install gpg"; return 1; }
            print_success "gpg installed"
        else
            print_info "Skipped gpg installation"
            return 1
        fi
    fi

    local missing=()
    for cmd in apt curl; do
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

    if ! grep_file -q "$expected_uri" "$sources_file"; then
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

# Configure an APT repository with GPG key and DEB822-format sources file
# Args: name, keyring_path, sources_path, repo_url
setup_apt_repo() {
    local name="$1"
    local keyring_path="$2"
    local sources_path="$3"
    local repo_url="$4"

    if is_repo_configured "$name" "$sources_path" "$keyring_path" "$repo_url"; then
        print_success "${name} ${K8S_VERSION} repo already configured"
        return 0
    fi

    mkdir -p /etc/apt/keyrings \
        || { print_error "Failed to create /etc/apt/keyrings"; return 1; }

    print_info "Downloading ${name} GPG key..."
    curl -fsSL "${repo_url}Release.key" | gpg --dearmor --yes -o "$keyring_path" \
        || { print_error "Failed to download/import ${name} GPG key"; return 1; }
    print_success "${name} GPG key installed: $keyring_path"

    print_info "Creating ${name} apt sources file..."
    if ! tee "$sources_path" > /dev/null << EOF
Types: deb
URIs: ${repo_url}
Suites: /
Components:
Signed-By: ${keyring_path}
EOF
    then
        print_error "Failed to write $sources_path"
        return 1
    fi
    print_success "${name} sources file created: $sources_path"
}

# Determine whether a repository should be configured.
# Auto-configures if packages from the repo are already installed (needed for updates).
# Otherwise prompts the user.
# Returns: 0 if repo should be configured, 1 to skip.
should_configure_repo() {
    local name="$1"
    shift
    local packages=("$@")

    for pkg in "${packages[@]}"; do
        if is_package_installed "$pkg"; then
            print_info "${name} packages detected, configuring repository for updates"
            return 0
        fi
    done

    prompt_yes_no "Configure ${name} repository? (needed to install ${name} packages)" "n"
}

# Check if newer Kubernetes versions are available at pkgs.k8s.io.
# Probes up to 2 minor versions ahead of the current K8S_VERSION.
# Informational only — does not modify K8S_VERSION.
check_newer_k8s_versions() {
    local current_minor
    current_minor="${K8S_VERSION#v1.}"

    if [[ ! "$current_minor" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    local newer_versions=()

    for offset in 1 2; do
        local check_minor=$(( current_minor + offset ))
        local check_version="v1.${check_minor}"
        local check_url="https://pkgs.k8s.io/core:/stable:/${check_version}/deb/Release"

        if curl -fsSL --head --connect-timeout 5 "$check_url" >/dev/null 2>&1; then
            newer_versions+=("$check_version")
        fi
    done

    if [[ ${#newer_versions[@]} -gt 0 ]]; then
        print_info "Newer Kubernetes versions available: ${newer_versions[*]} (current: ${K8S_VERSION})"
        print_info "To upgrade: update K8S_VERSION in kubernetes-setup.sh and re-run"
    fi
}

setup_kubernetes_repo() {
    setup_apt_repo "Kubernetes" \
        "/etc/apt/keyrings/kubernetes-apt-keyring.gpg" \
        "/etc/apt/sources.list.d/kubernetes.sources" \
        "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/"
}

setup_crio_repo() {
    setup_apt_repo "CRI-O" \
        "/etc/apt/keyrings/cri-o-apt-keyring.gpg" \
        "/etc/apt/sources.list.d/cri-o.sources" \
        "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${K8S_VERSION}/deb/"
}

# ============================================================================
# Entry Point
# ============================================================================

main_configure_k8s_repos() {
    detect_environment || { print_error "Failed to detect environment"; return 1; }

    print_info "Configuring Kubernetes APT repositories..."

    check_prerequisites || return 1
    cleanup_deprecated_files || print_warning "Deprecated file cleanup failed, continuing"

    local repos_configured=false

    if should_configure_repo "Kubernetes" "kubeadm" "kubectl" "kubelet"; then
        setup_kubernetes_repo || return 1
        K8S_REPO_CONFIGURED=true
        repos_configured=true
    else
        print_info "Skipping Kubernetes repository configuration"
    fi

    if should_configure_repo "CRI-O" "cri-o"; then
        setup_crio_repo || return 1
        CRIO_REPO_CONFIGURED=true
        repos_configured=true
    else
        print_info "Skipping CRI-O repository configuration"
    fi

    if [[ "$repos_configured" == true ]]; then
        print_info "Refreshing package lists..."
        apt update || { print_error "Failed to refresh package lists"; return 1; }
        check_newer_k8s_versions
    else
        print_info "No repositories configured, skipping package list refresh"
    fi

    print_success "Repository configuration complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_k8s_repos "$@"
fi
