#!/usr/bin/env bash
# configure-kernel-modules.sh - Load and persist required kernel modules for Kubernetes
# Ensures br_netfilter and overlay modules are loaded and configured to load at boot
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# ============================================================================
# Configuration
# ============================================================================

readonly REQUIRED_MODULES=("br_netfilter" "overlay")
readonly MODULES_CONF="/etc/modules-load.d/k8s.conf"

# ============================================================================
# Module Loading
# ============================================================================

# Check if a kernel module is currently loaded
# Args: module_name
# Returns: 0 if loaded, 1 otherwise
is_module_loaded() {
    local module="$1"
    if command -v lsmod &>/dev/null; then
        lsmod | grep -q "^${module}"
    elif [[ -r /proc/modules ]]; then
        grep -q "^${module} " /proc/modules
    else
        return 1
    fi
}

# Load a kernel module if not already loaded
# Args: module_name
load_module() {
    local module="$1"

    if is_module_loaded "$module"; then
        print_success "- ${module} already loaded"
        return 0
    fi

    print_info "Loading kernel module: ${module}..."
    modprobe "$module"
    print_success "- ${module} loaded"
}

# ============================================================================
# Persistence
# ============================================================================

# Check if the persistence file exists and contains all required modules
# Returns: 0 if fully persisted, 1 otherwise
is_persistence_configured() {
    if [[ ! -f "$MODULES_CONF" ]]; then
        return 1
    fi

    local module
    for module in "${REQUIRED_MODULES[@]}"; do
        if ! grep -q "^${module}$" "$MODULES_CONF"; then
            return 1
        fi
    done

    return 0
}

# Create or update the persistence file with all required modules
persist_modules() {
    if is_persistence_configured; then
        print_success "- ${MODULES_CONF} already configured"
        return 0
    fi

    print_info "Creating ${MODULES_CONF} for boot-time module loading..."
    backup_file "$MODULES_CONF"
    add_change_header "$MODULES_CONF" "modules"

    local module
    for module in "${REQUIRED_MODULES[@]}"; do
        append_to_file "$MODULES_CONF" "$module"
    done

    print_success "- Kernel modules persisted to ${MODULES_CONF}"
}

# ============================================================================
# Entry Point
# ============================================================================

main_configure_kernel_modules() {
    detect_environment

    if ! command -v modprobe &>/dev/null; then
        print_error "modprobe not found; cannot load kernel modules"
        print_info "Install kmod: apt install -y kmod"
        return 1
    fi

    print_info "Configuring required kernel modules..."

    local module
    for module in "${REQUIRED_MODULES[@]}"; do
        load_module "$module"
    done

    persist_modules

    print_success "Kernel module configuration complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_kernel_modules "$@"
fi
