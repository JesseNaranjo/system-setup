#!/usr/bin/env bash

# migrate-to-systemd-networkd.sh - Migrate from ifupdown to systemd-networkd
# Part of the system-setup suite
#
# This script:
# - Offers to migrate Linux systems using ifupdown to systemd-networkd
# - Parses /etc/network/interfaces using ifquery for reliable extraction
# - Generates systemd-networkd .network files (and .netdev for bridges)
# - Handles DHCP, static IPs, and bridges with best-effort migration
# - Appends original interface stanza as comments for reference
# - Manages service transitions (networking -> systemd-networkd)
# - Provides rollback instructions

set -euo pipefail

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source utilities
# shellcheck source=../utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Constants
# ============================================================================

readonly INTERFACES_FILE="/etc/network/interfaces"
readonly NETWORKD_DIR="/etc/systemd/network"
readonly RESOLV_CONF="/etc/resolv.conf"
readonly RESOLVED_STUB="/run/systemd/resolve/stub-resolv.conf"

# Priority numbering for .network files
readonly PRIORITY_STANDARD=10
readonly PRIORITY_BRIDGE=20

# Unsupported configuration keywords to warn about
readonly -a UNSUPPORTED_KEYWORDS=(
    "vlan-raw-device"
    "bond-master"
    "bond-slaves"
    "bond-mode"
    "bond-miimon"
    "pre-up"
    "post-up"
    "up"
    "pre-down"
    "post-down"
    "down"
    "wpa-ssid"
    "wpa-psk"
    "wpa-conf"
    "wireless-"
    "ppp"
    "provider"
    "metric"
    "mtu"
    "hwaddress"
)

# ============================================================================
# Global Variables
# ============================================================================

# Track created files for rollback instructions
declare -a CREATED_NETWORK_FILES=()
declare -a CREATED_NETDEV_FILES=()
RESOLV_CONF_SYMLINKED=false
INTERFACES_BACKUP_PATH=""

# Track unsupported configurations found
declare -a UNSUPPORTED_FOUND=()

# Stanza cache for performance optimization (avoids N+1 file reads)
declare -A STANZA_CACHE=()
STANZA_CACHE_POPULATED=false

# ============================================================================
# Precondition Checks
# ============================================================================

# Check if system uses ifupdown and is suitable for migration
# Returns: 0 if suitable, 1 otherwise
check_migration_preconditions() {
    print_info "Checking migration preconditions..."

    # Check for Linux OS
    if [[ "$DETECTED_OS" != "linux" ]]; then
        print_error "This migration is only supported on Linux systems."
        return 1
    fi

    # Check for /etc/network/interfaces
    if [[ ! -f "$INTERFACES_FILE" ]]; then
        print_info "No $INTERFACES_FILE found - system doesn't use ifupdown."
        return 1
    fi

    # Check if interfaces file has non-loopback stanzas
    if ! grep -qE "^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+" "$INTERFACES_FILE" 2>/dev/null || \
       ! grep -E "^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+" "$INTERFACES_FILE" 2>/dev/null | grep -qvE "[[:space:]]lo([[:space:]]|$)"; then
        print_info "No non-loopback interfaces found in $INTERFACES_FILE."
        return 1
    fi

    # Check for ifquery command
    if ! command -v ifquery &>/dev/null; then
        print_error "ifquery command not found."
        print_info "The ifquery utility (from ifupdown package) is required to parse interface configurations."
        print_info "Please ensure ifupdown is installed: apt install ifupdown"
        return 1
    fi

    # Check for systemd-networkd service
    if ! systemctl list-unit-files systemd-networkd.service &>/dev/null; then
        print_error "systemd-networkd service not found."
        print_info "This system doesn't appear to have systemd-networkd available."
        return 1
    fi

    # Check for /etc/systemd/network directory
    if [[ ! -d "$NETWORKD_DIR" ]]; then
        print_info "Creating $NETWORKD_DIR directory..."
        mkdir -p "$NETWORKD_DIR"
    fi

    # Container warning
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        print_warning "Running inside a container environment."
        print_warning "Container networking is often managed by the host system."
        print_warning "Modifying network configuration inside a container may cause connectivity issues."
        echo ""
        if ! prompt_yes_no "Continue with migration anyway?" "n"; then
            print_info "Migration cancelled."
            return 1
        fi
    fi

    print_success "✓ Preconditions met for migration"
    return 0
}

