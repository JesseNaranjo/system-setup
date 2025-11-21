#!/usr/bin/env bash

# system-configuration-issue.sh - Configure /etc/issue with network information
# Part of the system-setup suite
#
# This script:
# - Detects network interfaces
# - Updates /etc/issue with network interface information
# - Maintains formatting and updates automatically

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Network Interface Detection
# ============================================================================

# Detect network interface type
get_interface_type() {
    local iface="$1"

    # Skip loopback
    if [[ "$iface" == "lo" ]]; then
        echo "loopback"
        return
    fi

    # Check if wireless interface
    if [[ -d "/sys/class/net/${iface}/wireless" ]] || [[ -L "/sys/class/net/${iface}/phy80211" ]]; then
        echo "wifi"
        return
    fi

    # Check if it's a virtual/bridge interface
    if [[ -d "/sys/class/net/${iface}/bridge" ]]; then
        echo "bridge"
        return
    fi

    # Check if it's a tun/tap interface
    if [[ -f "/sys/class/net/${iface}/tun_flags" ]]; then
        echo "vpn"
        return
    fi

    # Check if it's a virtual ethernet (veth, docker, lxc)
    local dev_id=""
    if [[ -f "/sys/class/net/${iface}/dev_id" ]]; then
        dev_id=$(cat "/sys/class/net/${iface}/dev_id" 2>/dev/null)
    fi

    # veth pairs typically used by containers
    if [[ "$iface" == veth* ]]; then
        echo "veth"
        return
    fi

    # Docker interfaces
    if [[ "$iface" == docker* ]] || [[ "$iface" == br-* ]]; then
        echo "docker"
        return
    fi

    # Default to wired for physical ethernet interfaces
    echo "wire"
}

# Helper to get network interfaces, categorized
# Populates the global arrays: wire_interfaces, wifi_interfaces, other_interfaces
get_network_interfaces() {
    # Clear previous results
    wire_interfaces=()
    wifi_interfaces=()
    other_interfaces=()

    for iface in /sys/class/net/*; do
        local iface_name=$(basename "$iface")
        # Skip loopback
        if [[ "$iface_name" == "lo" ]]; then
            continue
        fi

        local iface_type=$(get_interface_type "$iface_name")
        case "$iface_type" in
            wire)
                wire_interfaces+=("$iface_name")
                ;;
            wifi)
                wifi_interfaces+=("$iface_name")
                ;;
            veth)
                # Skip virtual ethernet interfaces
                ;;
            loopback)
                # Skip loopback
                ;;
            *)
                other_interfaces+=("$iface_name:$iface_type")
                ;;
        esac
    done
}

# Helper to extract existing interface names from /etc/issue
# Populates the global array: existing_interfaces
get_existing_issue_interfaces() {
    existing_interfaces=()
    if [[ ! -f /etc/issue ]] || ! grep -q "║ Network Interfaces" /etc/issue; then
        return
    fi

    while IFS= read -r line; do
        # Match lines like: "  ║ - wire: \4{eth0} / \6{eth0} (eth0)"
        if [[ "$line" =~ \(([a-zA-Z0-9_-]+)\)[[:space:]]*$ ]]; then
            existing_interfaces+=("${BASH_REMATCH[1]}")
        fi
    done < <(sed -n '/║ Network Interfaces/,/^\s*╚═/p' /etc/issue)
}

# Helper to generate the new /etc/issue content box
generate_issue_content() {
    local temp_box=$(mktemp)

    # Add box with network interfaces
    echo "  ╔═══════════════════════════════════════════════════════════════════════════" > "$temp_box"
    echo "  ║ Network Interfaces" >> "$temp_box"
    echo "  ╠═══════════════════════════════════════════════════════════════════════════" >> "$temp_box"

    # Add wired, wireless, and other interfaces
    for iface in "${wire_interfaces[@]+"${wire_interfaces[@]}"}"; do
        echo "  ║ - wire: \\4{${iface}} / \\6{${iface}} (${iface})" >> "$temp_box"
    done
    for iface in "${wifi_interfaces[@]+"${wifi_interfaces[@]}"}"; do
        echo "  ║ - wifi: \\4{${iface}} / \\6{${iface}} (${iface})" >> "$temp_box"
    done
    for iface_info in "${other_interfaces[@]+"${other_interfaces[@]}"}"; do
        local iface="${iface_info%%:*}"
        local type="${iface_info##*:}"
        echo "  ║ - ${type}: \\4{${iface}} / \\6{${iface}} (${iface})" >> "$temp_box"
    done

    echo "  ╚═══════════════════════════════════════════════════════════════════════════" >> "$temp_box"

    echo "$temp_box"
}

# ============================================================================
# /etc/issue Configuration
# ============================================================================

# Configure /etc/issue with network interface information
configure_issue_network() {
    local issue_file="/etc/issue"

    # This feature is only for Linux and not in containers
    if [[ "$DETECTED_OS" != "linux" ]] || [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        print_info "$issue_file network info is only for non-containerized Linux systems. Skipping."
        return
    fi

    # Should already be covered by system scope check, but verify
    if ! check_privileges "system_config"; then
        print_error "No privileges to configure $issue_file. This should not happen."
        return
    fi

    print_info "Configuring network interfaces in $issue_file..."

    # Get current and previously configured interfaces
    get_network_interfaces
    get_existing_issue_interfaces

    # Compare current interfaces with existing ones to see if an update is needed
    local current_ifaces=$(printf "%s\n" "${wire_interfaces[@]}" "${wifi_interfaces[@]}" "${other_interfaces[@]%%:*}" | sort)
    local existing_ifaces=$(printf "%s\n" "${existing_interfaces[@]}" | sort)

    if [[ "$current_ifaces" == "$existing_ifaces" ]]; then
        print_success "- Network interfaces in $issue_file are already up-to-date"
        return
    fi

    print_info "Network interface changes detected. Updating $issue_file..."
    echo "            - Displayed: $existing_ifaces"
    echo "            - Current:  $current_ifaces"

    # Backup the file before making changes
    backup_file "$issue_file"

    # Generate the new network info box content
    local temp_box_path=$(generate_issue_content)
    local new_content=$(<"$temp_box_path")
    rm -f "$temp_box_path"

    # If the marker doesn't exist, add the box at the end of the file.
    if ! grep -q "║ Network Interfaces" "$issue_file"; then
        echo -e "\n$new_content" | run_elevated tee -a "$issue_file" > /dev/null
        print_success "✓ Added network interface info to $issue_file"
    else
        # If the marker exists, replace the entire block.
        local temp_issue=$(mktemp)
        # Use awk to replace the block between the start and end markers
        awk -v new_content="$new_content" '
            BEGIN { printing=1 }
            /║ Network Interfaces/ {
                if (printing) {
                    print new_content
                    printing=0
                }
            }
            /╚═.*═╝/ {
                if (!printing) {
                    printing=1
                    next
                }
            }
            printing { print }
        ' "$issue_file" > "$temp_issue"

        run_elevated mv "$temp_issue" "$issue_file"
        print_success "✓ Updated network interface info in $issue_file"
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

main_configure_issue() {
    # Detect OS if not already detected
    if [[ -z "$DETECTED_OS" ]]; then
        detect_os
    fi

    # Detect container environment if not already detected
    if [[ "$RUNNING_IN_CONTAINER" == false ]] || [[ "$DETECTED_OS" == "linux" ]]; then
        detect_container
    fi

    configure_issue_network
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_issue "$@"
fi
