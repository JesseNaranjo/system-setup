#!/usr/bin/env bash

# system-configuration.sh - System and user configuration
# Part of the system-setup suite
#
# This script:
# - Configures nano editor with sensible defaults and syntax highlighting
# - Configures GNU screen with scrollback and mouse support
# - Configures shell aliases and prompt colors for users

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Nano Configuration
# ============================================================================

get_nano_config_file() {
    local scope="$1"  # "user" or "system"

    if [[ "$scope" == "system" ]]; then
        if [[ "$DETECTED_OS" == "macos" ]]; then
            echo "/opt/homebrew/etc/nanorc"
        else
            echo "/etc/nanorc"
        fi
    else
        echo "$HOME/.nanorc"
    fi
}

# Configure nano
configure_nano() {
    local scope="$1"  # "user" or "system"

    print_info "Configuring nano..."

    local config_file=$(get_nano_config_file "$scope")

    # Create config file if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        print_info "Creating new nano configuration file: $config_file"
        if [[ "$scope" == "system" ]] && [[ "$DETECTED_OS" == "macos" ]] && [[ $EUID -ne 0 ]]; then
            # On macOS with system scope, use sudo to create the file
            run_elevated touch "$config_file"
        else
            touch "$config_file"
        fi
    fi

    # Configure each setting individually
    add_config_if_needed "nano" "$config_file" "set atblanks" "" "atblanks setting"
    add_config_if_needed "nano" "$config_file" "set autoindent" "" "autoindent setting"
    add_config_if_needed "nano" "$config_file" "set constantshow" "" "constantshow setting"
    add_config_if_needed "nano" "$config_file" "set indicator" "" "indicator setting"
    add_config_if_needed "nano" "$config_file" "set linenumbers" "" "line numbers setting"
    add_config_if_needed "nano" "$config_file" "set minibar" "" "minibar setting"
    add_config_if_needed "nano" "$config_file" "set mouse" "" "mouse support setting"
    add_config_if_needed "nano" "$config_file" "set multibuffer" "" "multibuffer setting"
    add_config_if_needed "nano" "$config_file" "set nonewlines" "" "nonewlines setting"
    add_config_if_needed "nano" "$config_file" "set smarthome" "" "smarthome setting"
    add_config_if_needed "nano" "$config_file" "set softwrap" "" "softwrap setting"
    add_config_if_needed "nano" "$config_file" "set tabsize" "4" "tab size setting"

    # Add homebrew include for macOS
    if [[ "$DETECTED_OS" == "macos" ]]; then
        local include_line_pattern='include "\/opt\/homebrew\/share\/nano\/\*\.nanorc"'
        local include_line='include "/opt/homebrew/share/nano/*.nanorc"'

        if ! config_exists "$config_file" "$include_line_pattern"; then
            print_info "+ Adding homebrew nano syntax definitions to $config_file"
            backup_file "$config_file"
            add_change_header "$config_file" "nano"

            {
                echo ""
                echo "# homebrew nano syntax definitions"
                echo "$include_line"
            } | run_elevated tee -a "$config_file" > /dev/null
        else
            print_success "- homebrew nano syntax definitions already configured"
        fi
    fi

    print_success "Nano configuration completed for $config_file"
}

# ============================================================================
# Screen Configuration
# ============================================================================

get_screen_config_file() {
    local scope="$1"  # "user" or "system"

    if [[ "$scope" == "system" ]]; then
        echo "/etc/screenrc"
    else
        echo "$HOME/.screenrc"
    fi
}

# Configure GNU screen
configure_screen() {
    local scope="$1"  # "user" or "system"

    print_info "Configuring GNU screen..."

    local config_file=$(get_screen_config_file "$scope")

    # Create config file if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        print_info "Creating new screen configuration file: $config_file"
        if [[ "$scope" == "system" ]] && [[ "$DETECTED_OS" == "macos" ]] && [[ $EUID -ne 0 ]]; then
            # On macOS with system scope, use sudo to create the file
            run_elevated touch "$config_file"
        else
            touch "$config_file"
        fi
    fi

    # Configure each setting individually
    add_config_if_needed "screen" "$config_file" "startup_message" "off" "startup message setting"
    add_config_if_needed "screen" "$config_file" "defscrollback" "9999" "default scrollback setting"
    add_config_if_needed "screen" "$config_file" "scrollback" "9999" "scrollback setting"
    add_config_if_needed "screen" "$config_file" "defmousetrack" "on" "default mouse tracking setting"
    add_config_if_needed "screen" "$config_file" "mousetrack" "on" "mouse tracking setting"

    print_success "GNU screen configuration completed for $config_file"
}