# ============================================================================
# Interface Parsing Functions
# ============================================================================

# Get list of configured interfaces (excluding loopback)
# Outputs interface names, one per line
get_interface_list() {
    # Get auto interfaces
    ifquery -l 2>/dev/null | grep -v "^lo$" | sort -u

    # Also get allow-hotplug interfaces
    ifquery -l --allow=hotplug 2>/dev/null | grep -v "^lo$" | sort -u
}

# Parse interface configuration using ifquery
# Args: $1 = interface name
# Outputs: key: value pairs
parse_interface_config() {
    local iface="$1"
    ifquery "$iface" 2>/dev/null || true
}

# Extract original stanza from interfaces file for an interface
# Args: $1 = interface name
# Outputs: The original stanza lines
extract_original_stanza() {
    local iface="$1"
    local in_stanza=false
    local stanza_lines=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Check for auto/allow-hotplug lines for this interface
        if [[ "$line" =~ ^[[:space:]]*(auto|allow-hotplug)[[:space:]]+.*[[:space:]]?"$iface"([[:space:]]|$) ]]; then
            stanza_lines+="$line"$'\n'
        fi

        # Check for iface line for this interface
        if [[ "$line" =~ ^[[:space:]]*iface[[:space:]]+"$iface"[[:space:]]+ ]]; then
            in_stanza=true
            stanza_lines+="$line"$'\n'
            continue
        fi

        # If in stanza, collect indented lines
        if [[ "$in_stanza" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]+[^[:space:]] ]]; then
                stanza_lines+="$line"$'\n'
            elif [[ "$line" =~ ^[[:space:]]*$ ]]; then
                # Empty line, might still be in stanza
                continue
            else
                # Non-indented line, end of stanza
                in_stanza=false
            fi
        fi
    done < "$INTERFACES_FILE"

    # Also check sourced files
    local source_dirs=$(grep -E "^[[:space:]]*(source|source-directory)[[:space:]]+" "$INTERFACES_FILE" 2>/dev/null | awk '{print $2}' || true)

    for source_path in $source_dirs; do
        # Expand globs
        for file in $source_path; do
            if [[ -f "$file" ]]; then
                in_stanza=false
                while IFS= read -r line || [[ -n "$line" ]]; do
                    if [[ "$line" =~ ^[[:space:]]*(auto|allow-hotplug)[[:space:]]+.*[[:space:]]?"$iface"([[:space:]]|$) ]]; then
                        stanza_lines+="$line"$'\n'
                    fi
                    if [[ "$line" =~ ^[[:space:]]*iface[[:space:]]+"$iface"[[:space:]]+ ]]; then
                        in_stanza=true
                        stanza_lines+="$line"$'\n'
                        continue
                    fi
                    if [[ "$in_stanza" == true ]]; then
                        if [[ "$line" =~ ^[[:space:]]+[^[:space:]] ]]; then
                            stanza_lines+="$line"$'\n'
                        elif [[ "$line" =~ ^[[:space:]]*$ ]]; then
                            continue
                        else
                            in_stanza=false
                        fi
                    fi
                done < "$file"
            fi
        done
    done

    echo "$stanza_lines"
}

# Pre-load all interface stanzas into cache
# Args: $1 = space-separated list of interfaces
populate_stanza_cache() {
    local interfaces="$1"

    for iface in $interfaces; do
        local stanza
        stanza=$(extract_original_stanza "$iface")
        if [[ -z "$stanza" ]]; then
            print_warning "Could not extract stanza for interface: $iface"
        fi
        STANZA_CACHE["$iface"]="$stanza"
    done
    STANZA_CACHE_POPULATED=true
}

# Get stanza from cache (or extract if cache not populated)
# Args: $1 = interface name
get_cached_stanza() {
    local iface="$1"

    if [[ "$STANZA_CACHE_POPULATED" == true ]]; then
        echo "${STANZA_CACHE[$iface]:-}"
    else
        extract_original_stanza "$iface"
    fi
}

# Write config file with error checking
# Args: $1=file_path $2=content $3=file_type(network|netdev)
# Returns: 0 on success, 1 on failure
write_config_file() {
    local file="$1"
    local content="$2"
    local file_type="${3:-network}"

    if ! printf '%s\n' "$content" > "$file" 2>/dev/null; then
        print_error "Failed to write $file"
        return 1
    fi

    if ! chmod 644 "$file"; then
        print_error "Failed to set permissions on $file"
        rm -f "$file"
        return 1
    fi

    if ! chown root:root "$file"; then
        print_error "Failed to set ownership on $file"
        rm -f "$file"
        return 1
    fi

    if [[ "$file_type" == "netdev" ]]; then
        CREATED_NETDEV_FILES+=("$file")
    else
        CREATED_NETWORK_FILES+=("$file")
    fi

    print_success "  ✓ Created $file"
    return 0
}

