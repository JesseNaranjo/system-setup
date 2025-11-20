#!/usr/bin/env bash

# setup-lxc.sh - LXC unprivileged container setup for a specified user
#
# Usage: sudo ./setup-lxc.sh <username> [subuid_start:100000]
#
# This script configures unprivileged LXC containers for a specific user by:
# - Checking and optionally installing bridge-utils package
# - Checking and optionally configuring br0 bridge for direct network access
# - Backing up /etc/lxc/default.conf
# - Adding veth interface permissions to /etc/lxc/lxc-usernet
# - Configuring subuid/subgid mappings in /etc/subuid and /etc/subgid
# - Enabling user namespaces (kernel.unprivileged_userns_clone)
# - Creating user's default LXC configuration (~/.config/lxc/default.conf)
# - Setting up systemd user service for LXC container auto-start
# - Enabling systemd lingering for the user
#
# Network Bridge (br0):
# - If br0 is not configured, the script offers to set it up
# - Automatically detects network interfaces and offers configuration
# - For single interface: offers automatic setup
# - For multiple interfaces: allows user to select which to bridge
# - Falls back to lxcbr0 (NAT mode) if br0 setup is declined or fails
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

print_backup() {
    echo -e "${GRAY}[ BACKUP  ] $1${NC}"
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

    # Set the prompt suffix based on default
    if [[ "${default,,}" == "y" ]]; then
        prompt_suffix="(Y/n)"
    else
        prompt_suffix="(y/N)"
    fi

    # Read from /dev/tty to work correctly in while-read loops
    read -p "$prompt_message $prompt_suffix: " -r user_reply </dev/tty

    # If user just pressed Enter (empty reply), use default
    if [[ -z "$user_reply" ]]; then
        [[ "${default,,}" == "y" ]]
    else
        [[ $user_reply =~ ^[Yy]$ ]]
    fi
}