# ============================================================================
# Shell Configuration
# ============================================================================

# Configure shell prompt colors for system-wide configuration
configure_shell_prompt_colors_system() {
    # Determine shell config file based on OS
    local shell_config
    if [[ "$DETECTED_OS" == "macos" ]]; then
        shell_config="/etc/zshrc"
    else
        shell_config="/etc/bash.bashrc"
    fi

    # Skip if config file doesn't exist
    if [[ ! -f "$shell_config" ]]; then
        print_warning "Shell configuration file $shell_config does not exist, skipping prompt color configuration"
        return 0
    fi

    print_info "Configuring shell prompt colors in $shell_config..."

    # OS-specific custom PS1 patterns
    local ps1_check_patterns=()
    local custom_ps1_pattern
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # macOS zsh prompt
        custom_ps1_pattern="PS1=\"[%F{247}%m%f:%F{%(!.red.green)}%n%f] %B%F{cyan}%~%f%b %#%(!.%F{red}%B!!%b%f.) \""
        ps1_check_patterns=("$custom_ps1_pattern")
    else
        # Linux bash prompt - conditional for root vs non-root
        # We'll use a marker comment to check if it's already configured
        local bash_prompt_root="PS1=\"\${debian_chroot:+(\$debian_chroot)}[\[\e[90m\]\h\[\e[0m\]:\[\e[91m\]\u\[\e[0m\]] \[\e[96;1m\]\w\[\e[0m\] \\$\[\e[91;1m\]!!\[\e[0m\] \""
        local bash_prompt_non_root="PS1=\"\${debian_chroot:+(\$debian_chroot)}[\[\e[90m\]\h\[\e[0m\]:\[\e[92m\]\u\[\e[0m\]] \[\e[96;1m\]\w\[\e[0m\] \\$ \""
        ps1_check_patterns=("$bash_prompt_root" "$bash_prompt_non_root")
        custom_ps1_pattern="
    if [ \"\$EUID\" -eq 0 ]; then
        # Root user - red username with !! warning
        $bash_prompt_root
    else
        # Non-root user - green username
        $bash_prompt_non_root
    fi"
    fi

    # Check if we already have our custom PS1
    local all_patterns_found=true
    for pattern in "${ps1_check_patterns[@]}"; do
        if ! grep -qF "$pattern" "$shell_config" 2>/dev/null; then
            all_patterns_found=false
            break
        fi
    done

    if [[ "$all_patterns_found" == true ]]; then
        print_success "- Custom PS1 prompt already configured"
        return 0
    fi

    # Backup the config file
    backup_file "$shell_config"

    # Check how many PS1 definitions exist
    local ps1_count=$(grep -c "^[[:space:]]*PS1=" "$shell_config" 2>/dev/null || echo "0")

    if [[ "$ps1_count" -eq 0 ]]; then
        # No existing PS1, just add at the end
        add_change_header "$shell_config" "shell"
        {
            echo "# Custom PS1 prompt - managed by system-setup.sh"
            echo "$custom_ps1_pattern"
        } | run_elevated tee -a "$shell_config" > /dev/null
        print_success "✓ Custom PS1 prompt configured in $shell_config"
    elif [[ "$ps1_count" -eq 1 ]]; then
        # Find the line number of the PS1 definition
        local ps1_line_num=$(grep -n "^[[:space:]]*PS1=" "$shell_config" | cut -d: -f1)

        # Comment out the line
        run_elevated sed -i.bak "${ps1_line_num}s/^\([[:space:]]*\)\(PS1=.*\)/\1# \2  # Replaced by system-setup.sh on $(date +%Y-%m-%d)/" "$shell_config" && run_elevated rm -f "${shell_config}.bak"

        # Create a temporary file with the new PS1 content
        local temp_ps1=$(mktemp)
        add_change_header "$temp_ps1" "shell"
        {
            echo "    # Custom PS1 prompt - managed by system-setup.sh"
            echo "$custom_ps1_pattern"
        } > "$temp_ps1"

        # Insert the new content after the commented line
        run_elevated sed -i.bak "${ps1_line_num}r ${temp_ps1}" "$shell_config" && run_elevated rm -f "${shell_config}.bak"
        rm -f "$temp_ps1"

        print_success "✓ Custom PS1 prompt configured in $shell_config"
    else
        # Multiple PS1 definitions - comment them all out, add at end, and prompt user
        print_warning "Found $ps1_count PS1 definitions in $shell_config"

        # Comment out all PS1 lines
        run_elevated sed -i.bak "s/^\([[:space:]]*\)\(PS1=.*\)/\1# \2  # Replaced by system-setup.sh on $(date +%Y-%m-%d)/" "$shell_config" && run_elevated rm -f "${shell_config}.bak"

        # Add new PS1 at the end
        add_change_header "$shell_config" "shell"
        {
            echo "# Custom PS1 prompt - managed by system-setup.sh"
            echo "$custom_ps1_pattern"
        } | run_elevated tee -a "$shell_config" > /dev/null

        # Provide instructions and wait
        echo ""
        echo -e "            ${YELLOW}╔═════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║        Multiple PS1 definitions were found and commented out.               ║${NC}"
        echo -e "            ${YELLOW}║        The new PS1 has been added at the end of the file.                   ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║        Please review the file to ensure proper placement.                   ║${NC}"
        echo -e "            ${YELLOW}║        nano will open for manual verification and adjustment.               ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}╚═════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -n 1 -s -r -p "Press any key to open nano and review $shell_config..."
        echo ""

        # Open nano for user to review/edit
        run_elevated nano "$shell_config"

        print_success "✓ File reviewed and saved"
    fi
}

# Comment out PS1 definitions in user config files (system scope only)
configure_shell_prompt_colors_user() {
    local home_dir="$1"
    local username="$2"

    # Skip if home directory doesn't exist
    if [[ ! -d "$home_dir" ]]; then
        return 0
    fi

    # Determine shell config file based on OS
    local shell_config
    if [[ "$DETECTED_OS" == "macos" ]]; then
        shell_config="${home_dir}/.zshrc"
    else
        shell_config="${home_dir}/.bashrc"
    fi

    # Skip if config file doesn't exist
    if [[ ! -f "$shell_config" ]]; then
        return 0
    fi

    # Check if there are any uncommented PS1 definitions that we would actually modify
    local has_ps1_to_comment=false
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # macOS: Check for ANY PS1 definitions
        if grep -q "^[[:space:]]*PS1=" "$shell_config" 2>/dev/null; then
            has_ps1_to_comment=true
        fi
    else
        # Linux: Check for PS1 definitions EXCEPT terminal title ones (PS1="\[\e]0;)
        if grep "^[[:space:]]*PS1=" "$shell_config" 2>/dev/null | grep -qv "^[[:space:]]*PS1=\"\\\\\[\\\\e\]0;"; then
            has_ps1_to_comment=true
        fi
    fi

    # Skip if no PS1 definitions to comment out
    if [[ "$has_ps1_to_comment" != true ]]; then
        # No uncommented PS1 definitions found (or only terminal title ones on Linux)
        return 0
    fi

    print_info "Commenting out PS1 definitions in $shell_config (user: $username)..."

    # Backup the config file
    backup_file "$shell_config"

    # Comment out existing PS1 definitions with OS-specific rules
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # macOS: Comment out ALL PS1 definitions
        run_elevated sed -i.bak "s/^\([[:space:]]*\)\(PS1=.*\)/\1# \2  # Commented out by system-setup.sh on $(date +%Y-%m-%d)/" "$shell_config" && run_elevated rm -f "${shell_config}.bak"
    else
        # Linux: Comment out all PS1 definitions EXCEPT those starting with: PS1="\[\e]0;
        # This preserves the terminal title escape sequences
        run_elevated sed -i.bak "/^[[:space:]]*PS1=\"\\\\\[\\\\e\]0;/! s/^\([[:space:]]*\)\(PS1=.*\)/\1# \2  # Commented out by system-setup.sh on $(date +%Y-%m-%d)/" "$shell_config" && run_elevated rm -f "${shell_config}.bak"
    fi

    # Restore ownership if running as root
    if [[ $EUID -eq 0 ]] && [[ "$username" != "root" ]]; then
        chown "$username:$username" "$shell_config" 2>/dev/null || true
    fi

    print_success "✓ PS1 definitions commented out in $shell_config"
}

# Configure shell for a specific user
configure_shell_for_user() {
    local home_dir="$1"
    local username="$2"

    # Determine shell config file
    local shell_config
    if [[ "$DETECTED_OS" == "macos" ]]; then
        shell_config="${home_dir}/.zshrc"
    else
        shell_config="${home_dir}/.bashrc"
    fi

    # Skip if home directory doesn't exist or is not accessible
    if [[ ! -d "$home_dir" ]]; then
        print_warning "Home directory $home_dir does not exist, skipping user $username"
        return 0
    fi

    # Create config file if it doesn't exist
    if [[ ! -f "$shell_config" ]]; then
        print_info "Creating new shell configuration file: $shell_config (user: $username)"
        touch "$shell_config"
        # Set proper ownership if running as root
        if [[ $EUID -eq 0 ]] && [[ "$username" != "root" ]]; then
            chown "$username:$username" "$shell_config" 2>/dev/null || true
        fi
    fi

    # Configure safety aliases
    if ! grep -q "Aliases to help avoid some mistakes" "$shell_config" 2>/dev/null; then
        backup_file "$shell_config"
        add_change_header "$shell_config" "shell"

        echo "" >> "$shell_config"
        echo "# Aliases to help avoid some mistakes:" >> "$shell_config"
    fi

    add_alias_if_needed "$shell_config" "cp" "cp -aiv" "copy with attributes and interactive"
    add_alias_if_needed "$shell_config" "mkdir" "mkdir -v" "verbose mkdir"
    add_alias_if_needed "$shell_config" "mv" "mv -iv" "interactive move"
    add_alias_if_needed "$shell_config" "rm" "rm -Iv" "interactive remove"

    if ! grep -q "verbose chmod" "$shell_config" 2>/dev/null; then
        echo "" >> "$shell_config"
    fi
    add_alias_if_needed "$shell_config" "chmod" "chmod -vv" "verbose chmod"
    add_alias_if_needed "$shell_config" "chown" "chown -vv" "verbose chown"

    # OS-specific ls configuration
    if [[ "$DETECTED_OS" == "macos" ]]; then
        if ! grep -q "macOS ls configuration" "$shell_config" 2>/dev/null; then
            echo "" >> "$shell_config"
            echo "# macOS ls configuration" >> "$shell_config"
        fi
        add_export_if_needed "$shell_config" "CLICOLOR" "YES" "terminal colors"
        add_alias_if_needed "$shell_config" "ls" "ls -AFGHhl" "macOS ls with colors and formatting"
    else
        if ! grep -q "Linux ls configuration" "$shell_config" 2>/dev/null; then
            echo "" >> "$shell_config"
            echo "# Linux ls configuration" >> "$shell_config"
        fi
        add_alias_if_needed "$shell_config" "ls" "ls --color=auto --group-directories-first -AFHhl" "Linux ls with colors and formatting"
    fi

    # Additional utility aliases
    if ! grep -q "Additional utility aliases" "$shell_config" 2>/dev/null; then
        echo "" >> "$shell_config"
        echo "# Additional utility aliases" >> "$shell_config"
    fi
    add_alias_if_needed "$shell_config" "diff" "diff --color" "diff colors"
    add_alias_if_needed "$shell_config" "lsblk" 'lsblk -o "NAME,FSTYPE,FSVER,LABEL,FSAVAIL,SIZE,FSUSE%,MOUNTPOINTS,UUID"' "enhanced lsblk"
    add_alias_if_needed "$shell_config" "lxc-ls" "lxc-ls -f" "formatted lxc-ls"
    if [[ "$SCREEN_INSTALLED" == true ]]; then
        add_alias_if_needed "$shell_config" "screen" "screen -T $TERM" "screen with proper terminal type"
    fi

    # 7z compression helpers
    if [[ "$DETECTED_OS" == "macos" ]]; then
        if ! grep -q "7z compression helpers (macOS" "$shell_config" 2>/dev/null; then
            echo "" >> "$shell_config"
            echo "# 7z compression helpers (macOS - using 7zz)" >> "$shell_config"
        fi
        add_alias_if_needed "$shell_config" "7z-ultra1" "7zz a -t7z -m0=lzma2 -mx=9 -md=256m -mfb=273 -mmf=bt4 -ms=on -mmt" "7z ultra compression level 1"
        add_alias_if_needed "$shell_config" "7z-ultra2" "7zz a -t7z -m0=lzma2 -mx=9 -md=512m -mfb=273 -mmf=bt4 -ms=on -mmt" "7z ultra compression level 2"
        add_alias_if_needed "$shell_config" "7z-ultra3" "7zz a -t7z -m0=lzma2 -mx=9 -md=1536m -mfb=273 -mmf=bt4 -ms=on -mmt" "7z ultra compression level 3"
    else
        if ! grep -q "^# 7z compression helpers$" "$shell_config" 2>/dev/null; then
            echo "" >> "$shell_config"
            echo "# 7z compression helpers" >> "$shell_config"
        fi
        add_alias_if_needed "$shell_config" "7z-ultra1" "7z a -t7z -m0=lzma2 -mx=9 -md=256m -mfb=273 -mmf=bt4 -ms=on -mmt" "7z ultra compression level 1"
        add_alias_if_needed "$shell_config" "7z-ultra2" "7z a -t7z -m0=lzma2 -mx=9 -md=512m -mfb=273 -mmf=bt4 -ms=on -mmt" "7z ultra compression level 2"
        add_alias_if_needed "$shell_config" "7z-ultra3" "7z a -t7z -m0=lzma2 -mx=9 -md=1536m -mfb=273 -mmf=bt4 -ms=on -mmt" "7z ultra compression level 3"
    fi

    # Restore ownership if running as root
    if [[ $EUID -eq 0 ]] && [[ "$username" != "root" ]]; then
        chown "$username:$username" "$shell_config" 2>/dev/null || true
    fi

    print_success "Shell configuration completed for $shell_config (user: $username)"
}

# Configure shell
configure_shell() {
    local scope="$1"  # "user" or "system"

    print_info "Configuring shell..."
    echo ""

    if [[ "$scope" == "system" ]]; then
        # Configure root user (skip on macOS as /root doesn't exist)
        if [[ "$DETECTED_OS" != "macos" ]] && [[ -d "/root" ]]; then
            print_info "Configuring shell for root..."
            configure_shell_for_user "/root" "root"
            configure_shell_prompt_colors_user "/root" "root"
            echo ""
        fi

        # System-wide configuration: iterate over all users
        # Linux: /home/, macOS: /Users/
        local users_dir
        if [[ "$DETECTED_OS" == "macos" ]]; then
            users_dir="/Users"
        else
            users_dir="/home"
        fi

        if [[ -d "$users_dir" ]]; then
            # Find all user home directories
            local user_count=0
            for user_home in "$users_dir"/*; do
                if [[ -d "$user_home" ]]; then
                    local username=$(basename "$user_home")
                    # Skip system users on macOS (Shared, Guest, etc.)
                    if [[ "$DETECTED_OS" == "macos" ]] && [[ "$username" == "Shared" || "$username" == "Guest" ]]; then
                        continue
                    fi
                    print_info "Configuring shell for $username..."
                    configure_shell_for_user "$user_home" "$username"
                    configure_shell_prompt_colors_user "$user_home" "$username"
                    echo ""
                    ((user_count++)) || true
                fi
            done

            if [[ $user_count -gt 0 ]]; then
                if [[ "$DETECTED_OS" == "macos" ]]; then
                    print_success "Configured shell for $user_count user(s)"
                else
                    print_success "Configured shell for root and $user_count user(s)"
                fi
            fi
        fi
    else
        # User-specific configuration: configure for current user only
        print_info "Configuring shell for current user..."
        configure_shell_for_user "$HOME" "$(whoami)"
    fi

    print_info "Note: Users may need to run 'source ~/.bashrc' (or ~/.zshrc) or restart their terminal for changes to take effect."

    if [[ "$scope" == "system" ]]; then
        echo ""
        # Configure system-wide prompt colors
        configure_shell_prompt_colors_system
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

main_configure_system() {
    local scope="${1:-}"

    # Validate scope parameter is provided
    if [[ -z "$scope" ]]; then
        print_error "Scope parameter is required"
        print_info "Usage: $0 <user|system>"
        print_info "  user   - Configure for current user only"
        print_info "  system - Configure system-wide for all users"
        exit 1
    fi

    # Validate scope value
    if [[ "$scope" != "user" && "$scope" != "system" ]]; then
        print_error "Invalid scope: $scope"
        print_info "Usage: $0 <user|system>"
        print_info "  user   - Configure for current user only"
        print_info "  system - Configure system-wide for all users"
        exit 1
    fi

    # Detect OS if not already detected
    if [[ -z "$DETECTED_OS" ]]; then
        detect_os
    fi

    # Verify package manager availability
    if verify_package_manager; then
        # Identify all installed special packages
        while IFS=: read -r display_name package_name; do
            if is_package_installed "$package_name"; then
                track_special_packages "$package_name"
            fi
        done < <(get_package_list)
    fi

    # Configure components based on what's installed
    if [[ "$NANO_INSTALLED" == true ]] || [[ -f $(get_nano_config_file "$scope") ]]; then
        configure_nano "$scope"
        echo ""
    fi

    if [[ "$SCREEN_INSTALLED" == true ]] || [[ -f $(get_screen_config_file "$scope") ]]; then
        configure_screen "$scope"
        echo ""
    fi

    configure_shell "$scope"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_system "$@"
fi
