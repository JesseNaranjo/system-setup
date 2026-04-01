#!/usr/bin/env bash

# start-lxc.sh - Start LXC containers
#
# Usage: ./start-lxc.sh [options] <container_name> [[container_name], ...]
#
# Options:
#   --privileged      Operate on system-scope (privileged) containers.
#                     Requires root. Uses /var/lib/lxc and system services.
#   --delegate        Persist cgroup delegation in a systemd drop-in for the
#                     container's service, then start normally. Survives restarts.
#   --delegate-once   Start with cgroup delegation via systemd-run instead of
#                     the service. One-time only, does not persist.
#   --no-swap         Persist MemorySwapMax=0 drop-in and mask /proc/swaps in
#                     container config. Survives restarts.
#   --no-swap-once    Start with one-time MemorySwapMax=0 (cgroup only, does
#                     not mask /proc/swaps).
#
# If a container name contains 'k8s', the script checks whether cgroup
# delegation and swap restriction are configured and warns if not.
#
# This script starts one or more LXC containers using systemd user services
# (or system services with --privileged). If only one container is specified,
# it will automatically attach to the container after startup with a 3-second
# countdown.
#
# Examples:
#   ./start-lxc.sh mycontainer              # Start and attach to one container
#   ./start-lxc.sh web db cache             # Start multiple containers
#   ./start-lxc.sh --delegate tst-k8s1      # Persist delegation, then start
#   ./start-lxc.sh --delegate-once tst-k8s1 # One-time delegation, no persist
#   ./start-lxc.sh --no-swap tst-k8s1       # Persist swap restriction + mask
#   ./start-lxc.sh --delegate --no-swap tst-k8s1  # Full k8s setup
#   ./start-lxc.sh --privileged tst-k8s1    # Start a privileged container

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
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
    local service="${SERVICE_PREFIX}@${name}.service"

    "${SYSTEMCTL_CMD[@]}" show "$service" -p Delegate 2>/dev/null | grep -qP "^Delegate=.*cpuset.*"
}

# Check if the user session has all required cgroup controllers available
# Warns if system-level delegation is missing (non-fatal)
# Returns: 0 always (warning only)
check_session_controllers() {
    # System-scope services have full cgroup access; session check is user-only
    if [[ "$PRIVILEGED" == true ]]; then
        return 0
    fi

    local cgroup_file="/sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers"

    [[ -f "$cgroup_file" ]] || return 0

    local available
    available="$(<"$cgroup_file")"
    local missing=()
    for controller in $DELEGATE_CONTROLLERS; do
        if [[ " $available " != *" $controller "* ]]; then
            missing+=("$controller")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_warning "⚠ Session cgroup is missing controllers: ${missing[*]}"
        print_warning "⚠ Run setup-lxc.sh to configure system-level delegation, or reboot if recently configured"
    fi
}

# Create a systemd drop-in to persist cgroup delegation for a container
# Args: container_name
install_delegation_dropin() {
    local name="$1"
    local dropin_dir
    dropin_dir="${DROPIN_BASE}/${SERVICE_PREFIX}@${name}.service.d"

    mkdir -p "$dropin_dir"
    cat > "${dropin_dir}/delegate.conf" <<EOF
[Service]
Delegate=${DELEGATE_CONTROLLERS}
EOF

    "${SYSTEMCTL_CMD[@]}" daemon-reload
    print_success "✓ Cgroup delegation persisted for ${name}"
}

# Warn if a k8s container is missing cgroup delegation
# Args: container_name
check_k8s_delegation() {
    local name="$1"

    if [[ "$name" != *k8s* ]]; then
        return
    fi

    check_session_controllers || true

    if has_delegation "$name"; then
        return
    fi

    print_warning "⚠ Container '${name}' looks like a Kubernetes node but has no cgroup delegation"
    print_warning "⚠ Kubernetes requires the cpuset controller. Use --delegate or --delegate-once"
}

# ============================================================================
# Swap Restriction
# ============================================================================

readonly SWAP_MOUNT_ENTRY="lxc.mount.entry = /dev/null proc/swaps none bind,optional 0 0"

# Check if a container's service has swap restricted via cgroup
# Args: container_name
# Returns: 0 if MemorySwapMax is 0, 1 otherwise
has_no_swap() {
    local name="$1"
    local service="${SERVICE_PREFIX}@${name}.service"

    local swap_max
    swap_max="$("${SYSTEMCTL_CMD[@]}" show "$service" -p MemorySwapMax --value 2>/dev/null)"
    [[ "$swap_max" == "0" ]]
}

