#!/usr/bin/env bash

# refresh-lxc.sh - Destroy and recreate an LXC container
#
# Usage: ./refresh-lxc.sh <container_name> [distribution] [release] [architecture]
#
# This script stops, destroys, recreates, and starts an LXC container.
# Optional parameters (distribution, release, architecture) will be auto-detected
# from the host system if not provided.
#
# Examples:
#   ./refresh-lxc.sh mycontainer
#   ./refresh-lxc.sh mycontainer debian bookworm amd64

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
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

# ============================================================================
# Input Validation
# ============================================================================

if [[ $# -eq 0 || -z ${1-} ]]; then
    print_error "Missing required container name argument"
    echo ""
    echo "Usage: ${0##*/} <container_name> [distribution] [release] [architecture]"
    echo ""
    echo "Arguments:"
    echo "  container_name  - Name of container to refresh (required)"
    echo "  distribution    - Linux distribution (optional, auto-detected if omitted)"
    echo "  release         - Distribution release (optional, auto-detected if omitted)"
    echo "  architecture    - System architecture (optional, auto-detected if omitted)"
    echo ""
    echo "Examples:"
    echo "  ${0##*/} mycontainer"
    echo "  ${0##*/} mycontainer debian bookworm amd64"
    exit 64  # 64 - EX_USAGE (sysexits.h)
fi

# ============================================================================
# Main Script
# ============================================================================

CONTAINER_NAME="$1"
DISTRIBUTION="${2:-}"
RELEASE="${3:-}"
ARCHITECTURE="${4:-}"

# Detect distribution if not specified
if [[ -z "$DISTRIBUTION" ]]; then
    if [[ -f /etc/os-release ]]; then
        # Extract distribution ID from os-release
        DISTRIBUTION=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        print_info "Detected distribution: $DISTRIBUTION"
    else
        print_error "Could not detect distribution. Please specify it manually."
        exit 1
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
        print_info "Detected release: $RELEASE"
    else
        print_error "Could not detect release. Please specify it manually."
        exit 1
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
echo "            Distribution: $DISTRIBUTION"
echo "            Release: $RELEASE"
echo "            Architecture: $ARCHITECTURE"
echo ""

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Step 1: Stop the container
print_info "Step 1/4: Stopping container..."
if [[ -f "$SCRIPT_DIR/stop-lxc.sh" ]]; then
    "$SCRIPT_DIR/stop-lxc.sh" "$CONTAINER_NAME"
else
    print_warning "stop-lxc.sh not found, attempting to stop manually..."
    lxc-stop --name "$CONTAINER_NAME" || true
    systemctl --user stop "lxc-bg-start@${CONTAINER_NAME}.service" 2>/dev/null || true
fi
echo ""

# Step 2: Destroy the container
print_info "Step 2/4: Destroying container..."
if lxc-destroy --name "$CONTAINER_NAME" --quiet; then
    print_success "✓ Container destroyed: $CONTAINER_NAME"
else
    print_error "✖ Failed to destroy container: $CONTAINER_NAME"
    echo "            (maybe it doesn't exist?)"
fi
echo ""

# Step 3: Create the container with specified parameters
print_info "Step 3/4: Creating container with:"
echo "            Distribution: $DISTRIBUTION"
echo "            Release: $RELEASE"
echo "            Architecture: $ARCHITECTURE"
if lxc-create --name "$CONTAINER_NAME" -t download -- -d "$DISTRIBUTION" -r "$RELEASE" -a "$ARCHITECTURE"; then
    print_success "✓ Container created: $CONTAINER_NAME"
else
    print_error "✖ Failed to create container: $CONTAINER_NAME"
    exit 1
fi
echo ""

# Step 4: Start the container
print_info "Step 4/4: Starting container..."
if [[ -f "$SCRIPT_DIR/start-lxc.sh" ]]; then
    "$SCRIPT_DIR/start-lxc.sh" "$CONTAINER_NAME"
else
    print_warning "start-lxc.sh not found, attempting to start manually..."
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

echo ""
print_success "Container $CONTAINER_NAME has been successfully refreshed!"
