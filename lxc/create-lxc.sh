#!/usr/bin/env bash

# create-lxc.sh - Create an LXC container (with optional destroy/recreate)
#
# Usage: ./create-lxc.sh [--privileged] <container_name> [distribution] [release] [architecture]
#
# This script creates an LXC container. If a container with the same name
# already exists, it prompts for confirmation before stopping, destroying,
# and recreating it. Optional parameters (distribution, release, architecture)
# will be auto-detected from the host system if not provided. If auto-detection
# fails, the lxc-create download template will prompt interactively.
#
# Options:
#   --privileged  Create a privileged container (requires root)
#
# Examples:
#   ./create-lxc.sh mycontainer
#   ./create-lxc.sh mycontainer debian bookworm amd64
#   ./create-lxc.sh --privileged mycontainer

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=utils-lxc.sh
source "${SCRIPT_DIR}/utils-lxc.sh"

# ============================================================================
# Input Validation
# ============================================================================

show_usage() {
    echo "Usage: ${0##*/} [--privileged] <container_name> [distribution] [release] [architecture]"
    echo ""
    echo "Arguments:"
    echo "  container_name  - Name of container to refresh (required)"
    echo "  distribution    - Linux distribution (optional, auto-detected if omitted)"
    echo "  release         - Distribution release (optional, auto-detected if omitted)"
    echo "  architecture    - System architecture (optional, auto-detected if omitted)"
    echo ""
    echo "Options:"
    echo "  --privileged    - Create a privileged container (requires root)"
    echo ""
    echo "Examples:"
    echo "  ${0##*/} mycontainer"
    echo "  ${0##*/} mycontainer debian bookworm amd64"
    echo "  ${0##*/} --privileged mycontainer"
    echo ""
    echo "If a container with the same name already exists, you will be"
    echo "prompted for confirmation before it is destroyed and recreated."
}

# ============================================================================
# Main Script
# ============================================================================

