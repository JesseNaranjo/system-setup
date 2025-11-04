#!/usr/bin/env bash

# setup-lxc.sh - LXC unprivileged container setup for a specified user
#
# Usage: sudo ./setup-lxc.sh <username> [subuid_start:100000]
#
# This script configures unprivileged LXC containers for a specific user by:
# - Backing up /etc/lxc/default.conf
# - Adding veth interface permissions to /etc/lxc/lxc-usernet
# - Configuring subuid/subgid mappings in /etc/subuid and /etc/subgid
# - Enabling user namespaces (kernel.unprivileged_userns_clone)
# - Creating user's default LXC configuration (~/.config/lxc/default.conf)
# - Setting up systemd user service for LXC container auto-start
# - Enabling systemd lingering for the user
#
# The script automatically handles permission setting and configuration deployment.
# Existing configuration files are backed up before modification.

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Global variables
BACKED_UP_FILES=""

# Print colored output
print_info() {
    echo -e "${BLUE}[   INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[  ERROR]${NC} $1"
}

print_backup() {
    echo -e "${GRAY}[ BACKUP] $1${NC}"
}

# Backup file if it exists (only once per session)
backup_file() {
    local file="$1"

    # Check if already backed up in this session
    if [[ "$BACKED_UP_FILES" == *"$file"* ]]; then
        return 0
    fi

    if [[ -f "$file" ]]; then
        local backup
        backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"

        # Copy file with preserved permissions (-p flag)
        cp -p "$file" "$backup"

        # Preserve ownership (requires appropriate permissions)
        # Get the owner and group of the original file
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS stat syntax
            local owner
            owner=$(stat -f "%u:%g" "$file")
            chown "$owner" "$backup" 2>/dev/null || true
        else
            # Linux stat syntax
            local owner
            owner=$(stat -c "%u:%g" "$file")
            chown "$owner" "$backup" 2>/dev/null || true
        fi

        print_backup "- Backed up existing file: $file -> $backup"
        BACKED_UP_FILES="$BACKED_UP_FILES $file"
    fi
}

# ============================================================================
# Input Validation
# ============================================================================

if [[ $EUID != 0 ]]; then
    print_error "This script requires root privileges (e.g., using su or sudo)."
    exit 1
fi

