#!/usr/bin/env bash

# setup-lxc.sh - LXC container setup (unprivileged or privileged)
#
# Usage: sudo ./setup-lxc.sh <username> [subuid_start:100000]
#        sudo ./setup-lxc.sh --privileged
#
# Unprivileged mode (default):
# - Checking and optionally installing bridge-utils package
# - Checking and optionally configuring br0 bridge for direct network access
# - Adding veth interface permissions to /etc/lxc/lxc-usernet
# - Configuring subuid/subgid mappings in /etc/subuid and /etc/subgid
# - Enabling user namespaces (kernel.unprivileged_userns_clone)
# - Configuring system-level cgroup delegation for Kubernetes containers
# - Creating user's default LXC configuration (~/.config/lxc/default.conf)
# - Setting up systemd user service for LXC container auto-start
# - Enabling systemd lingering for the user
#
# Privileged mode (--privileged):
# - Checking /etc/lxc/default.conf for veth networking
# - Installing system-level systemd service template for LXC auto-start
#
# Network Bridge (br0) [unprivileged only]:
# - If br0 is not configured, the script offers to set it up
# - Automatically detects network interfaces and offers configuration
# - For single interface: offers automatic setup
# - For multiple interfaces: allows user to select which to bridge
# - Falls back to lxcbr0 (NAT mode) if br0 setup is declined or fails
#
# The script automatically handles permission setting and configuration deployment.
# Existing configuration files are backed up before modification.

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=utils-lxc.sh
source "${SCRIPT_DIR}/utils-lxc.sh"

# Global variables
BACKED_UP_FILES=""

# Backup file if it exists (only once per session)
backup_file() {
    local file="$1"

    # Check if already backed up in this session
    if [[ "$BACKED_UP_FILES" == *"$file"* ]]; then
        return 0
    fi

    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S).bak"

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

check_for_updates "${BASH_SOURCE[0]}" "$@"

# ============================================================================
# Input Validation
# ============================================================================

if [[ $EUID != 0 ]]; then
    print_error "✖ This script requires root privileges (e.g., using su or sudo)."
    exit 1
fi

# Parse --privileged flag before positional arguments
PRIVILEGED=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --privileged)
            PRIVILEGED=true
            shift
            ;;
        -*)
            print_error "✖ Unknown option: $1"
            echo ""
            echo "Usage: ${0##*/} <username> [subuid_start]"
            echo "       ${0##*/} --privileged"
            exit 64  # EX_USAGE
            ;;
        *)
            break
            ;;
    esac
done

if [[ "$PRIVILEGED" == true ]]; then
    print_info "Configuring LXC for privileged containers (system scope)"
    echo ""
