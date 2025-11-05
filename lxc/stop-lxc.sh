#!/usr/bin/env bash

# stop-lxc.sh - Stop LXC containers
#
# Usage: ./stop-lxc.sh [container_name] [[container_name], ...]
#
# This script stops one or more LXC containers gracefully using lxc-stop
# and their associated systemd user services.
#
# If no container names are provided, it will stop all currently running containers.
#
# The script performs a two-step shutdown:
# 1. Gracefully stops the container using lxc-stop
# 2. Stops the systemd user service to clean up the service state
#
# Examples:
#   ./stop-lxc.sh                       # Stop all running containers
#   ./stop-lxc.sh mycontainer           # Stop a specific container
#   ./stop-lxc.sh web db cache          # Stop multiple containers

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
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

print_error() {
    echo -e "${RED}[  ERROR]${NC} $1"
}

# ============================================================================
# Main Script
# ============================================================================

if [[ $# -eq 0 || -z ${1-} ]]; then
    # No LXCs specified, so stop all running LXCs
    print_info "No containers specified, stopping all running containers..."

    #lxc-ls --running
    RUNNING=( $(/usr/bin/lxc-ls --running) )

    if [[ ${#RUNNING[@]} -eq 0 ]]; then
        print_warning "- No running containers found"
        exit 0
    fi
else
    RUNNING=("$@")
fi

print_info "Stopping ${#RUNNING[@]} container(s)..."
echo ""

for lxcName in "${RUNNING[@]}"; do
    print_info "Stopping LXC: ${lxcName}..."

    # Stop the container
    if lxc-stop --name "${lxcName}"; then
        print_success "✓ Container stopped: ${lxcName}"
    else
        print_error "✗ Failed to stop container: ${lxcName}"
    fi
    sleep 1

    # Stop the systemd service
    if systemctl --user stop "lxc-bg-start@${lxcName}.service" 2>/dev/null; then
        print_success "✓ Service stopped: lxc-bg-start@${lxcName}.service"
    else
        print_warning "⚠ Service may not be running: lxc-bg-start@${lxcName}.service"
    fi
    sleep 1
done

echo ""
lxc-ls --fancy

echo ""
print_success "Container shutdown sequence completed"
