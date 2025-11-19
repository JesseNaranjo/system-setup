#!/usr/bin/env bash

# configure-container-static-ip.sh - Configure static IP for containers
# Part of the system-setup suite
#
# This script:
# - Detects container environment
# - Configures static IP address for containers using systemd-networkd
# - Maintains DHCP while adding secondary static IP

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Container Static IP Configuration
# ============================================================================

# Configure static IP address for containers
configure_container_static_ip() {
    # Only applicable for Linux containers
    if [[ "$DETECTED_OS" != "linux" ]]; then
        return 0
    fi

    # Only run if in a container
    if [[ "$RUNNING_IN_CONTAINER" != true ]]; then
        return 0
    fi

    print_info "Checking static IP configuration for container..."

    # Check if systemd-networkd is available
    if [[ ! -d /etc/systemd/network ]]; then
        print_warning "/etc/systemd/network directory not found - systemd-networkd may not be configured"
        return 0
    fi

    # Get primary network interface (exclude lo, docker, veth, etc.)
    local primary_interface=""
    for iface in /sys/class/net/*; do
        local iface_name=$(basename "$iface")

        # Skip loopback, docker, and veth interfaces
        if [[ "$iface_name" == "lo" ]] || [[ "$iface_name" == docker* ]] || [[ "$iface_name" == veth* ]] || [[ "$iface_name" == br-* ]]; then
            continue
        fi

        # Get the first valid interface
        if [[ -z "$primary_interface" ]]; then
            primary_interface="$iface_name"
        fi
    done

    if [[ -z "$primary_interface" ]]; then
        print_warning "No suitable network interface found"
        return 0
    fi

    echo "          - Primary network interface: $primary_interface"

    # Get all current IP addresses
    if command -v ip &>/dev/null; then
        local ip_addresses=$(ip -4 addr show "$primary_interface" 2>/dev/null | grep "inet " | awk '{print $2}')
        if [[ -n "$ip_addresses" ]]; then
            echo "          - Current IP address(es):"
            while IFS= read -r ip_addr; do
                echo "            • $ip_addr"
            done <<< "$ip_addresses"
        else
            print_warning "- No IP address currently assigned"
        fi
    else
        print_warning "- 'ip' command not found, cannot display current IP addresses"
    fi

    # Check if static IP is already configured
    local network_file="/etc/systemd/network/10-${primary_interface}.network"
    local has_static_ip=false

    if [[ -f "$network_file" ]] &&  grep -q "^\[Address\]" "$network_file" 2>/dev/null; then
        has_static_ip=true
        print_success "Static IP configuration already exists in $network_file"

        # Show configured static IPs
        local static_ips=$(grep -A 1 "^\[Address\]" "$network_file" | grep "^Address=" | cut -d= -f2)
        if [[ -n "$static_ips" ]]; then
            echo "          - Configured static IP(s):"
            while IFS= read -r ip; do
                echo "            • $ip"
            done <<< "$static_ips"
        fi
        echo ""
        return 0
    fi

    echo ""
    print_info "Container static IP configuration:"
    echo "          - This will add a secondary static IP address to $primary_interface"
    echo "          - DHCP will remain enabled for the primary IP"
    echo "          - Uses systemd-networkd configuration"
    echo ""

    if ! prompt_yes_no "          Would you like to configure a static IP address?" "y"; then
        print_info "Skipping static IP configuration"
        return 0
    fi

    echo ""

    # Prompt for static IP address in CIDR notation
    local static_ip=""
    local static_prefix=""

    while true; do
        read -p "          Enter static IP in CIDR notation (e.g., 192.168.1.100/24, defaults to /24): " -r user_input </dev/tty

        # Check if input contains a slash (CIDR notation)
        if [[ "$user_input" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})(/([0-9]+))?$ ]]; then
            static_ip="${BASH_REMATCH[1]}"
            static_prefix="${BASH_REMATCH[3]}"

            # Set default prefix if not provided
            if [[ -z "$static_prefix" ]]; then
                static_prefix="24"
            fi

            # Validate IP address octets (0-255)
            local valid=true
            IFS='.' read -ra OCTETS <<< "$static_ip"
            for octet in "${OCTETS[@]+"${OCTETS[@]}"}"; do
                if [[ $octet -gt 255 ]]; then
                    valid=false
                    break
                fi
            done

            # Validate prefix (1-32)
            if [[ $static_prefix -lt 1 ]] || [[ $static_prefix -gt 32 ]]; then
                valid=false
            fi

            if [[ "$valid" == true ]]; then
                break
            fi
        fi

        print_error "Invalid IP address format. Please use CIDR notation (e.g., 192.168.1.100/24)"
    done

    echo ""
    print_info "Configuring static IP: ${static_ip}/${static_prefix} on ${primary_interface}..."

    # Backup existing network file if it exists
    if [[ -f "$network_file" ]]; then
        backup_file "$network_file"
    fi

    # Create or update the network configuration file
    cat > "$network_file" << EOF
# Network configuration for $primary_interface
# Managed by system-setup.sh
# Updated: $(date)

[Match]
Name=$primary_interface

[Network]
DHCP=yes

[Address]
Address=${static_ip}/${static_prefix}
EOF

    print_success "✓ Static IP configuration written to $network_file"
    echo ""

    # Restart systemd-networkd
    print_info "Restarting systemd-networkd to apply changes..."
    if systemctl restart systemd-networkd.service 2>/dev/null; then
        print_success "✓ systemd-networkd restarted successfully"

        # Wait a moment for network to settle
        sleep 2

        # Show new IP configuration
        echo ""
        print_info "Current IP addresses on $primary_interface:"
        ip -4 addr show "$primary_interface" 2>/dev/null | grep "inet " | awk '{print "          - " $2}' || true
    else
        print_warning "Could not restart systemd-networkd (may require manual restart)"
        print_info "To apply changes manually, run: systemctl restart systemd-networkd"
    fi

    echo ""
    print_success "Static IP configuration complete"
}

# ============================================================================
# Main Execution
# ============================================================================

main_configure_container_static_ip() {
    # Detect OS if not already detected
    if [[ -z "$DETECTED_OS" ]]; then
        detect_os
    fi

    # Detect container environment if not already detected
    if [[ "$RUNNING_IN_CONTAINER" == false ]] || [[ "$DETECTED_OS" == "linux" ]]; then
        detect_container
    fi

    configure_container_static_ip
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_container_static_ip "$@"
fi
