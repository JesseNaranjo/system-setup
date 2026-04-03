#!/usr/bin/env bash
# initialize-cluster.sh - Initialize or join a Kubernetes cluster
# Handles kubeadm init for control-plane nodes, kubeadm join for workers,
# and cluster reset/reinit for existing clusters
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# ============================================================================
# Cluster Status
# ============================================================================

# Check if the cluster is already initialized on this node
# Returns: 0 if admin.conf exists AND kubectl can reach the cluster
is_cluster_initialized() {
    [[ -f /etc/kubernetes/admin.conf ]] && kubectl cluster-info &>/dev/null
}

# ============================================================================
# Cluster Reset
# ============================================================================

# Reset an existing cluster so it can be reinitialized
# WARNING: This is destructive and removes all cluster state
reset_cluster() {
    print_warning "⚠ This will destroy the existing cluster on this node."
    kubeadm reset --force || { print_error "✖ Failed to reset cluster"; return 1; }

    # Clean up kubeconfig for the actual user (not root when using sudo)
    local user_home="$HOME"
    if [[ -n "${SUDO_USER:-}" ]]; then
        user_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    fi
    rm -f "${user_home}/.kube/config"

    print_success "✓ Cluster has been reset"
}

# ============================================================================
# Container Preflight Checks
# ============================================================================

# Verify kernel config is accessible for kubeadm's SystemVerification preflight
# kubeadm checks these paths in order; if none exist, it tries modprobe configs
# which always fails on Debian (CONFIG_IKCONFIG not built as module)
# Returns: 0 if found, 1 if missing
ensure_kernel_config() {
    local release
    release="$(uname -r)"

    local -a config_paths=(
        "/proc/config.gz"
        "/boot/config-${release}"
        "/usr/src/linux-${release}/.config"
        "/usr/src/linux/.config"
        "/usr/lib/modules/${release}/config"
        "/usr/lib/modules/${release}/build/.config"
    )

    local path
    for path in "${config_paths[@]}"; do
        [[ -f "$path" ]] && return 0
    done

    print_warning "⚠ Kernel config not found — kubeadm preflight will fail"
    print_info "Debian does not provide the 'configs' kernel module"
    print_info "In containers, /boot/config-${release} is typically missing"
    echo ""
    print_info "To fix, run one of these on the HOST (not inside this container):"
    print_info "  cp /boot/config-${release} ~/.local/share/lxc/<container>/rootfs/boot/"
    print_info "  (create /boot/ inside rootfs first if it doesn't exist: mkdir -p ...rootfs/boot)"
    echo ""
    print_info "Then re-run this script."
    return 1
}

# Ensure /dev/kmsg exists in the container
# kubelet's OOM watcher requires /dev/kmsg; LXC containers lack it by default
ensure_dev_kmsg() {
    if [[ -e /dev/kmsg ]]; then
        print_success "- /dev/kmsg already exists"
        return 0
    fi

    ln -s /dev/console /dev/kmsg
    print_success "✓ Created /dev/kmsg symlink to /dev/console"
}

