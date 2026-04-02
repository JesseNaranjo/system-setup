#!/usr/bin/env bash

# restart-lxc.sh - Restart LXC containers
#
# Usage: ./restart-lxc.sh [--privileged] [container_name] [[container_name], ...]
#
# This script restarts one or more LXC containers by stopping and then starting them.
# If no container names are provided, it will restart all currently running containers.
#
# Options:
#   --privileged  Restart privileged containers (requires root, uses system-scope services)
#
# Examples:
#   ./restart-lxc.sh                         # Restart all running containers
#   ./restart-lxc.sh mycontainer             # Restart a specific container
#   ./restart-lxc.sh web db cache            # Restart multiple containers
#   ./restart-lxc.sh --privileged web        # Restart a privileged container (as root)

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

print_error() {
    echo -e "${RED}[ ERROR   ]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ WARNING ]${NC} $1"
}

# ============================================================================
# Main Script
# ============================================================================

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PRIVILEGED=false
CONTAINERS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --privileged)
            PRIVILEGED=true
            shift
            ;;
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

# Privileged mode requires root
if [[ "$PRIVILEGED" == true && $EUID != 0 ]]; then
    print_error "✖ --privileged requires root."
    exit 1
fi

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

PRIV_FLAG=()
[[ "$PRIVILEGED" == true ]] && PRIV_FLAG=(--privileged)

print_info "Restarting ${#RUNNING[@]} container(s): ${RUNNING[*]}"
echo ""

"${SCRIPT_DIR}/stop-lxc.sh" ${PRIV_FLAG[@]+"${PRIV_FLAG[@]}"} "${RUNNING[@]}"
sleep 0.25
"${SCRIPT_DIR}/start-lxc.sh" ${PRIV_FLAG[@]+"${PRIV_FLAG[@]}"} "${RUNNING[@]}"

echo ""
print_success "Container restart sequence completed"
