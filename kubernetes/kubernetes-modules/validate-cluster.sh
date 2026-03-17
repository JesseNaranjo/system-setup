#!/usr/bin/env bash
# validate-cluster.sh - Validate Kubernetes cluster health
# Runs a series of checks (node readiness, system pods, services) and reports results
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# ============================================================================
# Validation Checks
# ============================================================================

# Check that all nodes report Ready status
# Args: passed_ref total_ref (nameref variables for tracking counts)
check_node_readiness() {
    local -n _passed=$1
    local -n _total=$2
    ((_total++)) || true

    local node_output
    if ! node_output="$(kubectl get nodes --no-headers 2>/dev/null)"; then
        print_warning "⚠ Node readiness: unable to query nodes"
        return 0
    fi

    if [[ -z "$node_output" ]]; then
        print_warning "⚠ Node readiness: no nodes found"
        return 0
    fi

    local not_ready
    not_ready="$(echo "$node_output" | grep -cv '\bReady\b' || true)"

    if [[ "$not_ready" -eq 0 ]]; then
        print_success "✓ Node readiness: all nodes are Ready"
        ((_passed++)) || true
    else
        print_warning "⚠ Node readiness: $not_ready node(s) not Ready"
    fi
}

# Check that all kube-system pods are Running
# Args: passed_ref total_ref (nameref variables for tracking counts)
check_system_pods() {
    local -n _passed=$1
    local -n _total=$2
    ((_total++)) || true

    local pod_output
    if ! pod_output="$(kubectl get pods -n kube-system --no-headers 2>/dev/null)"; then
        print_warning "⚠ System pods: unable to query kube-system pods"
        return 0
    fi

    if [[ -z "$pod_output" ]]; then
        print_warning "⚠ System pods: no pods found in kube-system"
        return 0
    fi

    local not_running
    not_running="$(echo "$pod_output" | grep -cv '\bRunning\b' || true)"

    if [[ "$not_running" -eq 0 ]]; then
        print_success "✓ System pods: all kube-system pods are Running"
        ((_passed++)) || true
    else
        print_warning "⚠ System pods: $not_running pod(s) not Running"
    fi
}

# Check that the kubelet service is active
# Args: passed_ref total_ref (nameref variables for tracking counts)
check_kubelet_service() {
    local -n _passed=$1
    local -n _total=$2
    ((_total++)) || true

    if systemctl is-active kubelet &>/dev/null; then
        print_success "✓ Kubelet service: active"
        ((_passed++)) || true
    else
        print_warning "⚠ Kubelet service: not active"
    fi
}

# Check that the CRI-O service is active
# Args: passed_ref total_ref (nameref variables for tracking counts)
check_crio_service() {
    local -n _passed=$1
    local -n _total=$2
    ((_total++)) || true

    if systemctl is-active crio &>/dev/null; then
        print_success "✓ CRI-O service: active"
        ((_passed++)) || true
    else
        print_warning "⚠ CRI-O service: not active"
    fi
}

# ============================================================================
# Entry Point
# ============================================================================

main_validate_cluster() {
    detect_environment || { print_error "✖ Failed to detect environment"; return 1; }

    print_info "Validating cluster health..."

    # Guard: skip if cluster is not initialized
    if ! kubectl cluster-info &>/dev/null; then
        print_info "Cluster is not initialized - skipping validation"
        return 0
    fi

    local passed=0
    local total=0

    check_node_readiness passed total
    check_system_pods passed total
    check_kubelet_service passed total
    check_crio_service passed total

    print_info "${passed}/${total} checks passed"

    [[ "$passed" -eq "$total" ]] && return 0 || return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_validate_cluster "$@"
fi