if [[ $# -eq 0 || -z ${1-} ]]; then
    print_error "Missing required username argument"
    echo ""
    echo "Usage: ${0##*/} <username> [subuid_start]"
    echo ""
    echo "Arguments:"
    echo "  username      - Target user for LXC setup"
    echo "  subuid_start  - Starting subuid/subgid ID (default: 100000)"
    echo ""
    echo "Example:"
    echo "  sudo ${0##*/} myuser"
    echo "  sudo ${0##*/} myuser 200000"
    exit 64  # 64 - EX_USAGE (sysexits.h)
fi

LIMITED_USER=$1

if ! id -u "$LIMITED_USER" >/dev/null 2>&1; then
    print_error "User \"$LIMITED_USER\" does not exist on this system"
    exit 67  # 67 - EX_NOUSER
fi

ID_NO=${2:-100000}

print_info "Configuring LXC for user: $LIMITED_USER (subuid start: $ID_NO)"
echo ""

# ============================================================================
# System Configuration
# ============================================================================

# Backup /etc/lxc/default.conf
print_info "Backing up /etc/lxc/default.conf..."
backup_file "/etc/lxc/default.conf"
echo ""

# Configure veth interface permissions
VETH_ENTRY="$LIMITED_USER veth lxcbr0 10"

print_info "Configuring veth interface permissions..."
if grep -q "^$VETH_ENTRY" /etc/lxc/lxc-usernet 2>/dev/null; then
    print_info "✓ veth entry already exists in /etc/lxc/lxc-usernet"
else
    print_warning "Adding veth entry to /etc/lxc/lxc-usernet"
    echo "$VETH_ENTRY" | tee -a /etc/lxc/lxc-usernet > /dev/null
    print_success "- Added: $VETH_ENTRY"
fi
echo ""

# Configure subuid mappings
SUB_ENTRY="$LIMITED_USER:$ID_NO:65535"

print_info "Configuring subuid mappings..."
if grep -q "^$SUB_ENTRY" /etc/subuid 2>/dev/null; then
    print_info "✓ subuid entry already exists in /etc/subuid"
else
    print_warning "Adding subuid entry to /etc/subuid"
    echo "$SUB_ENTRY" | tee -a /etc/subuid > /dev/null
    print_success "- Added: $SUB_ENTRY"
fi
echo ""

# Configure subgid mappings
print_info "Configuring subgid mappings..."
if grep -q "^$SUB_ENTRY" /etc/subgid 2>/dev/null; then
    print_info "✓ subgid entry already exists in /etc/subgid"
else
    print_warning "Adding subgid entry to /etc/subgid"
    echo "$SUB_ENTRY" | tee -a /etc/subgid > /dev/null
    print_success "- Added: $SUB_ENTRY"
fi
echo ""

# Enable user namespaces
print_info "Verifying user namespace support..."
USER_NAMESPACE_ENABLED=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "0")

if [[ "$USER_NAMESPACE_ENABLED" -eq 1 ]]; then
    print_success "✓ User namespaces already enabled"
else
    print_warning "User namespaces not enabled, enabling permanently..."
    sysctl -w kernel.unprivileged_userns_clone=1
    echo "kernel.unprivileged_userns_clone = 1" | tee /etc/sysctl.d/99-lxc.conf > /dev/null
    sysctl --system > /dev/null 2>&1
    print_success "- Enabled user namespace support"
fi
echo ""

# ============================================================================
# User Configuration
# ============================================================================

LIMITED_USER_HOME="/home/$LIMITED_USER"
LIMITED_USER_CONFIG="$LIMITED_USER_HOME/.config"
LIMITED_USER_CONFIG_LXC="$LIMITED_USER_CONFIG/lxc"

print_info "Creating user's default LXC configuration..."
print_info "- Location: $LIMITED_USER_CONFIG_LXC/default.conf"

mkdir -p "$LIMITED_USER_CONFIG_LXC"

tee "$LIMITED_USER_CONFIG_LXC/default.conf" > /dev/null <<EOF
# ID Map must match range found in /etc/subuid and /etc/subgid for "$LIMITED_USER"
lxc.idmap = u 0 $ID_NO 65535
lxc.idmap = g 0 $ID_NO 65535

# AppArmor Profile "unconfined" is necessary for networking to work (as of 2025-06-21)
lxc.apparmor.profile = unconfined

lxc.net.0.name = eth0
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
EOF

print_success "- Created LXC default configuration"
echo ""

# Set permissions on user directories
print_info "Setting permissions on user directories..."

chmod +x "$LIMITED_USER_HOME" 2>/dev/null || true

if [[ -d "$LIMITED_USER_HOME/.local" ]]; then
    chmod +x "$LIMITED_USER_HOME/.local"
    if [[ -d "$LIMITED_USER_HOME/.local/share" ]]; then
        chmod +x "$LIMITED_USER_HOME/.local/share"
        if [[ -d "$LIMITED_USER_HOME/.local/share/lxc" ]]; then
            chmod +x "$LIMITED_USER_HOME/.local/share/lxc"
        fi
    fi
fi

chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG"
chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_LXC"
chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_LXC/default.conf"

print_success "- Permissions set correctly"
echo ""

# ============================================================================
# Systemd Configuration
# ============================================================================

LIMITED_USER_CONFIG_SYSTEMD="$LIMITED_USER_CONFIG/systemd"
LIMITED_USER_CONFIG_SYSTEMD_USER="$LIMITED_USER_CONFIG_SYSTEMD/user"

print_info "Creating systemd user service for LXC auto-start..."
print_info "- Location: $LIMITED_USER_CONFIG_SYSTEMD_USER/lxc-bg-start@.service"

mkdir -p "$LIMITED_USER_CONFIG_SYSTEMD_USER"

tee "$LIMITED_USER_CONFIG_SYSTEMD_USER/lxc-bg-start@.service" > /dev/null <<EOF
[Unit]
Description=LXC Container %i
After=network.target

[Service]
ExecStart=/usr/bin/lxc-start -n %i
ExecStop=/usr/bin/lxc-stop -n %i
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF

print_success "- Created systemd service template"
echo ""

# Enable systemd lingering
print_info "Enabling systemd lingering for user: $LIMITED_USER"
if loginctl enable-linger ${LIMITED_USER}; then
    print_success "- Systemd lingering enabled"
else
    print_warning "- Failed to enable systemd lingering (may need manual intervention)"
fi
echo ""

# Set ownership on systemd files
chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_SYSTEMD"
chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_SYSTEMD_USER"
chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_SYSTEMD_USER/lxc-bg-start@.service"

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "========================================================================"
print_success "LXC configuration completed successfully for user: $LIMITED_USER"
echo "========================================================================"
echo ""
echo "Configuration Summary:"
echo "  - User:              $LIMITED_USER"
echo "  - Subuid/Subgid:     $ID_NO-$((ID_NO + 65535))"
echo "  - LXC Config:        $LIMITED_USER_CONFIG_LXC/default.conf"
echo "  - Systemd Service:   $LIMITED_USER_CONFIG_SYSTEMD_USER/lxc-bg-start@.service"
echo ""
echo "Next Steps:"
echo "  1. Switch to the user: su - $LIMITED_USER"
echo "  2. Create a container: lxc-create -t download -n mycontainer"
echo "  3. Start the container: lxc-start -n mycontainer"
echo "  4. Auto-start on boot: systemctl --user enable lxc-bg-start@mycontainer"
echo ""
