#!/usr/bin/env bash

# unprotect-lxc.sh - Remove destroy-protection from LXC containers
#
# Usage: ./unprotect-lxc.sh <container_name> [container_name ...]
#
# Removes the lxc.hook.destroy sentinel that protect-lxc.sh adds to a
# container's config, so the container becomes destroyable by lxc-destroy
# again.
#
# When run as root (e.g., via sudo), the script operates on privileged
# (system-scope) containers. Otherwise, it operates on unprivileged
# (user-scope) containers.
#
# Examples:
#   ./unprotect-lxc.sh mycontainer            # Unprotect a specific container
#   ./unprotect-lxc.sh web db cache           # Unprotect multiple containers
#   sudo ./unprotect-lxc.sh web               # Unprotect a privileged container

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=utils-lxc.sh
source "${SCRIPT_DIR}/utils-lxc.sh"

# ============================================================================
# Main Script
# ============================================================================

show_usage() {
    echo "Usage: ${0##*/} <container_name> [container_name ...]"
    echo ""
    echo "Removes protection from container(s), so the container becomes"
    echo "destroyable by lxc-destroy again."
    echo ""
    echo "Options:"
    echo "  --help, -h    Show this help"
    echo ""
    echo "Run as root (sudo) for privileged containers, or as a regular user"
    echo "for unprivileged ones — the scope follows the invoking EUID."
}

# Unprotect one container, printing its own outcome.
# Usage: unprotect_one "/var/lib/lxc" "dev-box"
# Returns: 0 on success or already-unprotected, 1 otherwise
unprotect_one() {
    local lxc_path="$1" name="$2"
    local config="${lxc_path}/${name}/config"

    if ! lxc_valid_name "$name"; then
        print_error "✖ Invalid container name: ${name}"
        return 1
    fi

    if [[ ! -f "$config" ]]; then
        print_error "✖ No such container: ${name} (looked for ${config})"
        return 1
    fi

    if ! lxc_is_protected "$config"; then
        print_success "- Not protected: ${name}"
        return 0
    fi

    lxc_unprotect_config "$config" || return 1
    print_success "✓ Unprotected: ${name}"
    print_warning "⚠ ${name} can now be destroyed by lxc-destroy"
}

main() {
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    local CONTAINERS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_usage
                exit 0
                ;;
            -*)
                print_error "✖ Unknown option: $1"
                show_usage
                exit 64  # EX_USAGE
                ;;
            *)
                CONTAINERS+=("$1")
                shift
                ;;
        esac
    done

    local LXC_PATH
    LXC_PATH="$(lxc_resolve_path)"

    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        print_error "✖ Missing required container name argument"
        show_usage
        exit 64  # EX_USAGE
    fi

    local FAILED=false NAME
    for NAME in "${CONTAINERS[@]}"; do
        unprotect_one "$LXC_PATH" "$NAME" || FAILED=true
    done

    [[ "$FAILED" == true ]] && exit 1
    return 0
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
