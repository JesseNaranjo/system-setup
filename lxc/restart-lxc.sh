#!/usr/bin/env bash

# restart-lxc.sh - Restart LXC containers
#
# Usage: ./restart-lxc.sh [container_name] [[container_name], ...]
#
# This script restarts one or more LXC containers by stopping and then starting them.
# If no container names are provided, it will restart all currently running containers.
#
# When run as root (e.g., via sudo), the script operates on privileged
# (system-scope) containers. Otherwise, it operates on unprivileged
# (user-scope) containers.
#
# Examples:
#   ./restart-lxc.sh                         # Restart all running containers
#   ./restart-lxc.sh mycontainer             # Restart a specific container
#   ./restart-lxc.sh web db cache            # Restart multiple containers
#   sudo ./restart-lxc.sh web               # Restart a privileged container

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=utils-lxc.sh
source "${SCRIPT_DIR}/utils-lxc.sh"

main() {
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    local CONTAINERS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -*)
                print_error "✖ Unknown option: $1"
                exit 64  # EX_USAGE
                ;;
            *)
                CONTAINERS+=("$1")
                shift
                ;;
        esac
    done

    local RUNNING

    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        # No LXCs specified, so restart all running LXCs
        print_info "No containers specified, restarting all running containers..."

        RUNNING=( $(/usr/bin/lxc-ls --running) )

        if [[ ${#RUNNING[@]} -eq 0 ]]; then
            print_warning "⚠ No running containers found"
            exit 0
        fi
    else
        RUNNING=("${CONTAINERS[@]}")
    fi

    print_info "Restarting ${#RUNNING[@]} container(s): ${RUNNING[*]}"
    echo ""

    "${SCRIPT_DIR}/stop-lxc.sh" "${RUNNING[@]}"
    sleep 0.25
    "${SCRIPT_DIR}/start-lxc.sh" "${RUNNING[@]}"

    echo ""
    print_success "Container restart sequence completed"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
