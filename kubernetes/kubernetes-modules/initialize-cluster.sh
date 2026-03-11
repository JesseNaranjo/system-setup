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
    print_warning "This will destroy the existing cluster on this node."
    kubeadm reset --force

    # Clean up kubeconfig for the actual user (not root when using sudo)
    local user_home="$HOME"
    if [[ -n "${SUDO_USER:-}" ]]; then
        user_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    fi
    rm -rf "${user_home}/.kube/config"

    print_success "Cluster has been reset"
}

# ============================================================================
# Control-Plane Initialization
# ============================================================================

# Initialize a new control-plane node with kubeadm
initialize_control_plane() {
    local pod_cidr
    read -r -p "Enter pod network CIDR [192.168.0.0/16]: " pod_cidr </dev/tty
    pod_cidr="${pod_cidr:-192.168.0.0/16}"

    print_info "Initializing control-plane with pod network CIDR: ${pod_cidr}..."
    kubeadm init --pod-network-cidr="${pod_cidr}"

    # When running under sudo, configure kubectl for the invoking user, not root
    local user_home="$HOME"
    local user_id
    user_id="$(id -u):$(id -g)"
    if [[ -n "${SUDO_USER:-}" ]]; then
        user_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
        user_id="$(id -u "${SUDO_USER}"):$(id -g "${SUDO_USER}")"
    fi

    print_info "Configuring kubectl access for ${SUDO_USER:-$(whoami)}..."
    mkdir -p "${user_home}/.kube"
    cp /etc/kubernetes/admin.conf "${user_home}/.kube/config"
    chown "${user_id}" "${user_home}/.kube/config"
    print_success "kubectl configured at ${user_home}/.kube/config"

    echo ""
    print_info "Join command for worker nodes:"
    kubeadm token create --print-join-command
    echo ""

    print_warning "Next steps: install a CNI plugin (e.g., Calico, Flannel, Cilium)"
}

# ============================================================================
# Worker Join
# ============================================================================

# Join this node to an existing cluster as a worker
join_as_worker() {
    local join_cmd
    read -r -p "Enter the full 'kubeadm join' command: " join_cmd </dev/tty

    if [[ -z "$join_cmd" ]]; then
        print_error "No join command provided"
        return 1
    fi

    # Validate the command starts with 'kubeadm join'
    if [[ ! "$join_cmd" =~ ^kubeadm[[:space:]]+join[[:space:]] ]]; then
        print_error "Input must be a 'kubeadm join' command"
        return 1
    fi

    print_info "Joining cluster as worker node..."
    # Word-splitting is intentional here - kubeadm join arguments are simple tokens
    # shellcheck disable=SC2086
    $join_cmd
    print_success "Successfully joined the cluster"
}

# ============================================================================
# Cluster Init/Join Flow
# ============================================================================

# Handle cluster initialization when cluster is already running
handle_existing_cluster() {
    print_success "Cluster is already initialized"
    kubectl cluster-info

    if prompt_yes_no "Print join command for worker nodes?" "n"; then
        kubeadm token create --print-join-command
    fi

    if prompt_yes_no "Reset and reinitialize cluster?" "n"; then
        reset_cluster
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
            print_error "Invalid option: ${choice}"
            return 1
            ;;
    esac
}

# ============================================================================
# Entry Point
# ============================================================================

main_initialize_cluster() {
    detect_environment

    print_info "Cluster initialization..."

    if is_cluster_initialized; then
        handle_existing_cluster
    else
        handle_new_cluster
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_initialize_cluster "$@"
fi
