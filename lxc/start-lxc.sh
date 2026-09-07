#!/usr/bin/env bash

# start-lxc.sh - Start LXC containers
#
# Usage: ./start-lxc.sh [options] <container_name> [[container_name], ...]
#
# Options:
#   --attach          Attach to the container after starting (single container only)
#   --delegate        Persist cgroup delegation in a systemd drop-in for the
#                     container's service, then start normally. Survives restarts.
#   --delegate-once   Start with cgroup delegation via systemd-run instead of
#                     the service. One-time only, does not persist.
#   --no-swap         Persist MemorySwapMax=0 drop-in and mask /proc/swaps in
#                     container config. Survives restarts.
#   --no-swap-once    Start with one-time MemorySwapMax=0 (cgroup only, does
#                     not mask /proc/swaps).
#   --k8s             Apply all Kubernetes container settings at once:
#                     cgroup delegation + swap restriction + /proc/sys writability
#                     + AppArmor unconfined. Equivalent to --delegate --no-swap,
#                     plus proc:rw and AppArmor.
#
# If a container name contains 'k8s', the script checks whether cgroup
# delegation, swap restriction, and /proc/sys writability are configured
# and warns if not.
#
# When run as root (e.g., via sudo), the script operates on privileged
# (system-scope) containers at /var/lib/lxc. Otherwise, it operates on
# unprivileged (user-scope) containers at ~/.local/share/lxc.
#
# This script starts one or more LXC containers using systemd services.
# Use --attach to enter the container shell after startup (single container only).
#
# Examples:
#   ./start-lxc.sh mycontainer                    # Start one container
#   ./start-lxc.sh mycontainer --attach           # Start and attach
#   ./start-lxc.sh web db cache                   # Start multiple containers
#   ./start-lxc.sh --delegate tst-k8s1            # Persist delegation, then start
#   ./start-lxc.sh --delegate-once tst-k8s1       # One-time delegation, no persist
#   ./start-lxc.sh --no-swap tst-k8s1             # Persist swap restriction + mask
#   ./start-lxc.sh --delegate --no-swap tst-k8s1  # Full k8s setup (granular)
#   sudo ./start-lxc.sh --k8s tst-k8s1            # Full k8s setup (privileged)
#   ./start-lxc.sh --k8s tst-k8s1                 # Full k8s setup (unprivileged)

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=utils-lxc.sh
source "${SCRIPT_DIR}/utils-lxc.sh"

readonly DELEGATE_CONTROLLERS="cpuset cpu io memory pids"

# ============================================================================
# Cgroup Delegation
# ============================================================================

