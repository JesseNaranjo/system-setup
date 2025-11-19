#!/usr/bin/env bash

# system-configuration-openssh-server.sh - Configure OpenSSH Server
# Part of the system-setup suite
#
# This script:
# - Configures SSH to use socket-based activation instead of service
# - Provides option to customize ssh.socket configuration

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# SSH Configuration
# ============================================================================

# Configure SSH to use socket-based activation instead of service
configure_ssh_socket() {
    # SSH socket configuration is only relevant for Linux systems with systemd
    if [[ "$DETECTED_OS" != "linux" ]]; then
        print_info "SSH socket configuration is only applicable to Linux systems with systemd"
        return 0
    fi

    # Check if systemd is available
    if ! command -v systemctl &>/dev/null; then
        print_warning "systemctl not found - cannot configure SSH socket (systemd required)"
        return 0
    fi

    print_info "Checking OpenSSH Server configuration..."

    # Check current state of ssh.service and ssh.socket
    local ssh_service_enabled=false
    local ssh_socket_enabled=false

    if systemctl is-enabled ssh.service &>/dev/null; then
        ssh_service_enabled=true
    fi

    if systemctl is-enabled ssh.socket &>/dev/null; then
        ssh_socket_enabled=true
    fi

    # Case 1: Both ssh.socket and ssh.service are enabled
    # Action: Disable ssh.service (no prompt needed - this is a misconfiguration)
    if [[ "$ssh_socket_enabled" == true && "$ssh_service_enabled" == true ]]; then
        print_warning "Both ssh.socket and ssh.service are enabled (conflicting configuration)"
        print_info "Disabling ssh.service to avoid conflicts..."
        if systemctl disable --now ssh.service 2>/dev/null; then
            print_success "✓ ssh.service disabled and stopped"
            print_success "✓ SSH is now using socket-based activation only"
        else
            print_error "Could not disable ssh.service"
            return 1
        fi
        return 0
    fi

    # Case 2: ssh.socket is already enabled and ssh.service is disabled
    # Action: Nothing to do
    if [[ "$ssh_socket_enabled" == true ]]; then
        print_success "- SSH is already using socket-based activation (ssh.socket)"
        return 0
    fi

    # Case 3: ssh.socket is disabled (regardless of ssh.service state)
    # Action: Prompt user to configure ssh.socket
    print_info "Configuring OpenSSH Server..."
    if [[ "$ssh_service_enabled" == true ]]; then
        print_info "- Current state: ssh.service is enabled (traditional service-based activation)"
    else
        print_info "- Current state: SSH is not currently enabled via socket or service"
    fi

    echo ""
    print_info "Socket-based activation (ssh.socket) vs Service-based (ssh.service):"
    echo "          • ssh.socket: Starts SSH daemon on-demand when connections arrive (saves resources)"
    echo "          • ssh.service: Keeps SSH daemon running constantly (traditional approach)"
    echo ""

    if ! prompt_yes_no "          Would you like to configure and enable ssh.socket?" "y"; then
        print_info "Keeping current SSH configuration (no changes made)"
        return 0
    fi

    echo ""
    print_info "Configuring socket-based SSH activation..."

    # Disable and stop ssh.service if it's enabled
    if [[ "$ssh_service_enabled" == true ]]; then
        print_info "Disabling ssh.service..."
        if systemctl disable --now ssh.service 2>/dev/null; then
            print_success "✓ ssh.service disabled and stopped"
        else
            print_warning "Could not disable ssh.service (it may not be active)"
        fi
    fi

    # Open editor for ssh.socket configuration
    echo ""
    echo -e "${YELLOW}╔═════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║                                                                             ║${NC}"
    echo -e "${YELLOW}║        You can customize the socket configuration here.                     ║${NC}"
    echo -e "${YELLOW}║        Examples: change port, add ListenStream, etc.                        ║${NC}"
    echo -e "${YELLOW}║                                                                             ║${NC}"
    echo -e "${YELLOW}║        nano will open for manual configuration and adjustment.              ║${NC}"
    echo -e "${YELLOW}║                                                                             ║${NC}"
    echo -e "${YELLOW}╚═════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -n 1 -s -r -p "Press any key to open nano and configure ssh.socket..."
    echo ""

    if systemctl edit ssh.socket; then
        print_success "✓ ssh.socket configuration saved"
    else
        print_error "Failed to edit ssh.socket configuration"
        return 1
    fi
    echo ""

    # Enable and start ssh.socket
    print_info "Enabling and starting ssh.socket..."
    if systemctl enable --now ssh.socket; then
        print_success "✓ ssh.socket enabled and started"
        echo ""

        # Show status
        print_info "Current SSH socket status:"
        systemctl status ssh.socket --no-pager --lines=10 || true
    else
        print_error "Failed to enable ssh.socket"
        return 1
    fi
    echo ""

    print_info "SSH socket configuration complete"
    print_info "- SSH daemon will now start automatically when connections arrive"
}

# ============================================================================
# Main Execution
# ============================================================================

main_configure_openssh_server() {
    # Detect OS if not already detected
    if [[ -z "$DETECTED_OS" ]]; then
        detect_os
    fi

    configure_ssh_socket
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_openssh_server "$@"
fi
