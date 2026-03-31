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

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

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

# Prompt user for yes/no confirmation
# Usage: prompt_yes_no "message" [default]
#   default: "y" or "n" (optional, defaults to "n")
# Returns: 0 for yes, 1 for no
prompt_yes_no() {
    local prompt_message="$1"
    local default="${2:-n}"
    local prompt_suffix
    local user_reply

    if [[ "${default,,}" == "y" ]]; then
        prompt_suffix="(Y/n)"
    else
        prompt_suffix="(y/N)"
    fi

    read -p "$prompt_message $prompt_suffix: " -r user_reply </dev/tty

    if [[ -z "$user_reply" ]]; then
        [[ "${default,,}" == "y" ]]
    else
        [[ $user_reply =~ ^[Yy]$ ]]
    fi
}

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

PRIVILEGED=false
CONTAINER_NAME=""
DISTRIBUTION=""
RELEASE=""
ARCHITECTURE=""

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

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if container already exists
CONTAINER_EXISTS=false
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
if [[ "$CONTAINER_EXISTS" == true ]]; then
    TOTAL_STEPS=4
else
    TOTAL_STEPS=2
fi
CURRENT_STEP=0

# Stop and destroy only if container exists
if [[ "$CONTAINER_EXISTS" == true ]]; then
    # Step: Stop the container
    ((CURRENT_STEP++)) || true
    print_info "Step ${CURRENT_STEP}/${TOTAL_STEPS}: Stopping container..."
    PRIV_FLAG=()
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
CREATE_FLAGS=()
[[ -n "$DISTRIBUTION" ]] && CREATE_FLAGS+=(-d "$DISTRIBUTION")
[[ -n "$RELEASE" ]] && CREATE_FLAGS+=(-r "$RELEASE")
[[ -n "$ARCHITECTURE" ]] && CREATE_FLAGS+=(-a "$ARCHITECTURE")
if lxc-create --name "$CONTAINER_NAME" -t download -- ${CREATE_FLAGS[@]+"${CREATE_FLAGS[@]}"}; then
    print_success "✓ Container created: $CONTAINER_NAME"

    # Offer Kubernetes container settings
    START_FLAGS=()
    [[ "$PRIVILEGED" == true ]] && START_FLAGS+=(--privileged)
    if [[ "$CONTAINER_NAME" == *k8s* ]]; then
        echo ""
        print_info "This container name suggests Kubernetes usage."
        print_info "Kubernetes requires cgroup delegation (cpuset) and /proc/swaps masked."
        if prompt_yes_no "Apply Kubernetes container settings (--delegate --no-swap)?" "y"; then
            START_FLAGS+=(--delegate --no-swap)
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
    "$SCRIPT_DIR/start-lxc.sh" ${START_FLAGS[@]+"${START_FLAGS[@]}"} "$CONTAINER_NAME"
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
