#!/usr/bin/env bash

# setup-configs.sh - Configure nano, screen, and shell settings
# Implements configurations from nano.md, screen-gnu.md, and shell.md
#
# Usage: ./setup-configs.sh
#
# This script configures:
# - nano editor with sensible defaults and syntax highlighting
# - GNU screen with scrollback and mouse support
# - Shell aliases for safety and convenience (supports bash/zsh)
#
# The script automatically detects Linux vs macOS and configures appropriately.
# It provides options for user-specific or system-wide installation.
# Existing configuration files are backed up before modification.

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variable to track backed up files (simpler approach)
BACKED_UP_FILES=""

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

# Print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
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
        cp "$file" "$backup"
        print_info "Backed up existing file: $file -> $backup"
        BACKED_UP_FILES="$BACKED_UP_FILES $file"
    fi
}

# Check if a configuration line exists in a file
config_exists() {
    local file="$1"
    local pattern="$2"
    
    [[ -f "$file" ]] && grep -qE "^[[:space:]]*${pattern}" "$file"
}

# Get current value of a configuration setting
get_config_value() {
    local file="$1"
    local setting="$2"
    
    if [[ -f "$file" ]]; then
        grep -E "^[[:space:]]*${setting}" "$file" | head -n 1 | sed -E "s/^[[:space:]]*${setting}[[:space:]]*//"
    fi
}

# Add configuration line only if it doesn't exist or has different value
add_config_if_needed() {
    local file="$1"
    local setting="$2"
    local value="$3"
    local description="$4"
    
    local full_setting
    if [[ -n "$value" ]]; then
        full_setting="${setting} ${value}"
    else
        full_setting="${setting}"
    fi
    
    local current_value
    current_value=$(get_config_value "$file" "$setting")
    
    if config_exists "$file" "$setting"; then
        if [[ "$current_value" == "$value" ]]; then
            print_info "✓ $description already configured correctly"
            return 0
        else
            print_info "✗ $description has different value: '$current_value' (expected: '$value')"
            print_warning "Updating $description in $file"
            # Backup before making changes
            backup_file "$file"
            # Remove old line and add new one (use temp file for cross-platform compatibility)
            grep -v "^[[:space:]]*${setting}" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
        fi
    else
        print_info "+ Adding $description to $file"
    fi
    
    echo "$full_setting" >> "$file"
}

# Add alias only if it doesn't exist or has different value
add_alias_if_needed() {
    local file="$1"
    local alias_name="$2"
    local alias_value="$3"
    local description="$4"
    
    local pattern="alias[[:space:]]+${alias_name}="
    local full_alias="alias ${alias_name}='${alias_value}'"
    local current_value
    
    if config_exists "$file" "$pattern"; then
        current_value=$(get_config_value "$file" "$pattern" | sed "s/^'//; s/'$//")
        if [[ "$current_value" == "$alias_value" ]]; then
            print_info "✓ $description alias already configured correctly"
            return 0
        else
            print_info "✗ $description alias has different value: '$current_value' (expected: '$alias_value')"
            print_warning "Updating $description alias in $file"
            # Backup before making changes
            backup_file "$file"
            # Remove old line and add new one (use temp file for cross-platform compatibility)
            grep -v "^[[:space:]]*alias[[:space:]]*${alias_name}=" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
        fi
    else
        print_info "+ Adding $description alias to $file"
    fi
    
    echo "$full_alias" >> "$file"
}

# Add export only if it doesn't exist or has different value
add_export_if_needed() {
    local file="$1"
    local var_name="$2"
    local var_value="$3"
    local description="$4"
    
    local pattern="export[[:space:]]+${var_name}="
    local full_export="export ${var_name}=${var_value}"
    local current_value
    
    if config_exists "$file" "$pattern"; then
        current_value=$(get_config_value "$file" "$pattern")
        if [[ "$current_value" == "$var_value" ]]; then
            print_info "✓ $description export already configured correctly"
            return 0
        else
            print_info "✗ $description export has different value: '$current_value' (expected: '$var_value')"
            print_warning "Updating $description export in $file"
            # Backup before making changes
            backup_file "$file"
            # Remove old line and add new one (use temp file for cross-platform compatibility)
            grep -v "^[[:space:]]*export[[:space:]]*${var_name}=" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
        fi
    else
        print_info "+ Adding $description export to $file"
    fi
    
    echo "$full_export" >> "$file"
}