# Check for unsupported configurations in interface
# Args: $1 = interface name, $2 = ifquery output
check_unsupported_config() {
    local iface="$1"
    local config="$2"

    for keyword in "${UNSUPPORTED_KEYWORDS[@]}"; do
        if echo "$config" | grep -qi "^${keyword}"; then
            UNSUPPORTED_FOUND+=("$iface: $keyword")
        fi
    done

    # Check original stanza for pre/post commands
    local stanza=$(get_cached_stanza "$iface")
    for keyword in pre-up post-up up pre-down post-down down; do
        if echo "$stanza" | grep -qE "^[[:space:]]+${keyword}[[:space:]]"; then
            # Avoid duplicates
            local entry="$iface: $keyword script"
            if [[ ! " ${UNSUPPORTED_FOUND[*]} " =~ " ${entry} " ]]; then
                UNSUPPORTED_FOUND+=("$entry")
            fi
        fi
    done
}

# ============================================================================
# Network File Generation
# ============================================================================

# Generate .network file content for an interface
# Args: $1 = interface name, $2 = ifquery output (inet), $3 = ifquery output (inet6, optional)
generate_network_file() {
    local iface="$1"
    local config_inet="$2"
    local config_inet6="${3:-}"

    local content=""
    local is_bridge=false
    local bridge_ports=""

    # Check if this is a bridge
    if echo "$config_inet" | grep -qi "^bridge_ports"; then
        is_bridge=true
        bridge_ports=$(echo "$config_inet" | grep -i "^bridge_ports" | cut -d: -f2- | xargs)
    fi

    # Header
    content+="# systemd-networkd configuration for $iface"$'\n'
    content+="# Generated by system-setup migrate-to-systemd-networkd.sh"$'\n'
    content+="# Date: $(date)"$'\n'
    content+=""$'\n'

    # [Match] section
    content+="[Match]"$'\n'
    content+="Name=$iface"$'\n'
    content+=""$'\n'

    # [Network] section
    content+="[Network]"$'\n'

    # Determine method (dhcp or static)
    local method_inet=""
    local method_inet6=""

    # Parse inet method from ifquery output
    # ifquery output format is "key: value"
    if echo "$config_inet" | grep -qi "^method"; then
        method_inet=$(echo "$config_inet" | grep -i "^method" | head -1 | cut -d: -f2- | xargs | tr '[:upper:]' '[:lower:]')
    fi

    if [[ -n "$config_inet6" ]] && echo "$config_inet6" | grep -qi "^method"; then
        method_inet6=$(echo "$config_inet6" | grep -i "^method" | head -1 | cut -d: -f2- | xargs | tr '[:upper:]' '[:lower:]')
    fi

    # Handle DHCP
    if [[ "$method_inet" == "dhcp" && "$method_inet6" == "dhcp" ]]; then
        content+="DHCP=yes"$'\n'
    elif [[ "$method_inet" == "dhcp" ]]; then
        content+="DHCP=ipv4"$'\n'
    elif [[ "$method_inet6" == "dhcp" || "$method_inet6" == "auto" ]]; then
        content+="DHCP=ipv6"$'\n'
    fi

    # Handle static addresses for inet
    if [[ "$method_inet" == "static" ]]; then
        local address=""
        local netmask=""
        local gateway=""

        if echo "$config_inet" | grep -qi "^address"; then
            address=$(echo "$config_inet" | grep -i "^address" | head -1 | cut -d: -f2- | xargs)
        fi

        if echo "$config_inet" | grep -qi "^netmask"; then
            netmask=$(echo "$config_inet" | grep -i "^netmask" | head -1 | cut -d: -f2- | xargs)
        fi

        if echo "$config_inet" | grep -qi "^gateway"; then
            gateway=$(echo "$config_inet" | grep -i "^gateway" | head -1 | cut -d: -f2- | xargs)
        fi

        # Convert netmask to CIDR if needed
        if [[ -n "$address" ]]; then
            if [[ "$address" != *"/"* && -n "$netmask" ]]; then
                local cidr=$(netmask_to_cidr "$netmask")
                address="${address}/${cidr}"
            fi
            content+="Address=$address"$'\n'
        fi

        if [[ -n "$gateway" ]]; then
            content+="Gateway=$gateway"$'\n'
        fi
    fi

    # Handle static addresses for inet6
    if [[ "$method_inet6" == "static" && -n "$config_inet6" ]]; then
        local address6=""
        local gateway6=""

        if echo "$config_inet6" | grep -qi "^address"; then
            address6=$(echo "$config_inet6" | grep -i "^address" | head -1 | cut -d: -f2- | xargs)
        fi

        if echo "$config_inet6" | grep -qi "^gateway"; then
            gateway6=$(echo "$config_inet6" | grep -i "^gateway" | head -1 | cut -d: -f2- | xargs)
        fi

        if [[ -n "$address6" ]]; then
            content+="Address=$address6"$'\n'
        fi

        if [[ -n "$gateway6" ]]; then
            content+="Gateway=$gateway6"$'\n'
        fi
    fi

    # Handle DNS
    local dns_servers=""
    if echo "$config_inet" | grep -qi "^dns-nameservers"; then
        dns_servers=$(echo "$config_inet" | grep -i "^dns-nameservers" | cut -d: -f2- | xargs)
    fi

    if [[ -n "$dns_servers" ]]; then
        for dns in $dns_servers; do
            content+="DNS=$dns"$'\n'
        done
    fi

    # Handle DNS search domains
    local dns_search=""
    if echo "$config_inet" | grep -qi "^dns-search"; then
        dns_search=$(echo "$config_inet" | grep -i "^dns-search" | cut -d: -f2- | xargs)
    fi

    if [[ -n "$dns_search" ]]; then
        content+="Domains=$dns_search"$'\n'
    fi

    # If this is a bridge, add Bridge= to member interfaces later
    if [[ "$is_bridge" == true ]]; then
        content+=""$'\n'
        content+="# Bridge configuration - member ports configured separately"$'\n'
    fi

    content+=""$'\n'

    # Add original stanza as comments
    content+="# ============================================================================"$'\n'
    content+="# Original /etc/network/interfaces stanza:"$'\n'
    content+="# ============================================================================"$'\n'

    local original_stanza=$(get_cached_stanza "$iface")
    if [[ -n "$original_stanza" ]]; then
        while IFS= read -r line; do
            content+="# $line"$'\n'
        done <<< "$original_stanza"
    fi

    echo "$content"
}

