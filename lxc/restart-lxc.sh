#!/usr/bin/env bash

# restart-lxc.sh - Restart LXC containers
#
# Usage: ./restart-lxc.sh [container_name] [[container_name], ...]
#
# This script restarts one or more LXC containers by stopping and then starting them.
# If no container names are provided, it will restart all currently running containers.
#
# Examples:
#   ./restart-lxc.sh                    # Restart all running containers
#   ./restart-lxc.sh mycontainer        # Restart a specific container
#   ./restart-lxc.sh web db cache       # Restart multiple containers

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Print colored output
print_info() {
    echo -e "${BLUE}[   INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# ============================================================================
# Main Script
# ============================================================================

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -eq 0 || -z ${1-} ]]; then
    # No LXCs specified, so restart all running LXCs
    print_info "No containers specified, restarting all running containers..."

    #lxc-ls --running
    RUNNING=( $(/usr/bin/lxc-ls --running) )

    if [[ ${#RUNNING[@]} -eq 0 ]]; then
        print_warning "- No running containers found"
        exit 0
    fi
else
    RUNNING=("$@")
fi

print_info "Restarting ${#RUNNING[@]} container(s): ${RUNNING[*]}"
echo ""

"${SCRIPT_DIR}/stop-lxc.sh" "${RUNNING[@]}"
sleep 1
"${SCRIPT_DIR}/start-lxc.sh" "${RUNNING[@]}"

echo ""
print_success "Container restart sequence completed"
