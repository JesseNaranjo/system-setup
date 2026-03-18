#!/usr/bin/env bash

# install-desktop.sh - Install and configure TigerVNC and XRDP desktop access
#
# Usage: ./install-desktop.sh
#
# This script:
# - Installs and configures TigerVNC for VNC access
# - Installs and configures XRDP for RDP access
# - Configures XFCE4 as the desktop environment
# - Generates TLS certificates for XRDP
# - Optionally removes unnecessary packages
#
# Must be run as the target user (not root). Uses sudo for root operations.

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    readonly SCRIPT_DIR
fi

# shellcheck source=utils-sys.sh
source "${SCRIPT_DIR}/utils-sys.sh"

# ============================================================================
# TigerVNC Functions
# ============================================================================

prompt_resolution() {
    # All display output goes to /dev/tty so that only the result
    # is captured when called via geometry=$(prompt_resolution)
    print_info "Select VNC display resolution:" >/dev/tty
    echo "            1) 1280x720   (720p / HD)" >/dev/tty
    echo "            2) 1366x768   (WXGA)" >/dev/tty
    echo "            3) 1600x900   (HD+)" >/dev/tty
    echo "            4) 1920x1080  (1080p / Full HD)" >/dev/tty
    echo "            5) 1920x1200  (WUXGA)" >/dev/tty
    echo "            6) 2560x1440  (QHD / 2K)" >/dev/tty
    echo "" >/dev/tty

    local choice
    read -p "            Enter choice (1-6) [4]: " -r choice </dev/tty

    case "${choice:-4}" in
        1) echo "1280x720" ;;
        2) echo "1366x768" ;;
        3) echo "1600x900" ;;
        4) echo "1920x1080" ;;
        5) echo "1920x1200" ;;
        6) echo "2560x1440" ;;
        *) echo "1920x1080" ;;
    esac
}

install_tigervnc_packages() {
    local packages=("tigervnc-standalone-server" "xfce4" "xfce4-terminal" "dbus-x11")
    local missing_packages=()

    for pkg in "${packages[@]}"; do
        if is_package_installed "$pkg"; then
            print_success "- ${pkg} already installed"
        else
            missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        return 0
    fi

    sudo apt update
    print_info "Installing TigerVNC packages: ${missing_packages[*]}"
    sudo apt install -y "${missing_packages[@]}"
    invalidate_package_cache
    print_success "✓ TigerVNC packages installed"
}

configure_tigervnc() {
    local config_dir="${HOME}/.config/tigervnc"
    local config_file="${config_dir}/config"
    local xstartup_dir="${HOME}/.vnc"
    local xstartup_file="${xstartup_dir}/xstartup"
    local passwd_file="${xstartup_dir}/passwd"
    local vncserver_users="/etc/tigervnc/vncserver.users"

    # --- TigerVNC config file ---
    local config_correct=true
    if [[ -f "$config_file" ]]; then
        for setting in "session=xfce" "depth=24" "securitytypes=VncAuth" "localhost=no" "alwaysshared"; do
            if ! grep -qF "$setting" "$config_file" 2>/dev/null; then
                config_correct=false
                break
            fi
        done
        if ! grep -q "^geometry=" "$config_file" 2>/dev/null; then
            config_correct=false
        fi
    else
        config_correct=false
    fi

    if [[ "$config_correct" == true ]]; then
        local current_geometry
        current_geometry=$(grep "^geometry=" "$config_file" | cut -d= -f2)
        print_success "- TigerVNC config already up-to-date (${current_geometry})"
    else
        local geometry
        geometry=$(prompt_resolution)

        mkdir -p "$config_dir"
        [[ -f "$config_file" ]] && backup_file "$config_file"
        cat > "$config_file" <<EOF
session=xfce
geometry=${geometry}
depth=24
securitytypes=VncAuth
localhost=no
alwaysshared
EOF
        print_success "✓ TigerVNC config created: ${config_file} (${geometry})"
    fi

    # --- xstartup script ---
    local desired_xstartup
    desired_xstartup=$(cat <<'XSTART'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
vncconfig -iconic &
exec dbus-launch --exit-with-session xfce4-session
XSTART
)

    if [[ -f "$xstartup_file" ]] && [[ "$(cat "$xstartup_file")" == "$desired_xstartup" ]]; then
        print_success "- VNC xstartup already up-to-date"
    else
        mkdir -p "$xstartup_dir"
        [[ -f "$xstartup_file" ]] && backup_file "$xstartup_file"
        echo "$desired_xstartup" > "$xstartup_file"
        chmod +x "$xstartup_file"
        print_success "✓ VNC xstartup created: ${xstartup_file}"
    fi

    # --- VNC password ---
    if [[ -f "$passwd_file" ]]; then
        print_success "- VNC password already configured"
    else
        print_info "Set VNC password for ${USER}:"
        if vncpasswd; then
            print_success "✓ VNC password configured"
        else
            print_warning "⚠ VNC password setup skipped or failed"
        fi
    fi

    # --- vncserver.users mapping ---
    local desired_mapping=":1=${USER}"
    if sudo grep -qF "$desired_mapping" "$vncserver_users" 2>/dev/null; then
        print_success "- VNC user mapping already configured"
    else
        sudo mkdir -p "$(dirname "$vncserver_users")"
        sudo tee "$vncserver_users" > /dev/null <<EOF
${desired_mapping}
EOF
        print_success "✓ VNC user mapping created: ${vncserver_users}"
    fi
}

