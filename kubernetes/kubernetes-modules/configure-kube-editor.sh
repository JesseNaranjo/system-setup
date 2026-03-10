#!/usr/bin/env bash
# configure-kube-editor.sh - Configure the KUBE_EDITOR environment variable
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck source=../utils.sh
source "${SCRIPT_DIR}/utils.sh"

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
# Editor Detection
# ============================================================================

# Detect the best available editor
# Checks in order: nano, vim, vi
# Returns the full path of the first editor found
detect_editor() {
    local editors=(nano vim vi)

    for editor in "${editors[@]}"; do
        if command -v "$editor" &>/dev/null; then
            command -v "$editor"
            return 0
        fi
    done

    return 1
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

    local editor_path
    if ! editor_path="$(detect_editor)"; then
        print_warning "No suitable editor found (checked: nano, vim, vi)"
        return 1
    fi

    print_info "Detected editor: $editor_path"

    add_export_if_needed "$rc_file" "KUBE_EDITOR" "\"${editor_path}\"" "KUBE_EDITOR environment variable"

    print_success "KUBE_EDITOR configuration complete"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main_configure_kube_editor "$@"
