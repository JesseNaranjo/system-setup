#!/usr/bin/env bash
# configure-kube-editor.sh - Configure the KUBE_EDITOR environment variable
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils-k8s.sh
source "${SCRIPT_DIR}/utils-k8s.sh"

# ============================================================================
# Shell RC File Detection
# ============================================================================

# Detect the user's shell RC file
# Checks for ~/.bashrc first, then ~/.zshrc, falls back to ~/.bashrc
detect_shell_rc_file() {
    # When running under sudo, use the invoking user's home, not root's
    local user_home="$HOME"
    if [[ -n "${SUDO_USER:-}" ]]; then
        user_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    fi

    if [[ -f "${user_home}/.bashrc" ]]; then
        echo "${user_home}/.bashrc"
    elif [[ -f "${user_home}/.zshrc" ]]; then
        echo "${user_home}/.zshrc"
    else
        echo "${user_home}/.bashrc"
    fi
}

# ============================================================================
# Entry Point
# ============================================================================

main_configure_kube_editor() {
    detect_environment

    print_info "Configuring KUBE_EDITOR..."

    local rc_file
    rc_file="$(detect_shell_rc_file)"

    if config_exists "$rc_file" "export[[:space:]]+KUBE_EDITOR="; then
        print_success "KUBE_EDITOR already configured"
        return 0
    fi

    if ! command -v nano &>/dev/null; then
        print_warning "nano not found, skipping KUBE_EDITOR configuration"
        return 0
    fi

    add_export_if_needed "$rc_file" "KUBE_EDITOR" "nano" "KUBE_EDITOR environment variable"

    print_success "KUBE_EDITOR configuration complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_kube_editor "$@"
fi
