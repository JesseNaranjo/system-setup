#!/usr/bin/env bash
# install-k8s-packages.sh - Role-based Kubernetes package installation
# Handles role selection, APT repository configuration, and package installation.
# When called from the orchestrator, SELECTED_ROLE is already set.
# When run standalone, prompts for role selection.
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
# Role Selection
# ============================================================================

# Prompt user to select the node role for package installation
# Sets global SELECTED_ROLE to: control-plane, worker, kubectl-only, or skip
select_node_role() {
    echo ""
    print_info "What role will this machine serve?"
    echo ""
    echo "  1) Kubernetes Control Plane"
    echo "     Installs: kubeadm, kubectl, kubelet, cri-o, kmod"
    echo ""
    echo "  2) Kubernetes Worker Node"
    echo "     Installs: kubeadm, kubelet, cri-o, kmod"
    echo ""
    echo "  3) kubectl only (remote cluster management)"
    echo "     Installs: kubectl"
    echo ""
    echo "  4) Skip package installation"
    echo ""

    local choice
    while true; do
        read -r -p "Select [1-4]: " choice </dev/tty
        case "$choice" in
            1) SELECTED_ROLE="control-plane"; break ;;
            2) SELECTED_ROLE="worker"; break ;;
            3) SELECTED_ROLE="kubectl-only"; break ;;
            4) SELECTED_ROLE="skip"; break ;;
            *) print_error "✖ Invalid option: ${choice}. Please select 1-4." ;;
        esac
    done

    print_info "Selected role: ${SELECTED_ROLE}"
}

# ============================================================================
# Role-Based Package Mapping
# ============================================================================

# Get the list of packages for a given node role
# Args: role (control-plane, worker, kubectl-only)
# Returns: newline-separated "Display Name:package_name" pairs
get_role_packages() {
    local role="$1"
    case "$role" in
        control-plane)
            echo "kubeadm:kubeadm"
            echo "kubectl:kubectl"
            echo "kubelet:kubelet"
            echo "CRI-O:cri-o"
            echo "kmod:kmod"
            ;;
        worker)
            echo "kubeadm:kubeadm"
            echo "kubelet:kubelet"
            echo "CRI-O:cri-o"
            echo "kmod:kmod"
            ;;
        kubectl-only)
            echo "kubectl:kubectl"
            ;;
    esac
}

# ============================================================================
# APT Repository Setup (absorbed from configure-k8s-repos.sh)
# ============================================================================

# Ensure gpg is available (needed for APT repository key management)
ensure_gpg() {
    command -v gpg &>/dev/null && return 0

    print_warning "⚠ gpg not found; required for APT repository key management"
    if prompt_yes_no "Install gpg?" "y"; then
        apt install gpg || { print_error "✖ Failed to install gpg"; return 1; }
        print_success "✓ gpg installed"
    else
        print_info "Skipped gpg installation"
        return 1
    fi
}

# Check whether a repository is already configured with the expected URI
# Args: sources_file, keyring_file, expected_uri
# Returns: 0 if fully configured, 1 otherwise
is_repo_configured() {
    local sources_file="$1"
    local keyring_file="$2"
    local expected_uri="$3"

    [[ -f "$sources_file" ]] && [[ -f "$keyring_file" ]] \
        && grep_file -q "$expected_uri" "$sources_file"
}