else
    if [[ $# -eq 0 || -z ${1-} ]]; then
        print_error "✖ Missing required username argument"
        echo ""
        echo "Usage: ${0##*/} <username> [subuid_start]"
        echo "       ${0##*/} --privileged"
        echo ""
        echo "Arguments:"
        echo "  username      - Target user for LXC setup"
        echo "  subuid_start  - Starting subuid/subgid ID (default: 100000)"
        echo ""
        echo "Options:"
        echo "  --privileged  - Configure for privileged containers (no user needed)"
        echo ""
        echo "Example:"
        echo "  sudo ${0##*/} myuser"
        echo "  sudo ${0##*/} myuser 200000"
        echo "  sudo ${0##*/} --privileged"
        exit 64  # 64 - EX_USAGE (sysexits.h)
    fi

    LIMITED_USER=$1

    if ! id -u "$LIMITED_USER" >/dev/null 2>&1; then
        print_error "✖ User \"$LIMITED_USER\" does not exist on this system"
        exit 67  # 67 - EX_NOUSER
    fi

    ID_NO=${2:-100000}

    print_info "Configuring LXC for user: $LIMITED_USER (subuid start: $ID_NO)"
    echo ""
fi

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
        print_warning "⚠ br0 already defined in /etc/network/interfaces"
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

    print_success "✓ Added br0 configuration to /etc/network/interfaces"
    print_info "- Bridge ports: $bridge_ports"
    print_info "- Bridge forwarding delay: 0 (faster startup)"
    print_info "- Bridge max wait: 0 (no delay)"
    print_info "- Bridge STP: off (not needed for simple setups)"

    # Offer to bring up the bridge now
    echo ""

    if prompt_yes_no "Would you like to bring up the br0 bridge now?"; then
        print_info "Bringing up br0 bridge..."
        if ifup br0 2>/dev/null; then
            print_success "✓ br0 bridge is now active"
        else
            print_warning "⚠ Could not bring up br0 automatically"
            print_warning "⚠ You may need to reboot or run: sudo ifup br0"
        fi
    else
        print_warning "⚠ br0 bridge not activated"
        print_warning "⚠ Run 'sudo ifup br0' or reboot to activate"
    fi

    echo ""
}

if [[ "$PRIVILEGED" != true ]]; then

# Check and offer to setup br0 bridge
print_info "Checking network bridge configuration..."

# Default to lxcbr0 (will be changed to br0 if successfully configured)
BRIDGE_LINK="lxcbr0"
SKIP_BRIDGE_SETUP=false

# Check if bridge-utils is installed
if ! check_bridge_utils; then
    print_warning "⚠ bridge-utils package is not installed"
    print_info "- Bridge-utils is required for br0 networking"
    echo ""

    if prompt_yes_no "Would you like to install bridge-utils now?"; then
        print_info "Installing bridge-utils..."
        if apt-get update && apt-get install -y bridge-utils; then
            print_success "✓ bridge-utils installed successfully"
        else
            print_error "✖ Failed to install bridge-utils"
            print_warning "⚠ Will use default lxcbr0 (NAT mode)"
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
        print_warning "⚠ br0 bridge is not configured"
        print_info "- Setting up br0 allows containers to connect directly to your network"
        echo ""

        # Get available interfaces
        mapfile -t INTERFACES < <(get_network_interfaces)

        if [[ ${#INTERFACES[@]} -eq 0 ]]; then
            print_warning "⚠ No suitable network interfaces found"
            print_warning "⚠ Will use default lxcbr0 (NAT mode)"
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
                    print_warning "⚠ No interfaces specified, will use lxcbr0"
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
    print_warning "⚠ Adding veth entry to /etc/lxc/lxc-usernet"
    backup_file "/etc/lxc/lxc-usernet"
    echo "$VETH_ENTRY" | tee -a /etc/lxc/lxc-usernet > /dev/null
    chmod 644 /etc/lxc/lxc-usernet
    chown root:root /etc/lxc/lxc-usernet
    print_success "✓ Added: $VETH_ENTRY"
fi
echo ""

# Configure subuid mappings
SUB_ENTRY="$LIMITED_USER:$ID_NO:65536"

print_info "Configuring subuid mappings..."
if grep -q "^$SUB_ENTRY" /etc/subuid 2>/dev/null; then
    print_success "✓ subuid entry already exists in /etc/subuid"
else
    print_warning "⚠ Adding subuid entry to /etc/subuid"
    backup_file "/etc/subuid"
    echo "$SUB_ENTRY" | tee -a /etc/subuid > /dev/null
    chmod 644 /etc/subuid
    chown root:root /etc/subuid
    print_success "✓ Added: $SUB_ENTRY"
fi
echo ""

# Configure subgid mappings
print_info "Configuring subgid mappings..."
if grep -q "^$SUB_ENTRY" /etc/subgid 2>/dev/null; then
    print_success "✓ subgid entry already exists in /etc/subgid"
else
    print_warning "⚠ Adding subgid entry to /etc/subgid"
    backup_file "/etc/subgid"
    echo "$SUB_ENTRY" | tee -a /etc/subgid > /dev/null
    chmod 644 /etc/subgid
    chown root:root /etc/subgid
    print_success "✓ Added: $SUB_ENTRY"
fi
echo ""

# Enable user namespaces
print_info "Verifying user namespace support..."
USER_NAMESPACE_ENABLED=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "0")

if [[ "$USER_NAMESPACE_ENABLED" -eq 1 ]]; then
    print_success "✓ User namespaces already enabled"
else
    print_warning "⚠ User namespaces not enabled, enabling permanently..."
    backup_file "/etc/sysctl.d/99-lxc.conf"
    sysctl -w kernel.unprivileged_userns_clone=1
    echo "kernel.unprivileged_userns_clone = 1" | tee /etc/sysctl.d/99-lxc.conf > /dev/null
    chmod 644 /etc/sysctl.d/99-lxc.conf
    chown root:root /etc/sysctl.d/99-lxc.conf
    sysctl --system > /dev/null 2>&1
    print_success "✓ Enabled user namespace support"
fi
echo ""

# Configure system-level cgroup delegation for user services
# This enables cpuset/io controllers for containers (required for Kubernetes)
DELEGATE_DROPIN="/etc/systemd/system/user@.service.d/delegate.conf"
DELEGATE_CONTENT="[Service]
Delegate=cpuset cpu io memory pids"

print_info "Checking system-level cgroup delegation..."
if [[ -f "$DELEGATE_DROPIN" ]] && [[ "$(<"$DELEGATE_DROPIN")" == "$DELEGATE_CONTENT" ]]; then
    print_success "- System-level cgroup delegation already configured"
else
    print_info "- Cgroup delegation enables cpuset/io controllers for user services"
    print_info "- Required for Kubernetes containers to pass cgroup preflight checks"
    echo ""

    if prompt_yes_no "Configure system-level cgroup delegation?" "y"; then
        backup_file "$DELEGATE_DROPIN"
        mkdir -p "$(dirname "$DELEGATE_DROPIN")"
        echo "$DELEGATE_CONTENT" > "$DELEGATE_DROPIN"
        chmod 644 "$DELEGATE_DROPIN"
        chown root:root "$DELEGATE_DROPIN"
        systemctl daemon-reload
        print_success "✓ System-level cgroup delegation configured"
        echo ""

        echo -e "${BOLD_RED}A reboot is required for cgroup controllers to become available.${NC}"
        if prompt_yes_no "Reboot now?" "n"; then
            print_info "Rebooting..."
            reboot
        else
            print_warning "⚠ Delegation will not take effect until next reboot"
        fi
    else
        print_info "Skipped system-level cgroup delegation"
    fi
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
lxc.idmap = u 0 $ID_NO 65536
lxc.idmap = g 0 $ID_NO 65536

# AppArmor Profile "unconfined" is necessary for networking to work (as of 2025-06-21)
lxc.apparmor.profile = unconfined

lxc.net.0.name = eth0
lxc.net.0.type = veth
lxc.net.0.link = $BRIDGE_LINK
lxc.net.0.flags = up
EOF

chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG"

chmod 644 "$LIMITED_USER_CONFIG_LXC/default.conf"
chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_LXC"
chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_LXC/default.conf"
print_success "✓ Created LXC default configuration"
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

print_success "✓ Permissions set correctly"
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

chmod 644 "$LIMITED_USER_CONFIG_SYSTEMD_USER/lxc-bg-start@.service"
print_success "✓ Created systemd service template"
echo ""

# Enable systemd lingering
print_info "Enabling systemd lingering for user: $LIMITED_USER"
if loginctl enable-linger ${LIMITED_USER}; then
    print_success "✓ Systemd lingering enabled"
else
    print_warning "⚠ Failed to enable systemd lingering (may need manual intervention)"
fi
echo ""

# Set ownership on systemd files
chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_SYSTEMD"
chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_SYSTEMD_USER"
chown ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_SYSTEMD_USER/lxc-bg-start@.service"

fi  # end unprivileged-only sections

# ============================================================================
# Privileged Container Configuration
# ============================================================================

if [[ "$PRIVILEGED" == true ]]; then

# Check /etc/lxc/default.conf for veth networking
print_info "Checking /etc/lxc/default.conf networking configuration..."
if grep -q '^lxc.net.0.type.*=.*veth' /etc/lxc/default.conf 2>/dev/null; then
    print_success "- /etc/lxc/default.conf already has veth networking"
else
    print_warning "⚠ /etc/lxc/default.conf has no veth networking"
    if prompt_yes_no "Add lxcbr0 networking to /etc/lxc/default.conf?" "y"; then
        backup_file "/etc/lxc/default.conf"
        cat >> /etc/lxc/default.conf <<EOF

lxc.net.0.name = eth0
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
EOF
        print_success "✓ Added veth/lxcbr0 networking to /etc/lxc/default.conf"
    else
        print_info "Skipped networking configuration"
    fi
fi
echo ""

# Install system-level systemd service template for privileged containers
PRIV_SERVICE_PATH="/etc/systemd/system/lxc-priv-bg-start@.service"

print_info "Creating system-level systemd service for privileged LXC auto-start..."
print_info "- Location: $PRIV_SERVICE_PATH"

tee "$PRIV_SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=LXC Container %i
After=network.target

[Service]
ExecStart=/usr/bin/lxc-start -n %i
ExecStop=/usr/bin/lxc-stop -n %i
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$PRIV_SERVICE_PATH"
chown root:root "$PRIV_SERVICE_PATH"
systemctl daemon-reload
print_success "✓ Created systemd service template"
echo ""

fi  # end privileged-only sections

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "========================================================================"
if [[ "$PRIVILEGED" == true ]]; then
    print_success "LXC privileged container configuration completed"
else
    print_success "LXC configuration completed successfully for user: $LIMITED_USER"
fi
echo "========================================================================"
echo ""
echo "Configuration Summary:"
if [[ "$PRIVILEGED" == true ]]; then
    echo "  - Mode:              Privileged (system scope)"
    echo "  - Systemd Service:   /etc/systemd/system/lxc-priv-bg-start@.service"
    echo "  - LXC Config:        /etc/lxc/default.conf"
    echo ""
    echo "Next Steps:"
    echo "  1. Create a container: lxc-create -n mycontainer -t download"
    echo "  2. Start the container: lxc-start -n mycontainer"
    echo "  3. Enable auto-start:  systemctl enable lxc-priv-bg-start@mycontainer"
else
    echo "  - User:              $LIMITED_USER"
    echo "  - Subuid/Subgid:     $ID_NO-$((ID_NO + 65535))"
    echo "  - Network Bridge:    $BRIDGE_LINK"
    echo "  - LXC Config:        $LIMITED_USER_CONFIG_LXC/default.conf"
    echo "  - Systemd Service:   $LIMITED_USER_CONFIG_SYSTEMD_USER/lxc-bg-start@.service"
    if [[ -f "$DELEGATE_DROPIN" ]]; then
        echo "  - Cgroup Delegation: $DELEGATE_DROPIN"
    fi
    echo ""
    echo "Next Steps:"
    echo "  1. Switch to the user: su - $LIMITED_USER"
    echo "  2. Create a container: lxc-create mycontainer -t download"
    echo "  3. Start the container: ./start-lxc mycontainer"
fi
echo ""