# Generate .netdev file for a bridge
# Args: $1 = bridge interface name
generate_bridge_netdev() {
    local iface="$1"

    local content=""
    content+="# systemd-networkd bridge device for $iface"$'\n'
    content+="# Generated by system-setup migrate-to-systemd-networkd.sh"$'\n'
    content+="# Date: $(date)"$'\n'
    content+=""$'\n'
    content+="[NetDev]"$'\n'
    content+="Name=$iface"$'\n'
    content+="Kind=bridge"$'\n'

    echo "$content"
}

# Generate .network file for a bridge member port
# Args: $1 = port interface name, $2 = bridge interface name
generate_bridge_port_network() {
    local port="$1"
    local bridge="$2"

    local content=""
    content+="# systemd-networkd configuration for $port (bridge port)"$'\n'
    content+="# Generated by system-setup migrate-to-systemd-networkd.sh"$'\n'
    content+="# Date: $(date)"$'\n'
    content+=""$'\n'
    content+="[Match]"$'\n'
    content+="Name=$port"$'\n'
    content+=""$'\n'
    content+="[Network]"$'\n'
    content+="Bridge=$bridge"$'\n'

    echo "$content"
}

# Convert dotted netmask to CIDR notation
# Args: $1 = netmask (e.g., 255.255.255.0)
# Outputs: CIDR prefix (e.g., 24)
netmask_to_cidr() {
    local netmask="$1"
    local cidr=0

    IFS='.' read -ra octets <<< "$netmask"
    for octet in "${octets[@]}"; do
        case "$octet" in
            255) ((cidr+=8)) ;;
            254) ((cidr+=7)) ;;
            252) ((cidr+=6)) ;;
            248) ((cidr+=5)) ;;
            240) ((cidr+=4)) ;;
            224) ((cidr+=3)) ;;
            192) ((cidr+=2)) ;;
            128) ((cidr+=1)) ;;
            0) ;;
            *) print_warning "Unexpected netmask octet: $octet" ;;
        esac
    done

    echo "$cidr"
}