# Configure an APT repository with GPG key and DEB822-format sources file
# Args: name, keyring_path, sources_path, repo_url
setup_apt_repo() {
    local name="$1"
    local keyring_path="$2"
    local sources_path="$3"
    local repo_url="$4"

    if is_repo_configured "$sources_path" "$keyring_path" "$repo_url"; then
        print_success "- ${name} ${K8S_VERSION} repo already configured"
        return 0
    fi

    mkdir -p /etc/apt/keyrings \
        || { print_error "✖ Failed to create /etc/apt/keyrings"; return 1; }

    print_info "Downloading ${name} GPG key..."
    curl -fsSL "${repo_url}Release.key" | gpg --dearmor --yes -o "$keyring_path" \
        || { print_error "✖ Failed to download/import ${name} GPG key"; return 1; }
    print_success "✓ ${name} GPG key installed: $keyring_path"

    print_info "Creating ${name} apt sources file..."
    if ! tee "$sources_path" > /dev/null << EOF
Types: deb
URIs: ${repo_url}
Suites: /
Components:
Signed-By: ${keyring_path}
EOF
    then
        print_error "✖ Failed to write $sources_path"
        return 1
    fi
    print_success "✓ ${name} sources file created: $sources_path"
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

# Remove deprecated one-line-style repository files
cleanup_deprecated_repo_files() {
    local deprecated_files=(
        "/etc/apt/sources.list.d/kubernetes.list"
        "/etc/apt/sources.list.d/kubernetes.list.bak"
        "/etc/apt/sources.list.d/cri-o.list"
        "/etc/apt/sources.list.d/cri-o.list.bak"
    )

    local file
    for file in "${deprecated_files[@]}"; do
        if [[ -f "$file" ]]; then
            print_info "Removing deprecated file: $file"
            rm -f "$file"
        fi
    done
}

# Check if newer Kubernetes versions are available at pkgs.k8s.io
# Probes up to 2 minor versions ahead of the current K8S_VERSION
check_newer_k8s_versions() {
    local current_minor
    current_minor="${K8S_VERSION#v1.}"

    [[ ! "$current_minor" =~ ^[0-9]+$ ]] && return 0

    local newer_versions=()
    local offset
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

# Configure APT repositories needed for the given packages
# Only sets up repos that aren't already configured
# Args: package names as separate arguments
ensure_repos_for_packages() {
    local packages=("$@")
    local need_k8s_repo=false
    local need_crio_repo=false

    local pkg
    for pkg in "${packages[@]}"; do
        case "$pkg" in
            kubeadm|kubectl|kubelet) need_k8s_repo=true ;;
            cri-o) need_crio_repo=true ;;
        esac
    done

    if [[ "$need_k8s_repo" != true && "$need_crio_repo" != true ]]; then
        return 0
    fi

    # gpg and curl are prerequisites for repo setup
    ensure_gpg || return 1
    if ! command -v curl &>/dev/null; then
        print_error "✖ curl is required for repository setup"
        return 1
    fi

    cleanup_deprecated_repo_files

    local repos_configured=false

    if [[ "$need_k8s_repo" == true ]]; then
        setup_kubernetes_repo || return 1
        repos_configured=true
    fi

    if [[ "$need_crio_repo" == true ]]; then
        setup_crio_repo || return 1
        repos_configured=true
    fi

    if [[ "$repos_configured" == true ]]; then
        print_info "Refreshing package lists..."
        apt update || { print_error "✖ Failed to refresh package lists"; return 1; }
        check_newer_k8s_versions
    fi
}

# ============================================================================
# Package Installation
# ============================================================================

# Install missing packages for the selected role
# Shows status, confirms with user, configures repos, installs in one apt call
# Args: role
install_role_packages() {
    local role="$1"

    if ! verify_package_manager; then
        print_warning "⚠ No supported package manager found on this system."
        return 1
    fi

    if ! check_privileges "package_install"; then
        print_warning "⚠ Cannot install packages without root privileges"
        return 1
    fi

    local role_label
    case "$role" in
        control-plane) role_label="Control Plane" ;;
        worker) role_label="Worker Node" ;;
        kubectl-only) role_label="kubectl only" ;;
        *) print_error "✖ Unknown role: ${role}"; return 1 ;;
    esac

    # Show status and collect missing packages
    local missing=()
    echo ""
    print_info "Packages for ${role_label} role:"

    while IFS=':' read -r display_name package_name; do
        if is_package_installed "$package_name"; then
            print_success "  ✓ ${display_name} (installed)"
            track_special_packages "$package_name"
        else
            print_warning "  ✖ ${display_name} (not installed)"
            missing+=("$package_name")
        fi
    done < <(get_role_packages "$role")

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo ""
        print_success "All packages for ${role_label} role are already installed"
        return 0
    fi

    # Confirm before installing
    echo ""
    if ! prompt_yes_no "Install ${#missing[@]} missing package(s)?" "y"; then
        print_info "Skipping package installation"
        return 0
    fi

    # Configure repos for the packages that need them
    ensure_repos_for_packages "${missing[@]}" || return 1

    # Install all missing packages in one call
    echo ""
    print_info "Installing: ${missing[*]}..."
    if apt install "${missing[@]}"; then
        print_success "✓ All packages installed successfully"
        invalidate_package_cache
        local pkg
        for pkg in "${missing[@]}"; do
            if is_package_installed "$pkg"; then
                track_special_packages "$pkg"
            fi
        done
    else
        print_error "✖ Package installation failed"
        return 1
    fi
}

# ============================================================================
# Entry Point
# ============================================================================

main_install_k8s_packages() {
    detect_environment || { print_error "✖ Failed to detect environment"; return 1; }

    # When run standalone, prompt for role selection
    if [[ -z "${SELECTED_ROLE:-}" ]]; then
        select_node_role || return 1
    fi

    if [[ "$SELECTED_ROLE" == "skip" ]]; then
        print_info "Skipping package installation"
        return 0
    fi

    install_role_packages "$SELECTED_ROLE"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_for_updates "${BASH_SOURCE[0]}" "$@"
    main_install_k8s_packages "$@"
fi
