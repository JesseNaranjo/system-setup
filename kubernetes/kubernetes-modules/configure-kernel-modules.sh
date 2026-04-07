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

# Load a kernel module if not already loaded
# Args: module_name
load_module() {
    local module="$1"

    if is_module_loaded "$module"; then
        print_success "- ${module} already loaded"
        return 0
    fi

    # Check if built into kernel (not a loadable module)
    if [[ -d "/sys/module/${module}" ]]; then
        print_success "- ${module} built into kernel"
        return 0
    fi

    print_info "Loading kernel module: ${module}..."
    modprobe "$module" || { print_error "✖ Failed to load kernel module: ${module}"; return 1; }
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
        if ! grep_file -q "^${module}$" "$MODULES_CONF"; then
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
    detect_environment || { print_error "✖ Failed to detect environment"; return 1; }

    # Container environment: cannot load kernel modules, verify availability from host
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        print_info "Container environment detected — verifying kernel module availability from host..."
        local module
        local all_available=true
        for module in "${REQUIRED_MODULES[@]}"; do
            if is_module_available "$module"; then
                print_success "- ${module} available"
            else
                print_warning "⚠ ${module} not available — host may need to load this module"
                all_available=false
            fi
        done
        if [[ "$all_available" == false ]]; then
            print_warning "⚠ Some kernel modules are not available. Kubernetes networking may not work correctly"
        fi
        persist_modules || return 1
        print_success "Kernel module configuration complete (container mode)"
        return 0
    fi

    if ! command -v modprobe &>/dev/null; then
        print_warning "⚠ modprobe not found; cannot load kernel modules"
        if prompt_yes_no "Install kmod (provides modprobe/lsmod)?" "y"; then
            apt install kmod || { print_error "✖ Failed to install kmod"; return 1; }
            print_success "✓ kmod installed"
        else
            print_info "Skipped kmod installation"
            return 1
        fi
    fi

    print_info "Configuring required kernel modules..."

    local module
    for module in "${REQUIRED_MODULES[@]}"; do
        load_module "$module" || return 1
    done

    persist_modules || return 1

    print_success "Kernel module configuration complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_for_updates "${BASH_SOURCE[0]}" "$@"
    main_configure_kernel_modules "$@"
fi
