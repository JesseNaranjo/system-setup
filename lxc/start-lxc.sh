#!/usr/bin/env bash

# start-lxc.sh - Start LXC containers
#
# Usage: ./start-lxc.sh <container_name> [[container_name], ...]
#
# This script starts one or more LXC containers using systemd user services.
# If only one container is specified, it will automatically attach to the
# container after startup with a 3-second countdown.
#
# The script uses systemd user services (lxc-bg-start@.service) to manage
# containers, ensuring proper lifecycle management and integration with systemd.
#
# Examples:
#   ./start-lxc.sh mycontainer          # Start and attach to one container
#   ./start-lxc.sh web db cache         # Start multiple containers

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
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
# Input Validation
# ============================================================================

if [[ $# -eq 0 || -z ${1-} ]]; then
    print_error "Missing required container name argument"
    echo ""
    echo "Usage: ${0##*/} <container_name> [[container_name], ...]"
    echo ""
    echo "Arguments:"
    echo "  container_name  - Name of container(s) to start"
    echo ""
    echo "Examples:"
    echo "  ${0##*/} mycontainer"
    echo "  ${0##*/} web db cache"
    exit 64  # 64 - EX_USAGE (sysexits.h)
fi

# ============================================================================
# Main Script
# ============================================================================

print_info "Starting ${#@} container(s)..."
echo ""

for lxcName in "$@"; do
    # Check if container is already running
    if lxc-info -n "${lxcName}" -s 2>/dev/null | grep -q "RUNNING"; then
        print_success "⊙ Container ${lxcName} is already running..."
        continue
    fi

    print_info "Starting ${lxcName}..."
    # lxc-unpriv-start --name "${lxcName}"
    if systemctl --user start "lxc-bg-start@${lxcName}.service"; then
        print_success "✓ Service and Container started: ${lxcName}"
    else
        print_error "✖ Failed to start service/container: ${lxcName}"
    fi
    sleep 0.5
done
echo ""

# If only one container specified, attach to it
if [[ $# -eq 1 ]]; then
    lxcName=$1

    print_info "Container started. Attaching in:"
    x=3
    while [ $x -gt 0 ]; do
        echo "            $x..."
        sleep 0.75
        x=$((x - 1))
    done
    echo ""

    lxc-ls --fancy
    echo ""

    # lxc-unpriv-attach reuses the calling environment in the container:
    # - All env variables are passed through, so by default the container thinks
    #   that it's running as the user that attached into the LXC
    # - Even though inside the container you may be root, the env variables are
    #   not setup correctly (for example, check $HOME without the --set-var argument)
    print_info "Attaching to ${lxcName} as root (use 'exit' or Ctrl+D to detach)..."
    echo ""
    lxc-unpriv-attach --name "${lxcName}" --set-var HOME=/root -- /bin/bash -l
else
    # Multiple containers, just show status
    lxc-ls --fancy
    echo ""
    print_success "All containers started successfully"
fi