main() {
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    local PRIVILEGED=false
    local CONTAINER_NAME=""
    local DISTRIBUTION=""
    local RELEASE=""
    local ARCHITECTURE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --privileged)
                PRIVILEGED=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            -*)
                print_error "✖ Unknown option: $1"
                show_usage
                exit 64  # EX_USAGE
                ;;
            *)
                if [[ -z "$CONTAINER_NAME" ]]; then
                    CONTAINER_NAME="$1"
                elif [[ -z "$DISTRIBUTION" ]]; then
                    DISTRIBUTION="$1"
                elif [[ -z "$RELEASE" ]]; then
                    RELEASE="$1"
                elif [[ -z "$ARCHITECTURE" ]]; then
                    ARCHITECTURE="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$CONTAINER_NAME" ]]; then
        print_error "✖ Missing required container name argument"
        echo ""
        show_usage
        exit 64  # EX_USAGE
    fi

    # Privileged mode requires root
    if [[ "$PRIVILEGED" == true && $EUID != 0 ]]; then
        print_error "✖ --privileged requires root."
        exit 1
    fi

    # Detect distribution if not specified
    if [[ -z "$DISTRIBUTION" ]]; then
        if [[ -f /etc/os-release ]]; then
            # Extract distribution ID from os-release
            DISTRIBUTION=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
            print_info "Detected distribution: $DISTRIBUTION"
        else
            print_warning "⚠ Could not detect distribution — download template will prompt"
        fi
    fi

    # Detect release if not specified
    if [[ -z "$RELEASE" ]]; then
        if [[ -f /etc/os-release ]]; then
            # Extract version codename or version ID from os-release
            RELEASE=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
            if [[ -z "$RELEASE" ]]; then
                RELEASE=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
            fi
            if [[ -n "$RELEASE" ]]; then
                print_info "Detected release: $RELEASE"
            else
                print_warning "⚠ Could not detect release — download template will prompt"
            fi
        else
            print_warning "⚠ Could not detect release — download template will prompt"
        fi
    fi

    # Detect architecture if not specified
    if [[ -z "$ARCHITECTURE" ]]; then
        ARCHITECTURE=$(uname -m)
        # Convert common architecture names to LXC format
        case "$ARCHITECTURE" in
            x86_64)
                ARCHITECTURE="amd64"
                ;;
            aarch64)
                ARCHITECTURE="arm64"
                ;;
            armv7l)
                ARCHITECTURE="armhf"
                ;;
        esac
        print_info "Detected architecture: $ARCHITECTURE"
    fi

    echo ""
    print_info "Refreshing container: $CONTAINER_NAME"
    echo "            Distribution: ${DISTRIBUTION:-<will prompt>}"
    echo "            Release: ${RELEASE:-<will prompt>}"
    echo "            Architecture: ${ARCHITECTURE:-<will prompt>}"
    [[ "$PRIVILEGED" == true ]] && echo "            Mode: privileged"
    echo ""

    # Check if container already exists
    local CONTAINER_EXISTS=false
    if lxc-info -n "${CONTAINER_NAME}" &>/dev/null; then
        CONTAINER_EXISTS=true
        print_warning "⚠ Container '${CONTAINER_NAME}' already exists!"
        echo ""
        if ! prompt_yes_no "            Do you want to destroy and recreate it?" "n"; then
            print_info "Operation cancelled by user"
            exit 75  # 75 - EX_TEMPFAIL (sysexits.h) - user chose to abort
        fi
        echo ""
    fi

    # Set total steps and initialize counter
    local TOTAL_STEPS
    if [[ "$CONTAINER_EXISTS" == true ]]; then
        TOTAL_STEPS=4
    else
        TOTAL_STEPS=2
    fi
    local CURRENT_STEP=0

    # Stop and destroy only if container exists
    if [[ "$CONTAINER_EXISTS" == true ]]; then
        # Step: Stop the container
        ((CURRENT_STEP++)) || true
        print_info "Step ${CURRENT_STEP}/${TOTAL_STEPS}: Stopping container..."
        local PRIV_FLAG=()
        [[ "$PRIVILEGED" == true ]] && PRIV_FLAG=(--privileged)
        if [[ -f "$SCRIPT_DIR/stop-lxc.sh" ]]; then
            "$SCRIPT_DIR/stop-lxc.sh" ${PRIV_FLAG[@]+"${PRIV_FLAG[@]}"} "$CONTAINER_NAME"
        else
            print_warning "⚠ stop-lxc.sh not found, attempting to stop manually..."
            lxc-stop --name "$CONTAINER_NAME" || true
            if [[ "$PRIVILEGED" == true ]]; then
                systemctl stop "lxc-priv-bg-start@${CONTAINER_NAME}.service" 2>/dev/null || true
            else
                systemctl --user stop "lxc-bg-start@${CONTAINER_NAME}.service" 2>/dev/null || true
            fi
        fi
        echo ""

        # Step: Destroy the container
        ((CURRENT_STEP++)) || true
        print_info "Step ${CURRENT_STEP}/${TOTAL_STEPS}: Destroying container..."
        if lxc-destroy --name "$CONTAINER_NAME" --quiet; then
            print_success "✓ Container destroyed: $CONTAINER_NAME"
        else
            print_error "✖ Failed to destroy container: $CONTAINER_NAME"
            exit 1
        fi
        echo ""
    fi

    # Step: Create the container with specified parameters
    ((CURRENT_STEP++)) || true
    print_info "Step ${CURRENT_STEP}/${TOTAL_STEPS}: Creating container with:"
    echo "            Distribution: ${DISTRIBUTION:-<will prompt>}"
    echo "            Release: ${RELEASE:-<will prompt>}"
    echo "            Architecture: ${ARCHITECTURE:-<will prompt>}"
    local CREATE_FLAGS=()
    [[ -n "$DISTRIBUTION" ]] && CREATE_FLAGS+=(-d "$DISTRIBUTION")
    [[ -n "$RELEASE" ]] && CREATE_FLAGS+=(-r "$RELEASE")
    [[ -n "$ARCHITECTURE" ]] && CREATE_FLAGS+=(-a "$ARCHITECTURE")
    local START_FLAGS=()
    if lxc-create --name "$CONTAINER_NAME" -t download -- ${CREATE_FLAGS[@]+"${CREATE_FLAGS[@]}"}; then
        print_success "✓ Container created: $CONTAINER_NAME"

        # Offer Kubernetes container settings
        [[ "$PRIVILEGED" == true ]] && START_FLAGS+=(--privileged)
        if [[ "$CONTAINER_NAME" == *k8s* ]]; then
            echo ""
            print_info "This container name suggests Kubernetes usage."
            print_info "Kubernetes requires cgroup delegation, swap restriction, and writable /proc/sys."
            if prompt_yes_no "Apply Kubernetes container settings (--k8s)?" "y"; then
                START_FLAGS+=(--k8s)
            fi
        fi
    else
        print_error "✖ Failed to create container: $CONTAINER_NAME"
        exit 1
    fi
    echo ""

    # Step: Start the container
    ((CURRENT_STEP++)) || true
    print_info "Step ${CURRENT_STEP}/${TOTAL_STEPS}: Starting container..."
    if [[ -f "$SCRIPT_DIR/start-lxc.sh" ]]; then
        "$SCRIPT_DIR/start-lxc.sh" --attach ${START_FLAGS[@]+"${START_FLAGS[@]}"} "$CONTAINER_NAME"
    else
        if [[ ${#START_FLAGS[@]} -gt 0 ]]; then
            print_warning "⚠ start-lxc.sh not found — cannot apply ${START_FLAGS[*]}; configure manually"
        fi
        print_warning "⚠ start-lxc.sh not found, attempting to start manually..."
        if [[ "$PRIVILEGED" == true ]]; then
            if systemctl start "lxc-priv-bg-start@${CONTAINER_NAME}.service"; then
                print_success "✓ Service and Container started: ${CONTAINER_NAME}"
                echo ""
                lxc-ls --fancy
                echo ""
                print_info "Attaching to ${CONTAINER_NAME} as root (use 'exit' or Ctrl+D to detach)..."
                echo ""
                lxc-attach --name "$CONTAINER_NAME" --set-var HOME=/root -- /bin/bash -l
            else
                print_error "✖ Failed to start container: ${CONTAINER_NAME}"
                exit 1
            fi
        else
            if systemctl --user start "lxc-bg-start@${CONTAINER_NAME}.service"; then
                print_success "✓ Service and Container started: ${CONTAINER_NAME}"
                echo ""
                lxc-ls --fancy
                echo ""
                print_info "Attaching to ${CONTAINER_NAME} as root (use 'exit' or Ctrl+D to detach)..."
                echo ""
                lxc-unpriv-attach --name "$CONTAINER_NAME" --set-var HOME=/root -- /bin/bash -l
            else
                print_error "✖ Failed to start container: ${CONTAINER_NAME}"
                exit 1
            fi
        fi
    fi

    echo ""
    print_success "Container $CONTAINER_NAME has been successfully created!"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
