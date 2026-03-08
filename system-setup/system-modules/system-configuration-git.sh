#!/usr/bin/env bash

# system-configuration-git.sh - Git configuration
# Part of the system-setup suite
#
# This script configures git with sensible defaults using git config commands.
# Supports both user scope (--global) and system scope (--system).

set -euo pipefail

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source utilities
# shellcheck source=../utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Git Configuration
# ============================================================================

# Git config settings: key|value|description
readonly GIT_CONFIG_SETTINGS=(
    "init.defaultBranch|development|default branch name"
    "fetch.prune|true|auto-prune stale remote branches on fetch"
    "branch.sort|-committerdate|sort branches by most recent commit"
    "push.autoSetupRemote|true|auto-track remote branch on first push"
    "column.ui|auto|column layout for branch/tag output"
    "tag.sort|-version:refname|sort tags by version number"
    "diff.colorMoved|zebra|highlight moved code blocks in diffs"
    "diff.algorithm|histogram|improved diff algorithm"
    "merge.conflictstyle|diff3|show base text in merge conflicts"
    "help.autocorrect|prompt|prompt for autocorrected commands"
)

# Get the git config file path for the given scope
get_git_config_file() {
    local scope="$1"  # "user" or "system"

    if [[ "$scope" == "system" ]]; then
        if [[ "$DETECTED_OS" == "macos" ]]; then
            echo "/opt/homebrew/etc/gitconfig"
        else
            echo "/etc/gitconfig"
        fi
    else
        echo "$HOME/.gitconfig"
    fi
}

# Configure git with sensible defaults
configure_git() {
    local scope="$1"  # "user" or "system"

    print_info "Configuring git..."

    # Backup gitconfig file if it exists
    local config_file
    config_file=$(get_git_config_file "$scope")
    if [[ -f "$config_file" ]]; then
        backup_file "$config_file"
    fi

    # Apply settings from data-driven list
    for entry in "${GIT_CONFIG_SETTINGS[@]}"; do
        IFS='|' read -r key value description <<< "$entry"
        add_git_config_if_needed "$scope" "$key" "$value" "$description"
    done

    # Set nano as default editor if available
    if command -v nano &>/dev/null; then
        add_git_config_if_needed "$scope" "core.editor" "nano" "default editor (nano)"
    fi

    # Initialize Git LFS if available
    if command -v git-lfs &>/dev/null; then
        local git_scope_flag
        if [[ "$scope" == "system" ]]; then
            git_scope_flag="--system"
        else
            git_scope_flag="--global"
        fi

        local lfs_filter
        lfs_filter=$(git config "$git_scope_flag" --get filter.lfs.process 2>/dev/null || echo "")
        if [[ -n "$lfs_filter" ]]; then
            print_success "- Git LFS already initialized"
        else
            print_info "+ Initializing Git LFS"
            if [[ "$scope" == "system" ]]; then
                run_elevated git lfs install --system
            else
                git lfs install
            fi
        fi
    fi

    print_success "Git configuration completed for $config_file"
}

# ============================================================================
# Main Execution
# ============================================================================

main_configure_git() {
    local scope="${1:-}"

    # Validate scope parameter is provided
    if [[ -z "$scope" ]]; then
        print_error "Scope parameter is required"
        print_info "Usage: $0 <user|system>"
        print_info "  user   - Configure for current user only (~/.gitconfig)"
        print_info "  system - Configure system-wide for all users (/etc/gitconfig)"
        return 1
    fi

    # Validate scope value
    if [[ "$scope" != "user" && "$scope" != "system" ]]; then
        print_error "Invalid scope: $scope"
        print_info "Usage: $0 <user|system>"
        return 1
    fi

    detect_environment

    # Check if git is available
    if ! command -v git &>/dev/null; then
        print_warning "Git is not installed, skipping git configuration"
        return 0
    fi

    configure_git "$scope"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_git "$@"
fi
