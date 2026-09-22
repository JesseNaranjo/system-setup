#!/usr/bin/env bash

# protect-lxc.sh - Protect LXC containers from destruction
#
# Usage: ./protect-lxc.sh <container_name> [container_name ...]
#        ./protect-lxc.sh --status
#
# Protects container(s) from accidental destruction by adding an
# lxc.hook.destroy sentinel to each container's config. LXC runs that hook
# before it touches the rootfs and aborts the destroy when it fails, so
# lxc-destroy leaves the rootfs and config intact.
#
# When run as root (e.g., via sudo), the script operates on privileged
# (system-scope) containers. Otherwise, it operates on unprivileged
# (user-scope) containers.
#
# Examples:
#   ./protect-lxc.sh mycontainer            # Protect a specific container
#   ./protect-lxc.sh web db cache           # Protect multiple containers
#   ./protect-lxc.sh --status               # List every container and its protection state
#   sudo ./protect-lxc.sh web               # Protect a privileged container

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
    echo "       ${0##*/} --status"
    echo ""
    echo "Protects container(s) from accidental destruction by adding an"
    echo "lxc.hook.destroy sentinel to each container's config. LXC runs that"
    echo "hook before it touches the rootfs and aborts the destroy when it"
    echo "fails, so lxc-destroy leaves the rootfs and config intact. -f still"
    echo "stops a running container before the veto, and -s still removes"
    echo "snapshots and clones made before the container was protected."
    echo ""
    echo "Options:"
    echo "  --status      List every container and its protection state"
    echo "  --help, -h    Show this help"
    echo ""
    echo "Run as root (sudo) for privileged containers, or as a regular user"
    echo "for unprivileged ones — the scope follows the invoking EUID."
}

# Protect one container, printing its own outcome.
# Usage: protect_one "/var/lib/lxc" "dev-box" "2026-09-15"
# Returns: 0 on success or already-protected, 1 otherwise
protect_one() {
    local lxc_path="$1" name="$2" today="$3"
    local config="${lxc_path}/${name}/config"

    if ! lxc_valid_name "$name"; then
        print_error "✖ Invalid container name: ${name}"
        return 1
    fi

    if [[ ! -f "$config" ]]; then
        print_error "✖ No such container: ${name} (looked for ${config})"
        return 1
    fi

    if lxc_is_protected "$config"; then
        print_success "- Already protected: ${name} (since $(lxc_protected_since "$config"))"
        return 0
    fi

    lxc_protect_config "$config" "$today" || return 1
    print_success "✓ Protected: ${name}"
}

# Print every container under an LXC root with its protection state.
# Usage: print_protection_status "/var/lib/lxc"
print_protection_status() {
    local lxc_path="$1"
    local names=()
    mapfile -t names < <(lxc_list_containers "$lxc_path")

    if [[ ${#names[@]} -eq 0 ]]; then
        print_warning "⚠ No containers defined under ${lxc_path}"
        return 0
    fi

    local width=4 name
    for name in "${names[@]}"; do
        (( ${#name} > width )) && width=${#name}
    done

    printf '%b%-*s  %-9s  %s%b\n' "$GRAY" "$width" "NAME" "PROTECTED" "SINCE" "$NC"
    local since
    for name in "${names[@]}"; do
        if since=$(lxc_protected_since "${lxc_path}/${name}/config"); then
            printf '%-*s  %b%-9s%b  %s\n' "$width" "$name" "$GREEN" "yes" "$NC" "$since"
        else
            printf '%-*s  %-9s  -\n' "$width" "$name" "no"
        fi
    done
}

main() {
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    local STATUS_ONLY=false
    local CONTAINERS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status)
                STATUS_ONLY=true
                shift
                ;;
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

    if [[ "$STATUS_ONLY" == true ]]; then
        if [[ ${#CONTAINERS[@]} -gt 0 ]]; then
            print_error "✖ --status takes no container names"
            show_usage
            exit 64  # EX_USAGE
        fi
        print_protection_status "$LXC_PATH"
        exit 0
    fi

    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        print_error "✖ Missing required container name argument"
        show_usage
        exit 64  # EX_USAGE
    fi

    local TODAY
    TODAY=$(date +%Y-%m-%d)

    local FAILED=false NAME
    for NAME in "${CONTAINERS[@]}"; do
        protect_one "$LXC_PATH" "$NAME" "$TODAY" || FAILED=true
    done

    [[ "$FAILED" == true ]] && exit 1
    return 0
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