# ============================================================================
# Migration Execution
# ============================================================================

# Perform the migration for all interfaces
perform_migration() {
    print_info "Starting migration..."
    echo ""

    # Get list of interfaces
    local interfaces=$(get_interface_list | sort -u)

    if [[ -z "$interfaces" ]]; then
        print_warning "No interfaces found to migrate."
        return 1
    fi

    print_info "Found interfaces to migrate:"
    for iface in $interfaces; do
        echo "            - $iface"
    done
    echo ""

    # Pre-load stanzas for performance (avoids N+1 file reads)
    populate_stanza_cache "$interfaces"

    # Track bridge ports to avoid duplicate processing
    declare -A bridge_ports_map

    # First pass: identify bridges and their ports
    for iface in $interfaces; do
        local config_inet=$(parse_interface_config "$iface")

        if echo "$config_inet" | grep -qi "^bridge_ports"; then
            local ports=$(echo "$config_inet" | grep -i "^bridge_ports" | cut -d: -f2- | xargs)
            for port in $ports; do
                bridge_ports_map["$port"]="$iface"
            done
        fi
    done

    # Second pass: generate configuration files
    for iface in $interfaces; do
        print_info "Processing interface: $iface"

        # Check if this interface is a bridge port (handled separately)
        if [[ -n "${bridge_ports_map[$iface]:-}" ]]; then
            local bridge="${bridge_ports_map[$iface]}"
            print_info "  - $iface is a member of bridge $bridge, generating port config"

            local port_file="${NETWORKD_DIR}/${PRIORITY_STANDARD}-${iface}.network"
            local port_content=$(generate_bridge_port_network "$iface" "$bridge")

            write_config_file "$port_file" "$port_content" "network" || return 1
            continue
        fi

        # Get inet configuration
        local config_inet=$(parse_interface_config "$iface")

        # Try to get inet6 configuration
        local config_inet6=""
        # ifquery doesn't have a direct way to query inet6, check original stanza
        if grep -qE "^[[:space:]]*iface[[:space:]]+${iface}[[:space:]]+inet6" "$INTERFACES_FILE" 2>/dev/null; then
            # Extract inet6 info from original stanza
            local in_inet6=false
            while IFS= read -r line; do
                if [[ "$line" =~ ^[[:space:]]*iface[[:space:]]+"$iface"[[:space:]]+inet6 ]]; then
                    in_inet6=true
                    # Extract method
                    local method6=$(echo "$line" | awk '{print $4}')
                    config_inet6+="method: $method6"$'\n'
                    continue
                fi
                if [[ "$in_inet6" == true ]]; then
                    if [[ "$line" =~ ^[[:space:]]+([^[:space:]]+)[[:space:]]+(.*) ]]; then
                        local key="${BASH_REMATCH[1]}"
                        local val="${BASH_REMATCH[2]}"
                        config_inet6+="$key: $val"$'\n'
                    elif [[ ! "$line" =~ ^[[:space:]] ]]; then
                        in_inet6=false
                    fi
                fi
            done < "$INTERFACES_FILE"
        fi

        # Check for unsupported configurations
        check_unsupported_config "$iface" "$config_inet"
        if [[ -n "$config_inet6" ]]; then
            check_unsupported_config "$iface" "$config_inet6"
        fi

        # Determine if this is a bridge
        local is_bridge=false
        local priority=$PRIORITY_STANDARD

        if echo "$config_inet" | grep -qi "^bridge_ports"; then
            is_bridge=true
            priority=$PRIORITY_BRIDGE

            # Create .netdev file for bridge
            local netdev_file="${NETWORKD_DIR}/${priority}-${iface}.netdev"
            local netdev_content=$(generate_bridge_netdev "$iface")

            write_config_file "$netdev_file" "$netdev_content" "netdev" || return 1
        fi

        # Generate .network file
        local network_file="${NETWORKD_DIR}/${priority}-${iface}.network"
        local network_content=$(generate_network_file "$iface" "$config_inet" "$config_inet6")

        write_config_file "$network_file" "$network_content" "network" || return 1

        echo ""
    done

    return 0
}

# ============================================================================
# Service Management
# ============================================================================

