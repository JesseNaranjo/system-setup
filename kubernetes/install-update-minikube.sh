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

# Detect the system's package manager
# Returns: "apt", "dnf", "zypper", or "unknown"
detect_package_manager() {
    if command -v apt &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

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

readonly MINIKUBE_BASE_URL="https://storage.googleapis.com/minikube/releases/latest"

main() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Please run: sudo $0"
        return 1
    fi

    local pkg_manager=$(detect_package_manager)
    local arch pkg_url pkg_path pkg_ext install_cmd

    case "$pkg_manager" in
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
            install_cmd="${pkg_manager} install -y"
            ;;
        *)
            print_error "Unsupported package manager (only apt, dnf, and zypper are supported)"
            return 1
            ;;
    esac

    if [[ "$arch" == "unsupported" ]]; then
        print_error "Unsupported architecture: $(uname -m) (only x86_64 and aarch64 are supported)"
        return 1
    fi

    pkg_path=$(mktemp --suffix=".${pkg_ext}")
    trap 'rm -f "${pkg_path}"' EXIT

    print_info "Detected package manager: ${pkg_manager}"
    print_info "Downloading minikube for ${arch} to ${pkg_path}..."
    if ! curl -fsSL -o "${pkg_path}" "${pkg_url}"; then
        print_error "Failed to download minikube from ${pkg_url}"
        return 1
    fi

    print_info "Installing minikube..."
    if $install_cmd "${pkg_path}"; then
        print_success "Minikube installed/updated successfully!"
    else
        print_error "Minikube installation failed"
        return 1
    fi
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