enable_tigervnc_service() {
    local service="tigervncserver@:1.service"

    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        print_success "- ${service} already enabled"
    else
        sudo systemctl enable --now "$service"
        print_success "✓ ${service} enabled and started"
    fi
}

setup_tigervnc() {
    print_info "── TigerVNC ─────────────────────────────────────────────────"
    echo ""

    if ! is_package_installed "tigervnc-standalone-server"; then
        if ! prompt_yes_no "Install TigerVNC?" "n"; then
            print_info "Skipped TigerVNC installation"
            echo ""
            return 0
        fi
    fi
    install_tigervnc_packages

    echo ""
    configure_tigervnc
    echo ""
    enable_tigervnc_service
    echo ""
}

# ============================================================================
# XRDP Functions
# ============================================================================

install_xrdp_packages() {
    local packages=("xrdp" "xorgxrdp" "xfce4" "xfce4-terminal" "dbus-x11")
    local missing_packages=()

    for pkg in "${packages[@]}"; do
        if is_package_installed "$pkg"; then
            print_success "- ${pkg} already installed"
        else
            missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        return 0
    fi

    sudo apt update
    print_info "Installing XRDP packages: ${missing_packages[*]}"
    sudo apt install -y "${missing_packages[@]}"
    invalidate_package_cache
    print_success "✓ XRDP packages installed"
}

configure_xrdp_ssl_cert_group() {
    if groups xrdp 2>/dev/null | grep -qw ssl-cert; then
        print_success "- xrdp user already in ssl-cert group"
    else
        sudo adduser xrdp ssl-cert
        print_success "✓ Added xrdp user to ssl-cert group"
    fi
}

configure_xrdp_startwm() {
    local startwm="/etc/xrdp/startwm.sh"

    if sudo grep -q "exec startxfce4" "$startwm" 2>/dev/null; then
        print_success "- startwm.sh already configured for XFCE"
        return 0
    fi

    # Backup before modifying
    local backup
    backup="${startwm}.backup.$(date +%Y%m%d_%H%M%S).bak"
    sudo cp -p "$startwm" "$backup"
    print_backup "- Created backup: ${backup}"

    # Comment out default Xsession lines
    sudo sed -i 's|^test -x /etc/X11/Xsession|# & # Replaced by install-desktop.sh|' "$startwm"
    sudo sed -i 's|^exec /bin/sh /etc/X11/Xsession|# & # Replaced by install-desktop.sh|' "$startwm"

    # Append XFCE startup
    sudo tee -a "$startwm" > /dev/null <<'EOF'

# XFCE desktop session - managed by install-desktop.sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
EOF

    print_success "✓ startwm.sh configured for XFCE"
}

configure_xrdp_xsession() {
    local xsession_file="${HOME}/.xsession"
    local desired_content="xfce4-session"

    if [[ -f "$xsession_file" ]] && [[ "$(cat "$xsession_file")" == "$desired_content" ]]; then
        print_success "- .xsession already configured"
        return 0
    fi

    [[ -f "$xsession_file" ]] && backup_file "$xsession_file"
    echo "$desired_content" > "$xsession_file"
    print_success "✓ .xsession created for XRDP"
}

configure_xrdp_certificates() {
    local cert_dir="/etc/xrdp/certs"
    local cert_file="${cert_dir}/cert.pem"
    local key_file="${cert_dir}/key.pem"

    if sudo test -f "$cert_file" && sudo test -f "$key_file"; then
        # Check if cert expires within 30 days (2592000 seconds)
        if sudo openssl x509 -checkend 2592000 -noout -in "$cert_file" 2>/dev/null; then
            print_success "- XRDP TLS certificate is valid (not expiring within 30 days)"
            return 0
        else
            print_warning "⚠ XRDP TLS certificate expires within 30 days"
            if ! prompt_yes_no "Renew XRDP TLS certificate?" "y"; then
                print_info "Skipped certificate renewal"
                return 0
            fi
        fi
    fi

    sudo mkdir -p "$cert_dir"
    sudo openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$key_file" -out "$cert_file" \
        -days 365 -subj "/CN=$(hostname)"
    sudo chown xrdp:xrdp "$cert_dir" "$cert_file" "$key_file"
    sudo chmod 0600 "$key_file"
    print_success "✓ XRDP TLS certificate generated (valid for 365 days)"
}