# Install systemd-resolved if not present
install_systemd_resolved() {
    if ! is_package_installed "systemd-resolved"; then
        print_info "Installing systemd-resolved..."
        if apt update && apt install systemd-resolved; then
            print_success "✓ systemd-resolved installed"
        else
            print_warning "Could not install systemd-resolved - DNS resolution may need manual configuration"
            return 1
        fi
    else
        print_success "✓ systemd-resolved is already installed"
    fi
    return 0
}

# Configure resolv.conf symlink
configure_resolv_conf() {
    echo ""
    print_info "systemd-resolved provides a local DNS stub resolver."
    print_info "To use it, /etc/resolv.conf should be a symlink to $RESOLVED_STUB"
    echo ""

    if [[ -L "$RESOLV_CONF" ]]; then
        local current_target=$(readlink -f "$RESOLV_CONF")
        if [[ "$current_target" == "$RESOLVED_STUB" || "$current_target" == "/run/systemd/resolve/stub-resolv.conf" ]]; then
            print_success "✓ $RESOLV_CONF is already symlinked to systemd-resolved"
            return 0
        fi
    fi

    if prompt_yes_no "Symlink $RESOLV_CONF to systemd-resolved stub?" "y"; then
        # Verify stub file exists (systemd-resolved must be running)
        if [[ ! -e "$RESOLVED_STUB" ]]; then
            print_warning "systemd-resolved stub not found: $RESOLVED_STUB"
            print_warning "Ensure systemd-resolved is running before symlinking"
            print_warning "⚠ Skipped resolv.conf symlink - DNS may need manual configuration"
            return 0
        fi

        backup_file "$RESOLV_CONF"
        rm -f "$RESOLV_CONF"

        if ! ln -s "$RESOLVED_STUB" "$RESOLV_CONF"; then
            print_error "Failed to create symlink: $RESOLV_CONF -> $RESOLVED_STUB"
            # Restore from backup
            local latest_backup
            latest_backup=$(ls -t "${RESOLV_CONF}.backup."*.bak 2>/dev/null | head -1)
            if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
                cp -p "$latest_backup" "$RESOLV_CONF"
                print_info "Restored $RESOLV_CONF from backup"
            fi
            return 1
        fi

        RESOLV_CONF_SYMLINKED=true
        print_success "✓ Created symlink: $RESOLV_CONF -> $RESOLVED_STUB"
    else
        print_warning "⚠ Skipped resolv.conf symlink - DNS may need manual configuration"
    fi
}

# Stop and disable old networking services
disable_old_networking() {
    print_info "Disabling old networking services..."
    echo ""

    # Check and disable networking.service (ifupdown)
    if systemctl is-active networking.service &>/dev/null || systemctl is-enabled networking.service &>/dev/null 2>&1; then
        print_info "Stopping and disabling networking.service..."
        systemctl stop networking.service 2>/dev/null || true
        systemctl disable networking.service 2>/dev/null || true
        print_success "✓ networking.service stopped and disabled"
    else
        print_info "networking.service is not active/enabled"
    fi

    # Check and disable NetworkManager
    if systemctl is-active NetworkManager.service &>/dev/null || systemctl is-enabled NetworkManager.service &>/dev/null 2>&1; then
        print_info "Stopping and disabling NetworkManager.service..."
        systemctl stop NetworkManager.service 2>/dev/null || true
        systemctl disable NetworkManager.service 2>/dev/null || true
        print_success "✓ NetworkManager.service stopped and disabled"
    else
        print_info "NetworkManager.service is not active/enabled"
    fi
}

# Enable and start systemd-networkd services
enable_systemd_networkd() {
    print_info "Enabling systemd-networkd services..."
    echo ""

    # Enable and start systemd-networkd
    if systemctl enable systemd-networkd.service 2>/dev/null; then
        print_success "✓ systemd-networkd.service enabled"
    else
        print_error "Failed to enable systemd-networkd.service"
        return 1
    fi

    if systemctl start systemd-networkd.service 2>/dev/null; then
        print_success "✓ systemd-networkd.service started"
    else
        print_warning "Could not start systemd-networkd.service - may require reboot"
    fi

    # Enable and start systemd-resolved
    if systemctl enable systemd-resolved.service 2>/dev/null; then
        print_success "✓ systemd-resolved.service enabled"
    else
        print_error "Failed to enable systemd-resolved.service"
        return 1
    fi

    if systemctl start systemd-resolved.service 2>/dev/null; then
        print_success "✓ systemd-resolved.service started"
    else
        print_warning "Could not start systemd-resolved.service - may require reboot"
    fi

    return 0
}