# Check if a container's LXC config masks /proc/swaps
# Args: container_name
# Returns: 0 if masked, 1 otherwise
has_swap_masked() {
    local name="$1"
    local config="${LXC_PATH}/${name}/config"

    [[ -f "$config" ]] && grep -q 'lxc\.mount\.entry.*proc/swaps' "$config"
}

# Create a systemd drop-in to persist MemorySwapMax=0 for a container
# Args: container_name
install_no_swap_dropin() {
    local name="$1"
    local dropin_dir
    dropin_dir="${DROPIN_BASE}/${SERVICE_PREFIX}@${name}.service.d"

    mkdir -p "$dropin_dir"
    cat > "${dropin_dir}/no-swap.conf" <<EOF
[Service]
MemorySwapMax=0
EOF

    "${SYSTEMCTL_CMD[@]}" daemon-reload
    print_success "✓ Swap restriction persisted for ${name} (MemorySwapMax=0)"
}

# Add lxc.mount.entry to mask /proc/swaps inside the container
# Args: container_name
mask_proc_swaps() {
    local name="$1"
    local config="${LXC_PATH}/${name}/config"

    if [[ ! -f "$config" ]]; then
        print_warning "⚠ Container config not found: ${config}"
        return 1
    fi

    if has_swap_masked "$name"; then
        print_info "/proc/swaps already masked for ${name}"
        return 0
    fi

    {
        echo ""
        echo "# Mask /proc/swaps — prevents kubelet from seeing host swap devices"
        echo "$SWAP_MOUNT_ENTRY"
    } >> "$config"
    print_success "✓ /proc/swaps masked for ${name}"
}

# Warn if a k8s container is missing swap restriction
# Args: container_name
check_k8s_no_swap() {
    local name="$1"

    if [[ "$name" != *k8s* ]]; then
        return
    fi

    if has_no_swap "$name" && has_swap_masked "$name"; then
        return
    fi

    print_warning "⚠ Container '${name}' looks like a Kubernetes node but has incomplete swap restriction"
    print_warning "⚠ Kubernetes requires swap off. Use --no-swap to enforce cgroup limits and mask /proc/swaps"
}

# ============================================================================
# Input Validation
# ============================================================================

usage() {
    echo "Usage: ${0##*/} [--privileged] [--delegate|--delegate-once] [--no-swap|--no-swap-once] <container_name> [...]"
    echo ""
    echo "Options:"
    echo "  --privileged      Operate on system-scope (privileged) containers (requires root)"
    echo "  --delegate        Persist cgroup delegation in service drop-in"
    echo "  --delegate-once   Start with one-time cgroup delegation (no persist)"
    echo "  --no-swap         Persist MemorySwapMax=0 drop-in and mask /proc/swaps in container config"
    echo "  --no-swap-once    Start with one-time MemorySwapMax=0 (cgroup only, does not mask /proc/swaps)"
    echo ""
    echo "Options are combinable: --delegate --no-swap applies both."
    echo ""
    echo "Examples:"
    echo "  ${0##*/} mycontainer"
    echo "  ${0##*/} --delegate --no-swap tst-k8s1"
    echo "  ${0##*/} --no-swap-once tst-k8s1"
    echo "  ${0##*/} --privileged tst-k8s1"
}

# Parse options
DELEGATE_MODE=""
SWAP_MODE=""
PRIVILEGED=false
CONTAINERS=()

for arg in "$@"; do
    case "$arg" in
        --privileged)
            PRIVILEGED=true
            ;;
        --delegate)
            DELEGATE_MODE="persist"
            ;;
        --delegate-once)
            DELEGATE_MODE="once"
            ;;
        --no-swap)
            SWAP_MODE="persist"
            ;;
        --no-swap-once)
            SWAP_MODE="once"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            print_error "✖ Unknown option: $arg"
            usage
            exit 64
            ;;
        *)
            CONTAINERS+=("$arg")
            ;;
    esac
done

# Derived globals — set once after parsing, used by all helper functions
if [[ "$PRIVILEGED" == true ]]; then
    [[ $EUID != 0 ]] && { print_error "✖ --privileged requires root."; exit 1; }
    LXC_PATH="/var/lib/lxc"
    SERVICE_PREFIX="lxc-priv-bg-start"
    SYSTEMCTL_CMD=(systemctl)
    SYSTEMD_RUN_CMD=(systemd-run --scope)
    ATTACH_CMD="lxc-attach"
    DROPIN_BASE="/etc/systemd/system"
