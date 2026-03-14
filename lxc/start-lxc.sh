#!/usr/bin/env bash

# start-lxc.sh - Start LXC containers
#
# Usage: ./start-lxc.sh [options] <container_name> [[container_name], ...]
#
# Options:
#   --delegate        Persist cgroup delegation in a systemd drop-in for the
#                     container's service, then start normally. Survives restarts.
#   --delegate-once   Start with cgroup delegation via systemd-run instead of
#                     the service. One-time only, does not persist.
#
# If a container name contains 'k8s', the script checks whether cgroup
# delegation is configured and warns if it is not (Kubernetes requires the
# cpuset controller).
#
# This script starts one or more LXC containers using systemd user services.
# If only one container is specified, it will automatically attach to the
# container after startup with a 3-second countdown.
#
# Examples:
#   ./start-lxc.sh mycontainer              # Start and attach to one container
#   ./start-lxc.sh web db cache             # Start multiple containers
#   ./start-lxc.sh --delegate tst-k8s1      # Persist delegation, then start
#   ./start-lxc.sh --delegate-once tst-k8s1 # One-time delegation, no persist

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

readonly DELEGATE_CONTROLLERS="cpuset cpu io memory pids"

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
# Cgroup Delegation
# ============================================================================

# Check if a container's service has cgroup delegation configured
# Args: container_name
# Returns: 0 if delegation is configured, 1 otherwise
has_delegation() {
    local name="$1"
    local service="lxc-bg-start@${name}.service"

    systemctl --user show "$service" -p Delegate 2>/dev/null | grep -q "cpuset"
}

# Create a systemd drop-in to persist cgroup delegation for a container
# Args: container_name
install_delegation_dropin() {
    local name="$1"
    local dropin_dir
    dropin_dir="${HOME}/.config/systemd/user/lxc-bg-start@${name}.service.d"

    mkdir -p "$dropin_dir"
    cat > "${dropin_dir}/delegate.conf" <<EOF
[Service]
Delegate=${DELEGATE_CONTROLLERS}
EOF

    systemctl --user daemon-reload
    print_success "Cgroup delegation persisted for ${name}"
}

# Start a container with one-time cgroup delegation via systemd-run
# Args: container_name
# Returns: 0 on success, 1 on failure
start_with_delegation() {
    local name="$1"

    if systemd-run --user --scope -p "Delegate=${DELEGATE_CONTROLLERS}" -- \
        lxc-start -n "$name"; then
        return 0
    else
        return 1
    fi
}

# Warn if a k8s container is missing cgroup delegation
# Args: container_name
check_k8s_delegation() {
    local name="$1"

    if [[ "$name" != *k8s* ]]; then
        return
    fi

    if has_delegation "$name"; then
        return
    fi

    print_warning "Container '${name}' looks like a Kubernetes node but has no cgroup delegation"
    print_warning "Kubernetes requires the cpuset controller. Use --delegate or --delegate-once"
}

# ============================================================================
# Input Validation
# ============================================================================

usage() {
    echo "Usage: ${0##*/} [--delegate|--delegate-once] <container_name> [...]"
    echo ""
    echo "Options:"
    echo "  --delegate        Persist cgroup delegation in service drop-in"
    echo "  --delegate-once   Start with one-time cgroup delegation (no persist)"
    echo ""
    echo "Examples:"
    echo "  ${0##*/} mycontainer"
    echo "  ${0##*/} --delegate tst-k8s1"
    echo "  ${0##*/} --delegate-once tst-k8s1"
}

# Parse options
DELEGATE_MODE=""
CONTAINERS=()

for arg in "$@"; do
    case "$arg" in
        --delegate)
            DELEGATE_MODE="persist"
            ;;
        --delegate-once)
            DELEGATE_MODE="once"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            print_error "Unknown option: $arg"
            usage
            exit 64
            ;;
        *)
            CONTAINERS+=("$arg")
            ;;
    esac
done

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    print_error "Missing required container name argument"
    echo ""
    usage
    exit 64  # 64 - EX_USAGE (sysexits.h)
fi

# ============================================================================
# Main Script
# ============================================================================

print_info "Starting ${#CONTAINERS[@]} container(s)..."
echo ""

for lxcName in "${CONTAINERS[@]}"; do
    # Check if container is already running
    if lxc-info -n "${lxcName}" -s 2>/dev/null | grep -q "RUNNING"; then
        print_success "⊙ Container ${lxcName} is already running..."
        continue
    fi

    # Handle delegation modes
    case "$DELEGATE_MODE" in
        persist)
            if ! has_delegation "$lxcName"; then
                install_delegation_dropin "$lxcName"
            else
                print_info "Cgroup delegation already configured for ${lxcName}"
            fi
            # Start via service (now has delegation)
            print_info "Starting ${lxcName}..."
            if systemctl --user start "lxc-bg-start@${lxcName}.service"; then
                print_success "✓ Service and Container started: ${lxcName}"
            else
                print_error "✖ Failed to start service/container: ${lxcName}"
            fi
            ;;
        once)
            print_info "Starting ${lxcName} with one-time cgroup delegation..."
            if start_with_delegation "$lxcName"; then
                print_success "✓ Container started with delegation: ${lxcName}"
            else
                print_error "✖ Failed to start container: ${lxcName}"
            fi
            ;;
        *)
            # Default: check k8s containers for missing delegation
            check_k8s_delegation "$lxcName"

            print_info "Starting ${lxcName}..."
            if systemctl --user start "lxc-bg-start@${lxcName}.service"; then
                print_success "✓ Service and Container started: ${lxcName}"
            else
                print_error "✖ Failed to start service/container: ${lxcName}"
            fi
            ;;
    esac
    sleep 0.5
done
echo ""

# If only one container specified, attach to it
if [[ ${#CONTAINERS[@]} -eq 1 ]]; then
    lxcName="${CONTAINERS[0]}"

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