# Verify systemd-networkd has configured interfaces
# Returns: 0 if interfaces are configured, 1 otherwise
verify_network_connectivity() {
    local max_attempts=5
    local wait_seconds=2

    print_info "Verifying systemd-networkd configuration..."

    for ((i=1; i<=max_attempts; i++)); do
        sleep "$wait_seconds"

        # Check systemd-networkd is active
        if ! systemctl is-active --quiet systemd-networkd.service; then
            if [[ $i -lt $max_attempts ]]; then
                print_info "Waiting for systemd-networkd to become active... ($i/$max_attempts)"
                continue
            fi
            print_error "systemd-networkd is not active"
            return 1
        fi

        # Check for interfaces in routable/configured state via networkctl
        local networkctl_output configured_count
        networkctl_output=$(networkctl --no-pager --no-legend 2>/dev/null)
        configured_count=$(echo "$networkctl_output" | awk '$4 == "routable" || $4 == "configured" {count++} END {print count+0}')

        if [[ "$configured_count" -gt 0 ]]; then
            print_success "✓ systemd-networkd has $configured_count configured interface(s)"
            # Show interface status for verification
            echo "$networkctl_output" | while read -r idx name type state; do
                if [[ "$state" == "routable" || "$state" == "configured" ]]; then
                    print_info "  - $name: $state"
                fi
            done
            return 0
        fi

        if [[ $i -lt $max_attempts ]]; then
            print_info "Waiting for interfaces to be configured... ($i/$max_attempts)"
        fi
    done

    print_error "systemd-networkd verification failed - no interfaces in configured/routable state"
    return 1
}

# Rollback new networking: stop services, delete created files, restore resolv.conf
rollback_new_networking() {
    print_warning "Rolling back to old networking..."

    # Stop and disable systemd-networkd
    systemctl stop systemd-networkd.service 2>/dev/null || true
    systemctl disable systemd-networkd.service 2>/dev/null || true

    # Stop and disable systemd-resolved
    systemctl stop systemd-resolved.service 2>/dev/null || true
    systemctl disable systemd-resolved.service 2>/dev/null || true

    # Delete created network config files
    local deleted_count=0
    for file in "${CREATED_NETWORK_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            print_info "  Removed $file"
            ((deleted_count++))
        fi
    done
    for file in "${CREATED_NETDEV_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            print_info "  Removed $file"
            ((deleted_count++))
        fi
    done

    if [[ $deleted_count -gt 0 ]]; then
        print_info "  Removed $deleted_count config file(s)"
    fi

    # Restore resolv.conf from backup if we symlinked it
    if [[ "$RESOLV_CONF_SYMLINKED" == true ]]; then
        local latest_backup
        latest_backup=$(ls -t "${RESOLV_CONF}.backup."*.bak 2>/dev/null | head -1)
        if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
            rm -f "$RESOLV_CONF"
            cp -p "$latest_backup" "$RESOLV_CONF"
            print_info "  Restored $RESOLV_CONF from backup"
        fi
    fi

    print_success "✓ Rolled back to old networking"
}

# ============================================================================
# Rollback Instructions
# ============================================================================

# Print rollback instructions at the end
print_rollback_instructions() {
    echo ""
    print_summary "─── Rollback Instructions ───────────────────────────────────────────"
    echo ""
    print_info "If you need to revert to ifupdown, follow these steps:"
    echo ""

    echo "            1. Restore the original interfaces file:"
    if [[ -n "$INTERFACES_BACKUP_PATH" ]]; then
        echo "               cp '$INTERFACES_BACKUP_PATH' '$INTERFACES_FILE'"
    else
        echo "               (Restore from your backup)"
    fi
    echo ""

    echo "            2. Remove created systemd-networkd files:"
    for file in "${CREATED_NETWORK_FILES[@]}"; do
        echo "               rm '$file'"
    done
    for file in "${CREATED_NETDEV_FILES[@]}"; do
        echo "               rm '$file'"
    done
    echo ""

    echo "            3. Disable systemd-networkd services:"
    echo "               systemctl disable --now systemd-networkd.service"
    echo "               systemctl disable --now systemd-resolved.service"
    echo ""

    echo "            4. Re-enable ifupdown networking:"
    echo "               systemctl enable networking.service"
    echo "               systemctl start networking.service"
    echo ""

    if [[ "$RESOLV_CONF_SYMLINKED" == true ]]; then
        echo "            5. Restore resolv.conf:"
        echo "               rm '$RESOLV_CONF'"
        echo "               (Restore from backup or recreate manually)"
        echo ""
    fi

    print_summary "─────────────────────────────────────────────────────────────────────"
}