# Configure nano
configure_nano() {
    local os="$1"
    local scope="$2"  # "user" or "system"
    
    print_info "Configuring nano..."
    
    local config_file
    if [[ "$scope" == "system" ]]; then
        config_file="/etc/nanorc"
        if [[ ! -w "/etc" ]]; then
            print_error "No write permission to /etc. Run as root or choose user scope."
            return 1
        fi
    else
        config_file="$HOME/.nanorc"
    fi
    
    # Create config file if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        print_info "Creating new nano configuration file: $config_file"
        touch "$config_file"
    fi
    
    # Add configuration header if file is empty or doesn't have our header
    if [[ ! -s "$config_file" ]] || ! grep -q "setup-configs.sh" "$config_file" 2>/dev/null; then
        echo "" >> "$config_file"
        echo "# nano configuration - managed by setup-configs.sh" >> "$config_file"
        echo "# Last updated: $(date)" >> "$config_file"
        echo "" >> "$config_file"
    fi
    
    # Check if we need to backup (only if we're going to make changes)
    local original_size
    original_size=$(wc -l < "$config_file" 2>/dev/null || echo "0")
    
    # Configure each setting individually
    add_config_if_needed "$config_file" "set atblanks" "" "atblanks setting"
    add_config_if_needed "$config_file" "set autoindent" "" "autoindent setting"
    add_config_if_needed "$config_file" "set constantshow" "" "constantshow setting"
    add_config_if_needed "$config_file" "set indicator" "" "indicator setting"
    add_config_if_needed "$config_file" "set linenumbers" "" "line numbers setting"
    add_config_if_needed "$config_file" "set minibar" "" "minibar setting"
    add_config_if_needed "$config_file" "set mouse" "" "mouse support setting"
    add_config_if_needed "$config_file" "set multibuffer" "" "multibuffer setting"
    add_config_if_needed "$config_file" "set nonewlines" "" "nonewlines setting"
    add_config_if_needed "$config_file" "set smarthome" "" "smarthome setting"
    add_config_if_needed "$config_file" "set softwrap" "" "softwrap setting"
    add_config_if_needed "$config_file" "set tabsize" "4" "tab size setting"
    
    # Add homebrew include for macOS
    if [[ "$os" == "macos" ]]; then
        local include_line='include "/opt/homebrew/share/nano/*.nanorc"'
        if ! config_exists "$config_file" 'include "/opt/homebrew/share/nano/\*\.nanorc"'; then
            print_info "+ Adding homebrew nano syntax definitions to $config_file"
            echo "" >> "$config_file"
            echo "# homebrew nano syntax definitions" >> "$config_file"
            echo "$include_line" >> "$config_file"
        else
            print_info "✓ homebrew nano syntax definitions already configured"
        fi
    fi
    
    # Check if we made changes and backup if needed
    local new_size
    new_size=$(wc -l < "$config_file" 2>/dev/null || echo "0")
    if [[ "$new_size" -gt "$original_size" ]]; then
        print_info "Configuration changes made to $config_file"
    fi
    
    print_success "Nano configuration completed for $config_file"
}

# Configure GNU screen
configure_screen() {
    local os="$1"
    local scope="$2"  # "user" or "system"
    
    print_info "Configuring GNU screen..."
    
    local config_file
    if [[ "$scope" == "system" ]]; then
        config_file="/etc/screenrc"
        if [[ ! -w "/etc" ]]; then
            print_error "No write permission to /etc. Run as root or choose user scope."
            return 1
        fi
    else
        config_file="$HOME/.screenrc"
    fi
    
    # Create config file if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        print_info "Creating new screen configuration file: $config_file"
        touch "$config_file"
    fi
    
    # Add configuration header if file is empty or doesn't have our header
    if [[ ! -s "$config_file" ]] || ! grep -q "setup-configs.sh" "$config_file" 2>/dev/null; then
        echo "" >> "$config_file"
        echo "# GNU screen configuration - managed by setup-configs.sh" >> "$config_file"
        echo "# Last updated: $(date)" >> "$config_file"
        echo "" >> "$config_file"
    fi
    
    # Configure each setting individually
    add_config_if_needed "$config_file" "startup_message" "off" "startup message setting"
    add_config_if_needed "$config_file" "defscrollback" "9999" "default scrollback setting"
    add_config_if_needed "$config_file" "scrollback" "9999" "scrollback setting"
    add_config_if_needed "$config_file" "defmousetrack" "on" "default mouse tracking setting"
    add_config_if_needed "$config_file" "mousetrack" "on" "mouse tracking setting"
    
    print_success "GNU screen configuration completed for $config_file"
}

