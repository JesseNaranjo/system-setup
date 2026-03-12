#!/usr/bin/env bash
# install-update-minikube.sh - Install or update minikube on Linux
# Supports apt (deb), dnf (rpm), and zypper (rpm) package managers
set -euo pipefail

# SCRIPT_DIR fallback for standalone execution
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

readonly MINIKUBE_BASE_URL="https://storage.googleapis.com/minikube/releases/latest"

# ============================================================================
# Prerequisites
# ============================================================================

check_prerequisites() {
    if ! command -v curl &>/dev/null; then
        print_error "curl is required but not installed"
        return 1
    fi
}

# ============================================================================
# Architecture Detection
# ============================================================================

# Get architecture name for DEB packages (amd64, arm64)
get_deb_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)       echo "unsupported" ;;
    esac
}

# Get architecture name for RPM packages (x86_64, aarch64)
get_rpm_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        *)       echo "unsupported" ;;
    esac
}

# ============================================================================
# Version Check
# ============================================================================

# Check whether minikube needs to be installed or updated.
# Returns:
#   0 - install or update should proceed
#   1 - already up-to-date, skip
check_minikube_version() {
    if ! command -v minikube &>/dev/null; then
        print_info "Minikube is not installed"
        return 0
    fi

    local update_output
    if ! update_output=$(minikube update-check 2>&1); then
        print_warning "Could not check minikube version (no network?), proceeding with install"
        return 0
    fi

    local current_version latest_version
    current_version=$(echo "$update_output" | grep -i "^CurrentVersion:" | awk '{print $2}' || true)
    latest_version=$(echo "$update_output" | grep -i "^LatestVersion:" | awk '{print $2}' || true)

    if [[ -z "$current_version" || -z "$latest_version" ]]; then
        print_warning "Could not parse minikube version info, proceeding with install"
        return 0
    fi

    if [[ "$current_version" == "$latest_version" ]]; then
        print_success "Minikube ${current_version} is already up-to-date"
        return 1
    fi

    print_info "Minikube update available: ${current_version} -> ${latest_version}"
    return 0
}

# ============================================================================
# Entry Point
# ============================================================================

main_install_update_minikube() {
    detect_environment || { print_error "Failed to detect environment"; return 1; }
    check_prerequisites || return 1

    # Check if already up-to-date
    if ! check_minikube_version; then
        return 0
    fi

    detect_package_manager || { print_error "Failed to detect package manager"; return 1; }

    local arch pkg_ext pkg_url install_cmd

    case "$DETECTED_PKG_MANAGER" in
        apt)
            arch=$(get_deb_arch)
            pkg_ext="deb"
            pkg_url="${MINIKUBE_BASE_URL}/minikube_latest_${arch}.deb"
            install_cmd="apt install -y"
            ;;
        dnf | zypper)
            arch=$(get_rpm_arch)
            pkg_ext="rpm"
            pkg_url="${MINIKUBE_BASE_URL}/minikube-latest.${arch}.rpm"
            install_cmd="${DETECTED_PKG_MANAGER} install -y"
            ;;
        *)
            print_error "Unsupported package manager: ${DETECTED_PKG_MANAGER} (only apt, dnf, and zypper are supported)"
            return 1
            ;;
    esac

    if [[ "$arch" == "unsupported" ]]; then
        print_error "Unsupported architecture: $(uname -m) (only x86_64 and aarch64 are supported)"
        return 1
    fi

    local pkg_path
    pkg_path=$(mktemp --suffix=".${pkg_ext}") || { print_error "Failed to create temp file"; return 1; }

    print_info "Detected package manager: ${DETECTED_PKG_MANAGER}"
    print_info "Downloading minikube for ${arch} to ${pkg_path}..."
    if ! curl -fsSL -o "${pkg_path}" "${pkg_url}"; then
        rm -f "${pkg_path}"
        print_error "Failed to download minikube from ${pkg_url}"
        return 1
    fi

    print_info "Installing minikube..."
    if $install_cmd "${pkg_path}"; then
        rm -f "${pkg_path}"
        print_success "Minikube installed/updated successfully"
    else
        rm -f "${pkg_path}"
        print_error "Minikube installation failed"
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_install_update_minikube "$@"
fi
