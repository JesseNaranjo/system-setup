#!/usr/bin/env bash

# stop-lxc.sh - Stop LXC containers
#
# Usage: ./stop-lxc.sh [container_name] [[container_name], ...]
#
# This script stops one or more LXC containers gracefully using lxc-stop
# and their associated systemd services.
#
# If no container names are provided, it will stop all currently running containers.
#
# The script performs a two-step shutdown:
# 1. Gracefully stops the container using lxc-stop
# 2. Stops the associated systemd service to clean up the service state
#
# When run as root (e.g., via sudo), the script operates on privileged
# (system-scope) containers. Otherwise, it operates on unprivileged
# (user-scope) containers.
#
# Examples:
#   ./stop-lxc.sh                       # Stop all running containers
#   ./stop-lxc.sh mycontainer           # Stop a specific container
#   ./stop-lxc.sh web db cache          # Stop multiple containers
#   sudo ./stop-lxc.sh web              # Stop a privileged container

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Print colored output
print_info() {
    echo -e "${BLUE}[ INFO    ]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[ SUCCESS ]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ WARNING ]${NC} $1"
}

print_error() {
    echo -e "${RED}[ ERROR   ]${NC} $1"
}

# ============================================================================
# Main Script
# ============================================================================

main() {
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

    # Root = privileged (system-scope), non-root = unprivileged (user-scope)
    local PRIVILEGED
    if [[ $EUID == 0 ]]; then
        PRIVILEGED=true
    else
        PRIVILEGED=false
    fi

    local RUNNING
    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        # No LXCs specified, so stop all running LXCs
        print_info "No containers specified, stopping all running containers..."

        RUNNING=( $(/usr/bin/lxc-ls --running) )

        if [[ ${#RUNNING[@]} -eq 0 ]]; then
            print_warning "⚠ No running containers found"
            exit 0
        fi
    else
        RUNNING=("${CONTAINERS[@]}")
    fi

    print_info "Stopping ${#RUNNING[@]} container(s)..."
    echo ""

    local lxcName
    for lxcName in "${RUNNING[@]}"; do
        print_info "Stopping ${lxcName}..."

        # Stop the container
        if lxc-stop --name "${lxcName}"; then
            print_success "✓ Container stopped: ${lxcName}"
        else
            print_error "✖ Failed to stop container: ${lxcName}"
        fi
        sleep 0.5

        # Stop the systemd service
        local SERVICE
        if [[ "$PRIVILEGED" == true ]]; then
            SERVICE="lxc-priv-bg-start@${lxcName}.service"
            if systemctl stop "$SERVICE" 2>/dev/null; then
                print_success "✓ Service stopped: ${SERVICE}"
            else
                print_warning "⚠ Service may not be running: ${SERVICE}"
            fi
        else
            SERVICE="lxc-bg-start@${lxcName}.service"
            if systemctl --user stop "$SERVICE" 2>/dev/null; then
                print_success "✓ Service stopped: ${SERVICE}"
            else
                print_warning "⚠ Service may not be running: ${SERVICE}"
            fi
        fi
        sleep 0.25
    done

    echo ""
    lxc-ls --fancy

    echo ""
    print_success "Container shutdown sequence completed"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
