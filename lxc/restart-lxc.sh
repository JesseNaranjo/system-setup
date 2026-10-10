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
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    readonly SCRIPT_DIR
fi

if [[ ! -f "${SCRIPT_DIR}/utils-lxc.sh" ]]; then
    printf 'utils-lxc.sh not found in %s: download it and _download-lxc-scripts.sh there, then run ./_download-lxc-scripts.sh\n' "${SCRIPT_DIR}" >&2
    exit 69
fi
# shellcheck source=utils-lxc.sh
source "${SCRIPT_DIR}/utils-lxc.sh"

main() {
    sweep_stale_temps '~*.tmp.??????'
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

        # -1: one bare name per line. lxc-ls already prints that way when stdout
        # is not a tty (lxc-ls(1)), which a command substitution never is; the
        # flag makes the format explicit rather than a side effect of the capture.
        # Captured first rather than fed to mapfile through a process
        # substitution: mapfile cannot report lxc-ls's exit status, so a failing
        # lxc-ls would read as "no running containers" instead of aborting.
        local running_list
        running_list=$(/usr/bin/lxc-ls -1 --running)

        if [[ -z "$running_list" ]]; then
            print_warning "⚠ No running containers found"
            exit 0
        fi

        mapfile -t RUNNING <<< "$running_list"
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