# Verify /proc/sys is writable for kubelet (privileged containers only)
# In unprivileged containers, KubeletInUserNamespace handles read-only /proc/sys.
# In privileged containers (no user namespace), kubelet must write kernel tunables.
# Checks two failure modes:
#   EROFS  — /proc/sys mounted read-only (LXC proc:mixed default)
#   EACCES — AppArmor 'generated' profile blocks /proc/sys writes
# Returns: 0 if writable or unprivileged, 1 if not writable
ensure_proc_sys_writable() {
    # Determine container type from uid_map (canonical runc/moby method)
    # Init namespace signature is exactly "0 0 4294967295"; anything else = user namespace
    local uid_map_line
    uid_map_line="$(head -1 /proc/self/uid_map 2>/dev/null)" || return 0

    local inside_uid outside_uid count
    read -r inside_uid outside_uid count <<< "$uid_map_line"

    if [[ "$inside_uid" != "0" || "$outside_uid" != "0" || "$count" != "4294967295" ]]; then
        print_success "- Unprivileged container (KubeletInUserNamespace handles /proc/sys)"
        return 0
    fi

    # Privileged container: check if /proc/sys is on a read-only mount (EROFS)
    if awk '$2 == "/proc/sys" && $4 ~ /(^|,)ro(,|$)/' /proc/mounts 2>/dev/null | grep -q .; then
        print_error "✖ /proc/sys is read-only — kubelet will fail to start"
        echo ""
        print_info "Kubelet needs to write kernel tunables (vm.overcommit_memory, kernel.panic, etc.)"
        print_info "KubeletInUserNamespace does not apply (this is not a user namespace container)"
        echo ""
        print_info "Fix: on the HOST, stop this container and restart with:"
        print_info "  sudo ./start-lxc.sh --privileged --k8s <container_name>"
        print_info "  (container name may differ from hostname '$(hostname)')"
        echo ""
        print_info "Or manually add to the container's LXC config:"
        print_info "  lxc.mount.auto = cgroup:mixed proc:rw sys:rw"
        return 1
    fi

    # Mount is rw — verify writes aren't blocked by AppArmor (EACCES)
    # Write the current value back (no-op) to test actual write permission
    local test_val
    test_val="$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)" || { print_success "- /proc/sys is writable"; return 0; }
    if ! printf '%s' "$test_val" > /proc/sys/vm/overcommit_memory 2>/dev/null; then
        print_error "✖ /proc/sys write blocked (likely AppArmor) — kubelet will fail to start"
        echo ""
        print_info "The mount is read-write but writes are denied (permission denied)."
        print_info "This typically means AppArmor's 'generated' profile is restricting /proc/sys access."
        echo ""
        print_info "Fix: on the HOST, stop this container and restart with:"
        print_info "  sudo ./start-lxc.sh --privileged --k8s <container_name>"
        print_info "  (container name may differ from hostname '$(hostname)')"
        echo ""
        print_info "Or manually add to the container's LXC config:"
        print_info "  lxc.apparmor.profile = unconfined"
        return 1
    fi

    print_success "- /proc/sys is writable"
}

# Generate kubeadm config file for cluster initialization
# Args: pod_cidr, config_path
# When running in a container, includes KubeletConfiguration with:
#   failSwapOn: false — /proc/swaps reflects host swap, cannot be disabled from inside
#   KubeletInUserNamespace: true — tolerates read-only /proc/sys and missing /dev/kmsg
generate_kubeadm_config() {
    local pod_cidr="$1"
    local config_path="$2"

    mkdir -p "$(dirname "$config_path")"

    cat > "$config_path" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: ${pod_cidr}
EOF

    # In containers, /proc/swaps reflects the host's swap (via LXCFS or kernel).
    # swapoff fails (no CAP_SYS_ADMIN) and bind-mounting /dev/null is overridden by LXCFS.
    # Tell kubelet to ignore swap state.
    if [[ "${RUNNING_IN_CONTAINER:-false}" == true ]]; then
        cat >> "$config_path" <<'EOF'
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failSwapOn: false
featureGates:
  KubeletInUserNamespace: true
EOF
        print_info "Container detected — kubeadm config includes failSwapOn: false, KubeletInUserNamespace: true"
    fi

    print_success "✓ Generated kubeadm config at ${config_path}"
}

# ============================================================================
# Shared Preflight (control-plane and worker)
# ============================================================================

# Run kubeadm preflight checks common to both init and join
# Ensures modprobe is available and container-specific requirements are met
run_kubeadm_preflight() {
    # kubeadm preflight loads the "configs" kernel module via modprobe
    # kmod is installed as part of the role package set; this catches standalone execution
    if ! command -v modprobe &>/dev/null; then
        print_error "✖ modprobe not found (install kmod: apt install kmod)"
        return 1
    fi

    # In containers, verify kernel config, /dev/kmsg, and /proc/sys writability
    if [[ "${RUNNING_IN_CONTAINER:-false}" == true ]]; then
        ensure_kernel_config || return 1
        ensure_dev_kmsg || return 1
        ensure_proc_sys_writable || return 1
    fi
}

# ============================================================================
# Control-Plane Initialization
# ============================================================================