# Check if a container's service has cgroup delegation configured
# Args: container_name
# Returns: 0 if delegation is configured, 1 otherwise
has_delegation() {
    local name="$1"
    local service="${SERVICE_PREFIX}@${name}.service"
    local controllers
    controllers="$("${SYSTEMCTL_CMD[@]}" show "$service" \
        -p DelegateControllers --value 2>/dev/null)"

    # cpuset explicitly listed in delegated controllers
    [[ "$controllers" == *cpuset* ]] && return 0
    # Empty controller list: check if all controllers
    # are delegated (Delegate=yes with no filter)
    [[ -z "$controllers" ]] && \
        [[ "$("${SYSTEMCTL_CMD[@]}" show "$service" \
            -p Delegate --value 2>/dev/null)" == "yes" ]] \
        && return 0
    return 1
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
readonly PROC_RW_MOUNT_AUTO="lxc.mount.auto = cgroup:mixed proc:rw sys:rw"

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
# /proc/sys Writability
# ============================================================================

# Check if a container's LXC config has proc:rw mount mode
# Args: container_name
# Returns: 0 if proc:rw is configured, 1 otherwise
has_proc_rw() {
    local name="$1"
    local config="${LXC_PATH}/${name}/config"

    [[ -f "$config" ]] && grep -qE '^lxc\.mount\.auto\s*=.*\bproc:rw\b' "$config"
}

# Add lxc.mount.auto with proc:rw to the container's LXC config
# Overrides proc:mixed from common.conf so kubelet can write to /proc/sys
# Args: container_name
install_proc_rw() {
    local name="$1"
    local config="${LXC_PATH}/${name}/config"

    if [[ ! -f "$config" ]]; then
        print_warning "⚠ Container config not found: ${config}"
        return 1
    fi

    if has_proc_rw "$name"; then
        print_info "/proc/sys already writable for ${name}"
        return 0
    fi

    {
        echo ""
        echo "# Mount /proc and /sys read-write — required for kubelet"
        echo "$PROC_RW_MOUNT_AUTO"
    } >> "$config"
    print_success "✓ /proc/sys set to read-write for ${name}"
}

# Warn if a k8s container is missing proc:rw
# Args: container_name
check_k8s_proc_rw() {
    local name="$1"

    [[ "$name" != *k8s* ]] && return
    has_proc_rw "$name" && return

    print_warning "⚠ Container '${name}' looks like a Kubernetes node but /proc/sys is not writable"
    print_warning "⚠ Kubelet requires writable /proc/sys. Use --k8s"
}

# ============================================================================
# AppArmor Profile
# ============================================================================

# Check if a container's AppArmor profile is set to unconfined
# Args: container_name
# Returns: 0 if unconfined, 1 otherwise
has_apparmor_unconfined() {
    local name="$1"
    local config="${LXC_PATH}/${name}/config"

    [[ -f "$config" ]] && grep -qE '^lxc\.apparmor\.profile\s*=\s*unconfined' "$config"
}

# Set AppArmor profile to unconfined in the container's LXC config
# The default 'generated' profile blocks /proc/sys writes even with proc:rw
# Appending overrides earlier values (LXC uses last-occurrence-wins)
# Args: container_name
install_apparmor_unconfined() {
    local name="$1"
    local config="${LXC_PATH}/${name}/config"

    if [[ ! -f "$config" ]]; then
        print_warning "⚠ Container config not found: ${config}"
        return 1
    fi

    if has_apparmor_unconfined "$name"; then
        print_info "AppArmor already unconfined for ${name}"
        return 0
    fi

    {
        echo ""
        echo "# Disable AppArmor confinement — required for kubelet to write /proc/sys tunables"
        echo "lxc.apparmor.profile = unconfined"
    } >> "$config"
    print_success "✓ AppArmor set to unconfined for ${name}"
}

# Warn if a k8s container has a restricting AppArmor profile
# Args: container_name
check_k8s_apparmor() {
    local name="$1"

    [[ "$name" != *k8s* ]] && return
    has_apparmor_unconfined "$name" && return

    print_warning "⚠ Container '${name}' looks like a Kubernetes node but AppArmor is not unconfined"
    print_warning "⚠ Kubelet requires unconfined AppArmor to write /proc/sys. Use --k8s"
}

# ============================================================================
# Input Validation
# ============================================================================

usage() {
    echo "Usage: ${0##*/} [--k8s] [--delegate|--delegate-once] [--no-swap|--no-swap-once] [--attach] <container_name> [...]"
    echo ""
    echo "Run as root (sudo) for privileged containers, or as a regular user for unprivileged."
    echo ""
    echo "Options:"
    echo "  --attach          Attach to the container shell after starting (single container only)"
    echo "  --k8s             Apply all Kubernetes settings: --delegate + --no-swap + proc:rw + AppArmor"
    echo "  --delegate        Persist cgroup delegation in service drop-in"
    echo "  --delegate-once   Start with one-time cgroup delegation (no persist)"
    echo "  --no-swap         Persist MemorySwapMax=0 drop-in and mask /proc/swaps in container config"
    echo "  --no-swap-once    Start with one-time MemorySwapMax=0 (cgroup only, does not mask /proc/swaps)"
    echo ""
    echo "--k8s is equivalent to --delegate --no-swap plus /proc/sys writability."
    echo "Individual flags can override --k8s regardless of order: --k8s --delegate-once (or"
    echo "--delegate-once --k8s) uses one-time delegation for the current start."
    echo ""
    echo "Examples:"
    echo "  ${0##*/} mycontainer"
    echo "  ${0##*/} mycontainer --attach"
    echo "  sudo ${0##*/} --k8s tst-k8s1"
    echo "  ${0##*/} --delegate --no-swap tst-k8s1"
    echo "  ${0##*/} --no-swap-once tst-k8s1"
}

main() {
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    # Parse options
    DELEGATE_MODE=""
    SWAP_MODE=""
    PROC_RW=false
    CONTAINERS=()
    ATTACH=false

    for arg in "$@"; do
        case "$arg" in
            --k8s)
                [[ -z "$DELEGATE_MODE" ]] && DELEGATE_MODE="persist"
                [[ -z "$SWAP_MODE" ]] && SWAP_MODE="persist"
                PROC_RW=true
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
            --attach)
                ATTACH=true
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
    # Root = privileged (system-scope), non-root = unprivileged (user-scope)
    if [[ $EUID == 0 ]]; then
        PRIVILEGED=true
        LXC_PATH="/var/lib/lxc"
        SERVICE_PREFIX="lxc-priv-bg-start"
        SYSTEMCTL_CMD=(systemctl)
        SYSTEMD_RUN_CMD=(systemd-run --scope)
        ATTACH_CMD="lxc-attach"
        DROPIN_BASE="/etc/systemd/system"
    else
        PRIVILEGED=false
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

    if [[ "$ATTACH" == true && ${#CONTAINERS[@]} -gt 1 ]]; then
        print_error "✖ --attach can only be used with a single container"
        echo ""
        usage
        exit 64
    fi

    # Pre-flight: verify the systemd service template exists (not needed for systemd-run path)
    if [[ "$DELEGATE_MODE" != "once" && "$SWAP_MODE" != "once" ]]; then
        SERVICE_TEMPLATE="${DROPIN_BASE}/${SERVICE_PREFIX}@.service"
        if [[ ! -f "$SERVICE_TEMPLATE" ]]; then
            print_error "✖ Systemd service template not found: ${SERVICE_TEMPLATE}"
            if [[ "$PRIVILEGED" == true ]]; then
                print_error "  Run 'sudo setup-lxc.sh --privileged' to install it."
            else
                print_error "  Run 'sudo setup-lxc.sh $USER' to install it."
            fi
            exit 69  # EX_UNAVAILABLE — required service template not installed
        fi
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

        if [[ "$PROC_RW" == true ]]; then
            install_proc_rw "$lxcName" \
                || print_warning "⚠ Failed to set proc:rw for ${lxcName}; configure manually"
            install_apparmor_unconfined "$lxcName" \
                || print_warning "⚠ Failed to set AppArmor unconfined for ${lxcName}; configure manually"
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
            if [[ "$PROC_RW" != true ]]; then
                check_k8s_proc_rw "$lxcName"
                check_k8s_apparmor "$lxcName"
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

    if [[ "$ATTACH" == true ]]; then
        lxcName="${CONTAINERS[0]}"

        if [[ "$any_failed" == true ]]; then
            lxc-ls --fancy
            echo ""
            exit 1
        fi

        print_info "Attaching in:"
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
        lxc-ls --fancy
        echo ""
        if [[ "$any_failed" == true ]]; then
            print_warning "⚠ Some containers failed to start (see errors above)"
            exit 1
        else
            print_success "✓ All containers started successfully"
        fi
    fi
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