else
    LXC_PATH="${HOME}/.local/share/lxc"
    SERVICE_PREFIX="lxc-bg-start"
    SYSTEMCTL_CMD=(systemctl --user)
    SYSTEMD_RUN_CMD=(systemd-run --user --scope)
    ATTACH_CMD="lxc-unpriv-attach"
    DROPIN_BASE="${HOME}/.config/systemd/user"
fi

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    print_error "✖ Missing required container name argument"
    echo ""
    usage
    exit 64  # 64 - EX_USAGE (sysexits.h)
fi

# ============================================================================
# Main Script
# ============================================================================

print_info "Starting ${#CONTAINERS[@]} container(s)..."
echo ""

any_failed=false
for lxcName in "${CONTAINERS[@]}"; do
    # Install persistent settings BEFORE the running check — they apply on next restart
    if [[ "$DELEGATE_MODE" == "persist" ]]; then
        check_session_controllers || true
        if ! has_delegation "$lxcName"; then
            install_delegation_dropin "$lxcName"
        else
            print_info "Cgroup delegation already configured for ${lxcName}"
        fi
    fi

    if [[ "$SWAP_MODE" == "persist" ]]; then
        if ! has_no_swap "$lxcName"; then
            install_no_swap_dropin "$lxcName"
        else
            print_info "Swap cgroup restriction already configured for ${lxcName}"
        fi
        mask_proc_swaps "$lxcName" \
            || print_warning "⚠ Failed to mask /proc/swaps for ${lxcName}; configure manually"
    fi

    # Skip start if already running (persistent settings above still applied)
    if lxc-info -n "${lxcName}" -s 2>/dev/null | grep -q "RUNNING"; then
        print_success "⊙ Container ${lxcName} is already running (settings applied for next restart)"
        continue
    fi

    # Start the container
    if [[ "$DELEGATE_MODE" == "once" || "$SWAP_MODE" == "once" ]]; then
        # systemd-run bypasses the service, so include ALL desired properties
        # (both persisted and one-time) for this start
        [[ "$DELEGATE_MODE" == "once" ]] && { check_session_controllers || true; }
        run_props=()
        [[ -n "$DELEGATE_MODE" ]] && run_props+=(-p "Delegate=${DELEGATE_CONTROLLERS}")
        [[ -n "$SWAP_MODE" ]] && run_props+=(-p "MemorySwapMax=0")

        print_info "Starting ${lxcName} with one-time properties: ${run_props[*]}..."
        if "${SYSTEMD_RUN_CMD[@]}" "${run_props[@]}" -- lxc-start -n "$lxcName"; then
            print_success "✓ Container started: ${lxcName}"
        else
            print_error "✖ Failed to start container: ${lxcName}"
            any_failed=true
        fi
    else
        # No one-time flags: start via service (drop-ins apply automatically)
        # Warn about missing settings on k8s containers only when no explicit flags
        if [[ -z "$DELEGATE_MODE" ]]; then
            check_k8s_delegation "$lxcName"
        fi
        if [[ -z "$SWAP_MODE" ]]; then
            check_k8s_no_swap "$lxcName"
        fi

        print_info "Starting ${lxcName}..."
        if "${SYSTEMCTL_CMD[@]}" start "${SERVICE_PREFIX}@${lxcName}.service"; then
            print_success "✓ Service and Container started: ${lxcName}"
        else
            print_error "✖ Failed to start service/container: ${lxcName}"
            any_failed=true
        fi
    fi
done
echo ""

# If only one container specified, attach to it
if [[ ${#CONTAINERS[@]} -eq 1 ]]; then
    lxcName="${CONTAINERS[0]}"

    print_info "Container started. Attaching in:"
    x=3
    while [[ $x -gt 0 ]]; do
        echo "            $x..."
        sleep 0.75
        x=$((x - 1))
    done
    echo ""

    lxc-ls --fancy
    echo ""

    # lxc-attach / lxc-unpriv-attach reuse the calling environment in the container:
    # - All env variables are passed through, so by default the container thinks
    #   that it's running as the user that attached into the LXC
    # - Even though inside the container you may be root, the env variables are
    #   not setup correctly (for example, check $HOME without the --set-var argument)
    print_info "Attaching to ${lxcName} as root (use 'exit' or Ctrl+D to detach)..."
    echo ""
    "$ATTACH_CMD" --name "${lxcName}" --set-var HOME=/root -- /bin/bash -l
else
    # Multiple containers, just show status
    lxc-ls --fancy
    echo ""
    if [[ "$any_failed" == true ]]; then
        print_warning "⚠ Some containers failed to start (see errors above)"
    else
        print_success "✓ All containers started successfully"
    fi
fi