# Backup file if it exists (only once per session)
backup_file() {
    local file="$1"

    # Check if already backed up in this session
    if [[ "$BACKED_UP_FILES" == *"$file"* ]]; then
        return 0
    fi

    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"

        # Copy file with preserved permissions (-p flag)
        cp -p "$file" "$backup"

        # Preserve ownership (requires appropriate permissions)
        # Get the owner and group of the original file
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS stat syntax
            local owner=$(stat -f "%u:%g" "$file")
            chown "$owner" "$backup" 2>/dev/null || true
        else
            # Linux stat syntax
            local owner=$(stat -c "%u:%g" "$file")
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
# Network Bridge Configuration
# ============================================================================

# Check if bridge-utils is installed (required for br0)
check_bridge_utils() {
    if command -v brctl >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to get available network interfaces (excluding loopback and virtual)
get_network_interfaces() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS - list physical interfaces
        networksetup -listallhardwareports 2>/dev/null | grep "Device:" | awk '{print $2}' | grep -v "^lo"
    else
        # Linux - list physical interfaces
        ip -o link show | awk -F': ' '{print $2}' | grep -v "^lo\|^veth\|^lxcbr\|^docker\|^virbr\|^br" | sed 's/@.*//'
    fi
}

# Function to check if br0 is configured in /etc/network/interfaces
check_br0_configured() {
    if [[ ! -f /etc/network/interfaces ]]; then
        return 1
    fi
    grep -q "^iface br0" /etc/network/interfaces 2>/dev/null
}

# Function to setup br0 bridge
setup_br0_bridge() {
    local bridge_ports="$1"

    print_info "Setting up br0 bridge with interface(s): $bridge_ports"

    # Backup the interfaces file
    backup_file "/etc/network/interfaces"

    # Check if br0 already exists in the file
    if check_br0_configured; then
        print_warning "- br0 already defined in /etc/network/interfaces"
        return 0
    fi

    # Append br0 configuration
    cat >> /etc/network/interfaces <<EOF

# Bridge interface for LXC containers
auto br0
iface br0 inet dhcp
    bridge_ports $bridge_ports
    bridge_fd 0
    bridge_maxwait 0
    bridge_stp off
    bridge_waitport 0
EOF

    print_success "- Added br0 configuration to /etc/network/interfaces"
    print_info "- Bridge ports: $bridge_ports"
    print_info "- Bridge forwarding delay: 0 (faster startup)"
    print_info "- Bridge max wait: 0 (no delay)"
    print_info "- Bridge STP: off (not needed for simple setups)"

    # Offer to bring up the bridge now
    echo ""

    if prompt_yes_no "Would you like to bring up the br0 bridge now?"; then
        print_info "Bringing up br0 bridge..."
        if ifup br0 2>/dev/null; then
            print_success "- br0 bridge is now active"
        else
            print_warning "- Could not bring up br0 automatically"
            print_warning "- You may need to reboot or run: sudo ifup br0"
        fi
    else
        print_warning "- br0 bridge not activated"
        print_warning "- Run 'sudo ifup br0' or reboot to activate"
    fi

    echo ""
}

# Check and offer to setup br0 bridge
print_info "Checking network bridge configuration..."

# Default to lxcbr0 (will be changed to br0 if successfully configured)
BRIDGE_LINK="lxcbr0"
SKIP_BRIDGE_SETUP=false

# Check if bridge-utils is installed
if ! check_bridge_utils; then
    print_warning "- bridge-utils package is not installed"
    print_info "- Bridge-utils is required for br0 networking"
    echo ""

    if prompt_yes_no "Would you like to install bridge-utils now?"; then
        print_info "Installing bridge-utils..."
        if apt-get update && apt-get install -y bridge-utils; then
            print_success "- bridge-utils installed successfully"
        else
            print_error "- Failed to install bridge-utils"
            print_warning "- Will use default lxcbr0 (NAT mode)"
            SKIP_BRIDGE_SETUP=true
        fi
    else
        print_info "Skipping bridge-utils installation, will use lxcbr0"
        SKIP_BRIDGE_SETUP=true
    fi
    echo ""
fi

if [[ "$SKIP_BRIDGE_SETUP" == "false" ]]; then
    if check_br0_configured; then
        print_success "✓ br0 bridge is already configured"
        BRIDGE_LINK="br0"
    else
        print_warning "- br0 bridge is not configured"
        print_info "- Setting up br0 allows containers to connect directly to your network"
        echo ""

        # Get available interfaces
        mapfile -t INTERFACES < <(get_network_interfaces)

        if [[ ${#INTERFACES[@]} -eq 0 ]]; then
            print_warning "No suitable network interfaces found"
            print_warning "Will use default lxcbr0 (NAT mode)"
        elif [[ ${#INTERFACES[@]} -eq 1 ]]; then
            # Single interface - offer to setup automatically
            SINGLE_INTERFACE="${INTERFACES[0]}"
            echo "Detected network interface: $SINGLE_INTERFACE"
            echo ""

            if prompt_yes_no "Would you like to setup br0 bridge on $SINGLE_INTERFACE?"; then
                setup_br0_bridge "$SINGLE_INTERFACE"
                BRIDGE_LINK="br0"
            else
                print_info "Skipping br0 setup, will use lxcbr0"
            fi
        else
            # Multiple interfaces - let user choose
            echo "Multiple network interfaces detected:"
            for i in "${!INTERFACES[@]}"; do
                echo "  $((i+1)). ${INTERFACES[$i]}"
            done
            echo ""

            if prompt_yes_no "Would you like to setup br0 bridge?"; then
                echo ""
                echo "Enter the interface(s) to bridge (space-separated, e.g., 'eth0' or 'eth0 eth1'):"
                read -r SELECTED_INTERFACES

                if [[ -n "$SELECTED_INTERFACES" ]]; then
                    setup_br0_bridge "$SELECTED_INTERFACES"
                    BRIDGE_LINK="br0"
                else
                    print_warning "No interfaces specified, will use lxcbr0"
                fi
            else
                print_info "Skipping br0 setup, will use lxcbr0"
            fi
        fi
    fi
fi
echo ""

# ============================================================================
# System Configuration
# ============================================================================

# Configure veth interface permissions
VETH_ENTRY="$LIMITED_USER veth $BRIDGE_LINK 10"

print_info "Configuring veth interface permissions..."
if grep -q "^$VETH_ENTRY" /etc/lxc/lxc-usernet 2>/dev/null; then
    print_success "✓ veth entry already exists in /etc/lxc/lxc-usernet"
else
    print_warning "Adding veth entry to /etc/lxc/lxc-usernet"
    backup_file "/etc/lxc/lxc-usernet"
    echo "$VETH_ENTRY" | tee -a /etc/lxc/lxc-usernet > /dev/null
    print_success "- Added: $VETH_ENTRY"
fi
echo ""

# Configure subuid mappings
SUB_ENTRY="$LIMITED_USER:$ID_NO:65535"

print_info "Configuring subuid mappings..."
if grep -q "^$SUB_ENTRY" /etc/subuid 2>/dev/null; then
    print_success "✓ subuid entry already exists in /etc/subuid"
else
    print_warning "Adding subuid entry to /etc/subuid"
    backup_file "/etc/subuid"
    echo "$SUB_ENTRY" | tee -a /etc/subuid > /dev/null
    print_success "- Added: $SUB_ENTRY"
fi
echo ""

# Configure subgid mappings
print_info "Configuring subgid mappings..."
if grep -q "^$SUB_ENTRY" /etc/subgid 2>/dev/null; then
    print_success "✓ subgid entry already exists in /etc/subgid"
else
    print_warning "Adding subgid entry to /etc/subgid"
    backup_file "/etc/subgid"
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
    backup_file "/etc/sysctl.d/99-lxc.conf"
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
lxc.net.0.link = $BRIDGE_LINK
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
echo "  - Network Bridge:    $BRIDGE_LINK"
echo "  - LXC Config:        $LIMITED_USER_CONFIG_LXC/default.conf"
echo "  - Systemd Service:   $LIMITED_USER_CONFIG_SYSTEMD_USER/lxc-bg-start@.service"
echo ""
echo "Next Steps:"
echo "  1. Switch to the user: su - $LIMITED_USER"
echo "  2. Create a container: lxc-create mycontainer -t download"
echo "  3. Start the container: ./start-lxc mycontainer"
echo ""