# Initialize a new control-plane node with kubeadm
initialize_control_plane() {
    run_kubeadm_preflight || return 1

    local pod_cidr
    read -r -p "Enter pod network CIDR [192.168.0.0/16]: " pod_cidr </dev/tty
    pod_cidr="${pod_cidr:-192.168.0.0/16}"

    # Validate CIDR format before embedding in kubeadm config YAML
    if [[ ! "$pod_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        print_error "✖ Invalid CIDR format: ${pod_cidr}"
        print_info "Expected format: x.x.x.x/y (e.g., 192.168.0.0/16)"
        return 1
    fi

    local config_path="/etc/kubernetes/kubeadm-config.yaml"
    generate_kubeadm_config "$pod_cidr" "$config_path"

    print_info "Initializing control-plane with pod network CIDR: ${pod_cidr}..."
    kubeadm init --config="$config_path" \
        || { print_error "✖ Failed to initialize control plane"; return 1; }

    # When running under sudo, configure kubectl for the invoking user, not root
    local user_home="$HOME"
    local user_id
    user_id="$(id -u):$(id -g)"
    if [[ -n "${SUDO_USER:-}" ]]; then
        user_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
        user_id="$(id -u "${SUDO_USER}"):$(id -g "${SUDO_USER}")"
    fi

    print_info "Configuring kubectl access for ${SUDO_USER:-$(whoami)}..."
    mkdir -p "${user_home}/.kube" \
        || { print_error "✖ Failed to create .kube directory"; return 1; }
    cp /etc/kubernetes/admin.conf "${user_home}/.kube/config" \
        || { print_error "✖ Failed to copy kubeconfig"; return 1; }
    chown "${user_id}" "${user_home}/.kube/config" \
        || { print_error "✖ Failed to set kubeconfig ownership"; return 1; }
    print_success "✓ kubectl configured at ${user_home}/.kube/config"

    echo ""
    print_info "Join command for worker nodes:"
    kubeadm token create --print-join-command \
        || { print_error "✖ Failed to generate join command"; return 1; }
    echo ""

    print_warning "⚠ Next steps: install a CNI plugin (e.g., Calico, Flannel, Cilium)"
}

# ============================================================================
# Worker Join
# ============================================================================

# Join this node to an existing cluster as a worker
join_as_worker() {
    run_kubeadm_preflight || return 1

    local join_cmd
    read -r -p "Enter the full 'kubeadm join' command: " join_cmd </dev/tty

    if [[ -z "$join_cmd" ]]; then
        print_error "✖ No join command provided"
        return 1
    fi

    # Validate the command starts with 'kubeadm join'
    if [[ ! "$join_cmd" =~ ^kubeadm[[:space:]]+join[[:space:]] ]]; then
        print_error "✖ Input must be a 'kubeadm join' command"
        return 1
    fi

    print_info "Joining cluster as worker node..."
    # Word-splitting is intentional here - kubeadm join arguments are simple tokens
    # shellcheck disable=SC2086
    $join_cmd || { print_error "✖ Failed to join cluster"; return 1; }
    print_success "✓ Successfully joined the cluster"
}

# ============================================================================
# Cluster Init/Join Flow
# ============================================================================

# Handle cluster initialization when cluster is already running
handle_existing_cluster() {
    print_success "- Cluster is already initialized"
    kubectl cluster-info

    if prompt_yes_no "Print join command for worker nodes?" "n"; then
        kubeadm token create --print-join-command \
            || print_warning "⚠ Failed to generate join command"
    fi

    if prompt_yes_no "Reset and reinitialize cluster?" "n"; then
        reset_cluster || return 1
        initialize_control_plane
    fi
}

# Handle cluster initialization when no cluster is present
handle_new_cluster() {
    print_info "No existing cluster detected on this node."
    echo ""
    echo "  1) Initialize as control-plane node"
    echo "  2) Join as worker node"
    echo "  3) Skip"
    echo ""

    local choice
    read -r -p "Select an option [1-3]: " choice </dev/tty

    case "${choice}" in
        1)
            initialize_control_plane
            ;;
        2)
            join_as_worker
            ;;
        3)
            print_info "Skipping cluster initialization"
            return 0
            ;;
        *)
            print_error "✖ Invalid option: ${choice}"
            return 1
            ;;
    esac
}

# ============================================================================
# Entry Point
# ============================================================================

main_initialize_cluster() {
    detect_environment || { print_error "✖ Failed to detect environment"; return 1; }

    print_info "Cluster initialization..."

    if is_cluster_initialized; then
        handle_existing_cluster || return 1
    else
        handle_new_cluster || return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_initialize_cluster "$@"
fi