# ============================================================================
# Main Entry Point
# ============================================================================

# Main migration function
migrate_to_systemd_networkd() {
    print_info "=== Migrate ifupdown to systemd-networkd ==="
    echo ""

    # Check preconditions
    if ! check_migration_preconditions; then
        return 1
    fi
    echo ""

    # Backup interfaces file
    print_info "Backing up current configuration..."
    backup_file "$INTERFACES_FILE"
    # Find the backup path from the global array
    for backup in "${CREATED_BACKUP_FILES[@]}"; do
        if [[ "$backup" == "${INTERFACES_FILE}"* ]]; then
            INTERFACES_BACKUP_PATH="$backup"
            break
        fi
    done
    echo ""

    # Perform migration
    if ! perform_migration; then
        print_error "Migration failed"
        return 1
    fi

    # Warn about unsupported configurations
    if [[ ${#UNSUPPORTED_FOUND[@]} -gt 0 ]]; then
        echo ""
        print_warning "═══════════════════════════════════════════════════════════════════════"
        print_warning "The following configurations are NOT automatically migrated:"
        print_warning "═══════════════════════════════════════════════════════════════════════"
        for item in "${UNSUPPORTED_FOUND[@]}"; do
            echo "            ⚠ $item"
        done
        echo ""
        print_warning "These configurations will need to be added manually to the generated"
        print_warning ".network files. Refer to systemd.network(5) man page for syntax."
        print_warning "═══════════════════════════════════════════════════════════════════════"
        echo ""
        if ! prompt_yes_no "Continue with migration anyway?" "n"; then
            print_info "Migration cancelled. Generated files have been created but services not switched."
            print_info "You can review the files in $NETWORKD_DIR and re-run when ready."
            print_rollback_instructions
            return 1
        fi
    fi
    echo ""

    # Install systemd-resolved if needed
    install_systemd_resolved
    echo ""

    # Configure resolv.conf
    configure_resolv_conf
    echo ""

    # Enable new networking FIRST (before disabling old)
    if ! enable_systemd_networkd; then
        print_error "Failed to enable systemd-networkd services"
        print_rollback_instructions
        return 1
    fi

    # Verify connectivity before disabling old networking
    if ! verify_network_connectivity; then
        print_error "New networking failed connectivity test"
        rollback_new_networking
        print_info "Old networking remains active"
        print_rollback_instructions
        return 1
    fi
    echo ""

    # Only NOW disable old networking (new is verified working)
    disable_old_networking
    echo ""

    print_success "═══════════════════════════════════════════════════════════════════════"
    print_success "Migration complete!"
    print_success "═══════════════════════════════════════════════════════════════════════"
    echo ""
    print_info "Created files:"
    for file in "${CREATED_NETWORK_FILES[@]}"; do
        echo "            ✓ $file"
    done
    for file in "${CREATED_NETDEV_FILES[@]}"; do
        echo "            ✓ $file"
    done

    print_rollback_instructions

    return 0
}

# Main entry point with user prompt
main_migrate_to_systemd_networkd() {
    detect_environment

    # Only applicable on Linux
    if [[ "$DETECTED_OS" != "linux" ]]; then
        return 0
    fi

    # Check if ifupdown is in use
    if [[ ! -f "$INTERFACES_FILE" ]]; then
        print_info "No $INTERFACES_FILE found - skipping network migration."
        return 0
    fi

    # Check if ifquery is available
    if ! command -v ifquery &>/dev/null; then
        return 0
    fi

    # Check if there are non-loopback interfaces
    if ! grep -qE "^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+" "$INTERFACES_FILE" 2>/dev/null || \
       ! grep -E "^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+" "$INTERFACES_FILE" 2>/dev/null | grep -qvE "[[:space:]]lo([[:space:]]|$)"; then
        return 0
    fi

    print_info "=== Network Configuration Migration ==="
    print_info "This system appears to use ifupdown (/etc/network/interfaces)."
    print_info "You can migrate to systemd-networkd for modern network management."
    echo ""

    if prompt_yes_no "Migrate from ifupdown to systemd-networkd?" "n"; then
        echo ""
        migrate_to_systemd_networkd
    else
        print_info "Skipping network migration."
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_migrate_to_systemd_networkd "$@"
fi