configure_xrdp_ini() {
    local ini_file="/etc/xrdp/xrdp.ini"
    local needs_update=false

    # Parallel arrays for settings (associative arrays have non-deterministic order)
    local -a setting_keys=("security_layer" "certificate" "key_file" "ssl_protocols")
    local -a setting_vals=("tls" "/etc/xrdp/certs/cert.pem" "/etc/xrdp/certs/key.pem" "TLSv1.2, TLSv1.3")

    for i in "${!setting_keys[@]}"; do
        local key="${setting_keys[$i]}"
        local val="${setting_vals[$i]}"
        if sudo grep -qF "${key}=${val}" "$ini_file" 2>/dev/null; then
            print_success "- xrdp.ini: ${key} already correct"
        else
            needs_update=true
        fi
    done

    if [[ "$needs_update" == false ]]; then
        return 0
    fi

    # Backup before modifying
    local backup
    backup="${ini_file}.backup.$(date +%Y%m%d_%H%M%S).bak"
    sudo cp -p "$ini_file" "$backup"
    print_backup "- Created backup: ${backup}"

    for i in "${!setting_keys[@]}"; do
        local key="${setting_keys[$i]}"
        local val="${setting_vals[$i]}"
        sudo sed -i "s|^${key}=.*|${key}=${val}|" "$ini_file"
        # Append if key was missing or commented out and sed matched nothing
        if ! sudo grep -qF "${key}=${val}" "$ini_file"; then
            echo "${key}=${val}" | sudo tee -a "$ini_file" > /dev/null
        fi
    done

    print_success "✓ xrdp.ini TLS settings configured"
}

configure_xrdp() {
    configure_xrdp_ssl_cert_group
    configure_xrdp_startwm
    configure_xrdp_xsession
    configure_xrdp_certificates
    configure_xrdp_ini
}

enable_xrdp_service() {
    local service="xrdp"

    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        print_success "- ${service} service already enabled"
    else
        sudo systemctl enable --now "$service"
        print_success "✓ ${service} service enabled and started"
    fi
}

setup_xrdp() {
    print_info "── XRDP ─────────────────────────────────────────────────────"
    echo ""

    if ! is_package_installed "xrdp"; then
        if ! prompt_yes_no "Install XRDP?" "n"; then
            print_info "Skipped XRDP installation"
            echo ""
            return 0
        fi
    fi
    install_xrdp_packages

    echo ""
    configure_xrdp
    echo ""
    enable_xrdp_service
    echo ""
}

# ============================================================================
# Package Cleanup
# ============================================================================

purge_unnecessary_packages() {
    print_info "── Package Cleanup ──────────────────────────────────────────"
    echo ""

    local packages_to_purge=(
        "dosfstools"
        "eject"
        "exfatprogs"
        "gnome-accessibility-themes"
        "gnome-themes-extra"
        "gnome-themes-extra-data"
        "gnupg-utils"
        "ipp-usb"
        "libgpg-error-l10n"
        "libgphoto2-l10n"
        "sane-airscan"
        "sane-utils"
        "usbmuxd"
        "xserver-xorg-legacy"
    )

    local installed_packages=()
    for pkg in "${packages_to_purge[@]}"; do
        if is_package_installed "$pkg"; then
            installed_packages+=("$pkg")
        fi
    done

    if [[ ${#installed_packages[@]} -eq 0 ]]; then
        print_success "- No unnecessary packages found to remove"
        echo ""
        return 0
    fi

    print_info "Found ${#installed_packages[@]} unnecessary package(s):"
    for pkg in "${installed_packages[@]}"; do
        echo "            - ${pkg}"
    done
    echo ""

    if ! prompt_yes_no "Remove these unnecessary packages?" "y"; then
        print_info "Skipped package cleanup"
        echo ""
        return 0
    fi

    sudo apt purge -y "${installed_packages[@]}"
    sudo apt autoremove -y
    invalidate_package_cache
    print_success "✓ Removed ${#installed_packages[@]} unnecessary package(s)"
    echo ""
}

# ============================================================================
# Main
# ============================================================================

main_install_desktop() {
    detect_environment

    if [[ "$DETECTED_OS" != "linux" ]]; then
        print_error "✖ This script is only supported on Linux"
        exit 1
    fi

    if [[ $EUID -eq 0 ]]; then
        print_error "✖ Run as the target user, not root: ./install-desktop.sh"
        exit 1
    fi

    if ! sudo -v; then
        print_error "✖ Sudo access is required for package installation and service management"
        exit 1
    fi

    print_info "Desktop Environment Setup (TigerVNC + XRDP)"
    echo ""

    setup_tigervnc
    setup_xrdp
    purge_unnecessary_packages
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_install_desktop "$@"
fi