# Configure shell
configure_shell() {
    local os="$1"
    
    print_info "Configuring shell aliases..."
    
    # Determine shell config file
    local shell_config
    if [[ "$os" == "macos" ]]; then
        shell_config="$HOME/.zshrc"
    else
        shell_config="$HOME/.bashrc"
    fi
    
    # Create config file if it doesn't exist
    if [[ ! -f "$shell_config" ]]; then
        print_info "Creating new shell configuration file: $shell_config"
        touch "$shell_config"
    fi
    
    # Add configuration header if file is empty or doesn't have our header
    if [[ ! -s "$shell_config" ]] || ! grep -q "setup-configs.sh" "$shell_config" 2>/dev/null; then
        echo "" >> "$shell_config"
        echo "# Shell configuration - managed by setup-configs.sh" >> "$shell_config"
        echo "# Last updated: $(date)" >> "$shell_config"
        echo "" >> "$shell_config"
    fi
    
    # Configure safety aliases
    if ! grep -q "Aliases to help avoid some mistakes" "$shell_config" 2>/dev/null; then
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
    if [[ "$os" == "macos" ]]; then
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
    add_alias_if_needed "$shell_config" "lsblk" 'lsblk -o "NAME,FSTYPE,FSVER,LABEL,FSAVAIL,SIZE,FSUSE%,MOUNTPOINTS,UUID"' "enhanced lsblk"
    add_alias_if_needed "$shell_config" "lxc-ls" "lxc-ls -f" "formatted lxc-ls"
    
    # 7z compression helpers
    if [[ "$os" == "macos" ]]; then
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
    
    print_success "Shell configuration completed for $shell_config"
    print_info "Note: You may need to run 'source $shell_config' or restart your terminal for changes to take effect."
}

# Main function
main() {
    print_info "System Configuration Setup Script (Idempotent Mode)"
    print_info "==================================================="
    
    local os
    os=$(detect_os)
    print_info "Detected OS: $os"
    
    if [[ "$os" == "unknown" ]]; then
        print_error "Unknown operating system. This script supports Linux and macOS."
        exit 1
    fi
    
    # Get user preferences
    echo ""
    print_info "This script will configure:"
    echo "  - nano editor settings"
    echo "  - GNU screen settings"
    echo "  - Shell aliases and configurations"
    echo ""
    print_info "The script will only add or update configurations that are missing or different."
    print_info "Existing configurations matching the desired values will be left unchanged."
    echo ""
    
    read -p "Continue? (y/N): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Setup cancelled."
        exit 0
    fi
    
    # Ask for scope (user vs system) for nano and screen only
    echo ""
    print_info "Choose configuration scope for nano and screen:"
    echo "  1) User-specific (recommended)"
    echo "  2) System-wide (requires root privileges)"
    read -p "Enter choice (1-2): " -r scope_choice
    
    local scope
    case "$scope_choice" in
        1) scope="user" ;;
        2) scope="system" ;;
        *) 
            print_warning "Invalid choice. Defaulting to user-specific."
            scope="user"
            ;;
    esac
    
    print_info "Using scope: $scope"
    
    # Configure each component
    echo ""
    configure_nano "$os" "$scope"
    echo ""
    configure_screen "$os" "$scope"
    echo ""
    configure_shell "$os"
    
    echo ""
    print_success "Configuration setup complete!"
    print_info "The script made only necessary changes to bring your configuration up to date."
    print_info "You may need to restart your terminal or source your shell configuration file for all changes to take effect."
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi