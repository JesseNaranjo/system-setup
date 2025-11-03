#!/usr/bin/env bash

# system-setup.sh - System configuration and package management
# Implements configurations from nano.md, screen-gnu.md, and shell.md
#
# Usage: ./system-setup.sh
#
# This script:
# - Checks and optionally installs required packages (nano, screen, htop, 7zip, openssh-server)
# - Configures nano editor with sensible defaults and syntax highlighting
# - Configures GNU screen with scrollback and mouse support
# - Configures shell aliases for safety and convenience (supports bash/zsh)
#
# The script automatically detects Linux vs macOS and configures appropriately.
# It provides options for user-specific or system-wide installation.
# Existing configuration files are backed up before modification.

if [[ $scriptUpdated -eq 0 || -z $scriptUpdated ]]; then
    REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main"
    SCRIPT_FILE="system-setup.sh"
    TEMP_SCRIPT_FILE="$(mktemp)"
    trap 'rm -f "${TEMP_SCRIPT_FILE}"' RETURN     # ensure cleanup even on exit/interrupt

    # Check for curl or wget availability
    DOWNLOAD_CMD=""
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
    else
        # Display large error message if neither curl nor wget is available
        echo ""
        echo "╔═════════════════════════════════════════════════════════════════════╗"
        echo "║                                                                     ║"
        echo "║                  ⚠️   SELF-UPDATE NOT AVAILABLE  ⚠️                   ║"  # the extra space is intentional for alignment due to the ⚠️  character
        echo "║                                                                     ║"
        echo "║    Neither 'curl' nor 'wget' is installed on this system.           ║"
        echo "║    Self-updating functionality requires one of these tools.         ║"
        echo "║                                                                     ║"
        echo "║    To enable self-updating, please install one of the following:    ║"
        echo "║      • curl  (recommended)                                          ║"
        echo "║      • wget                                                         ║"
        echo "║                                                                     ║"
        echo "║    Installation commands:                                           ║"
        echo "║      macOS:    brew install curl                                    ║"
        echo "║      Debian:   apt install curl                                     ║"
        echo "║      RHEL:     yum install curl                                     ║"
        echo "║                                                                     ║"
        echo "║    Continuing with local version of the script...                   ║"
        echo "║                                                                     ║"
        echo "╚═════════════════════════════════════════════════════════════════════╝"
        echo ""
    fi

    # Proceed with self-update if a download command is available
    if [[ -n "$DOWNLOAD_CMD" ]]; then
        echo "▶ Fetching ${REMOTE_BASE}/${SCRIPT_FILE}..."

        DOWNLOAD_SUCCESS=false
        if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
            # -H header, -o file path, -f fail-on-HTTP-error, -s silent, -S show errors, -L follow redirects
            if curl -H 'Cache-Control: no-cache, no-store' -o "${TEMP_SCRIPT_FILE}" -fsSL "${REMOTE_BASE}/${SCRIPT_FILE}"; then
                DOWNLOAD_SUCCESS=true
            fi
        elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
            # --no-cache, -O output file, -q quiet, --show-progress
            if wget --no-cache --no-cookies -O "${TEMP_SCRIPT_FILE}" -q "${REMOTE_BASE}/${SCRIPT_FILE}"; then
                DOWNLOAD_SUCCESS=true
            fi
        fi

        if [[ "$DOWNLOAD_SUCCESS" == true ]]; then
            if diff -u "${BASH_SOURCE[0]}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
                echo "  ✓ ${SCRIPT_FILE} is already up-to-date"
                echo ""
            else
                echo -e "${LINE_COLOR}╭───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╮${RESET_COLOR}${CODE_COLOR}"
                cat "${TEMP_SCRIPT_FILE}"
                echo -e "${RESET_COLOR}${LINE_COLOR}╰────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${RESET_COLOR}"
                diff -u --color "${BASH_SOURCE[0]}" "${TEMP_SCRIPT_FILE}" || true
                echo -e "${LINE_COLOR}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${RESET_COLOR}"; echo

                read -p "→ Overwrite and run updated ${SCRIPT_FILE}?: [y/N] " continueExec
                echo ""

                if [[ $continueExec == [Yy] ]]; then
                    chmod +x $TEMP_SCRIPT_FILE
                    export scriptUpdated=1
                    $TEMP_SCRIPT_FILE
                    unset scriptUpdated
                    mv $TEMP_SCRIPT_FILE ${BASH_SOURCE[0]}
                    exit 0
                else
                    rm -f $TEMP_SCRIPT_FILE
                    echo "→ Running local unmodified copy..."
                    echo ""
                fi
            fi
        else
            echo "  ✖ Download failed — skipping $SCRIPT_FILE"
            echo "  → Running local unmodified copy..."
            echo ""
        fi
    fi
fi


set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly GRAY='\033[0;90m'
readonly NC='\033[0m' # No Color

# Global variables
BACKED_UP_FILES=""
HEADER_ADDED_FILES=""
NANO_INSTALLED=false
SCREEN_INSTALLED=false
OPENSSH_SERVER_INSTALLED=false

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
    echo -e "${GRAY}[ BACKUP]${NC} $1"
}

# Check if a package is installed (unified for both macOS and Linux)
is_package_installed() {
    local os="$1"
    local package="$2"

    if [[ "$os" == "macos" ]]; then
        brew list "$package" &>/dev/null
    else
        dpkg -l "$package" 2>/dev/null | grep -q "^ii"
    fi
}

# Verify package manager is available
verify_package_manager() {
    local os="$1"

    if [[ "$os" == "macos" ]]; then
        if ! command -v brew &>/dev/null; then
            print_error "Homebrew is not installed. Please install it from https://brew.sh"
            return 1
        fi
    else
        if ! command -v apt &>/dev/null; then
            print_error "apt package manager not found. This script requires apt (Debian/Ubuntu-based systems)"
            return 1
        fi
    fi
    return 0
}

# Get package definitions for the given OS
get_package_list() {
    local os="$1"

    if [[ "$os" == "macos" ]]; then
        # macOS packages (brew)
        echo "7-zip:sevenzip"
        echo "ca-certificates:ca-certificates"
        echo "Git:git"
        echo "htop:htop"
        echo "Nano Editor:nano"
        echo "Ollama:ollama"
        echo "Screen (GNU):screen"
    else
        # Linux packages (apt)
        echo "7-zip:7zip"
        echo "aptitude:aptitude"
        echo "ca-certificates:ca-certificates"
        echo "cURL:curl"
        echo "Git:git"
        echo "htop:htop"
        echo "Nano Editor:nano"
        echo "OpenSSH Server:openssh-server"
        echo "Screen (GNU):screen"
    fi
}

# Track if specific packages are installed for later configuration
track_special_packages() {
    local package="$1"

    if [[ "$package" == "nano" ]]; then
        NANO_INSTALLED=true
    elif [[ "$package" == "screen" ]]; then
        SCREEN_INSTALLED=true
    elif [[ "$package" == "openssh-server" ]]; then
        OPENSSH_SERVER_INSTALLED=true
    fi
}

# Install packages based on OS
install_packages() {
    local os="$1"
    shift
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    echo ""
    print_info "Installing packages: ${packages[*]}"

    if [[ "$os" == "macos" ]]; then
        if brew install "${packages[@]}"; then
            print_success "All packages installed successfully"
            return 0
        fi
    else
        if apt update && apt install -y "${packages[@]}"; then
            print_success "All packages installed successfully"
            return 0
        fi
    fi

    print_error "Failed to install some packages"
    return 1
}

# Check and optionally install packages (consolidated logic)
check_and_install_packages() {
    local os="$1"
    local packages_to_install=()

    print_info "Checking for required packages..."
    echo ""

    # Verify package manager availability
    if ! verify_package_manager "$os"; then
        return 1
    fi

    # Process each package in the list
    while IFS=: read -r display_name package; do
        if is_package_installed "$os" "$package"; then
            print_success "$display_name is already installed"
            track_special_packages "$package"
        else
            print_warning "$display_name is not installed"
            local response
            read -p " - Would you like to install $display_name? (y/N): " -r response < /dev/tty
            if [[ $response =~ ^[Yy]$ ]]; then
                packages_to_install+=("$package")
                track_special_packages "$package"
            fi
        fi
    done < <(get_package_list "$os")

    # Install all selected packages at once
    if ! install_packages "$os" "${packages_to_install[@]}"; then
        return 1
    fi

    echo ""
    return 0
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

# Add change header to file (only once per session)
add_change_header() {
    local file="$1"
    local config_type="$2"  # "nano", "screen", or "shell"

    # Check if header already added in this session
    if [[ "$HEADER_ADDED_FILES" == *"$file"* ]]; then
        return 0
    fi

    # Add header before changes
    echo "" >> "$file"
    case "$config_type" in
        nano)
            echo "# nano configuration - managed by system-setup.sh" >> "$file"
            ;;
        screen)
            echo "# GNU screen configuration - managed by system-setup.sh" >> "$file"
            ;;
        shell)
            echo "# Shell configuration - managed by system-setup.sh" >> "$file"
            ;;
    esac
    echo "# Updated: $(date)" >> "$file"
    echo "" >> "$file"

    # Mark this file as having header added
    HEADER_ADDED_FILES="$HEADER_ADDED_FILES $file"
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
        grep -E "^[[:space:]]*${setting}" "$file" | head -n 1 | sed -E "s/^[[:space:]]*${setting}[[:space:]]*//" || true
    fi
}

# Add configuration line only if it doesn't exist or has different value
add_config_if_needed() {
    local config_type="$1"
    local file="$2"
    local setting="$3"
    local value="$4"
    local description="$5"

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
            # Backup and add header before making changes
            backup_file "$file"
            add_change_header "$file" "$config_type"
            # Comment out old line instead of removing it
            sed -i.bak "s/^[[:space:]]*\(${setting}\)/# \1  # Replaced by system-setup.sh on $(date +%Y-%m-%d)/" "$file" && rm -f "${file}.bak"
        fi
    else
        print_info "+ Adding $description to $file"
        # Backup and add header before making changes
        backup_file "$file"
        add_change_header "$file" "$config_type"
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
            # Backup and add header before making changes
            backup_file "$file"
            add_change_header "$file" "shell"
            # Comment out old line instead of removing it
            sed -i.bak "s/^[[:space:]]*\(alias[[:space:]]*${alias_name}=.*\)/# \1  # Replaced by system-setup.sh on $(date +%Y-%m-%d)/" "$file" && rm -f "${file}.bak"
        fi
    else
        print_info "+ Adding $description alias to $file"
        # Backup and add header before making changes
        backup_file "$file"
        add_change_header "$file" "shell"
    fi

    echo "$full_alias" >> "$file"
}

# Add export only if it doesn't exist or has different value
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
            # Backup and add header before making changes
            backup_file "$file"
            add_change_header "$file" "shell"
            # Comment out old line instead of removing it
            sed -i.bak "s/^[[:space:]]*\(export[[:space:]]*${var_name}=.*\)/# \1  # Replaced by system-setup.sh on $(date +%Y-%m-%d)/" "$file" && rm -f "${file}.bak"
        fi
    else
        print_info "+ Adding $description export to $file"
        # Backup and add header before making changes
        backup_file "$file"
        add_change_header "$file" "shell"
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
    if [[ "$os" == "macos" ]]; then
        local include_line='include "/opt/homebrew/share/nano/*.nanorc"'
        if ! config_exists "$config_file" "$include_line"; then
            print_info "+ Adding homebrew nano syntax definitions to $config_file"
            backup_file "$config_file"
            add_change_header "$config_file" "nano"
            echo "" >> "$config_file"
            echo "# homebrew nano syntax definitions" >> "$config_file"
            echo "$include_line" >> "$config_file"
        else
            print_info "✓ homebrew nano syntax definitions already configured"
        fi
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

    # Configure each setting individually
    add_config_if_needed "screen" "$config_file" "startup_message" "off" "startup message setting"
    add_config_if_needed "screen" "$config_file" "defscrollback" "9999" "default scrollback setting"
    add_config_if_needed "screen" "$config_file" "scrollback" "9999" "scrollback setting"
    add_config_if_needed "screen" "$config_file" "defmousetrack" "on" "default mouse tracking setting"
    add_config_if_needed "screen" "$config_file" "mousetrack" "on" "mouse tracking setting"

    print_success "GNU screen configuration completed for $config_file"
}

# Configure shell for a specific user
configure_shell_for_user() {
    local os="$1"
    local home_dir="$2"
    local username="$3"

    # Determine shell config file
    local shell_config
    if [[ "$os" == "macos" ]]; then
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

    # Restore ownership if running as root
    if [[ $EUID -eq 0 ]] && [[ "$username" != "root" ]]; then
        chown "$username:$username" "$shell_config" 2>/dev/null || true
    fi

    print_success "Shell configuration completed for $shell_config (user: $username)"
    echo ""
}

# Configure shell
configure_shell() {
    local os="$1"
    local scope="$2"  # "user" or "system"

    print_info "Configuring shell aliases..."

    if [[ "$scope" == "system" ]]; then
        # Configure root user
        print_info "Configuring shell for root user..."
        configure_shell_for_user "$os" "/root" "root"

        # System-wide configuration: iterate over all users in /home/
        if [[ ! -d "/home" ]]; then
            print_warning "/home directory does not exist, cannot configure system-wide"
            return 1
        fi

        print_info "Configuring shell for all users in /home/..."

        # Find all user home directories in /home
        local user_count=0
        for user_home in /home/*; do
            if [[ -d "$user_home" ]]; then
                local username
                username=$(basename "$user_home")
                print_info "Processing user: $username"
                configure_shell_for_user "$os" "$user_home" "$username"
                ((user_count++)) || true
            fi
        done

        if [[ $user_count -eq 0 ]]; then
            print_warning "No user directories found in /home/"
        else
            print_success "Configured shell for $user_count user(s)"
        fi
    else
        # User-specific configuration: configure for current user only
        print_info "Configuring shell for current user..."
        configure_shell_for_user "$os" "$HOME" "$(whoami)"
    fi

    print_info "Note: Users may need to run 'source ~/.bashrc' (or ~/.zshrc) or restart their terminal for changes to take effect."
}

# Configure swap memory
configure_swap() {
    local os="$1"

    # Swap configuration is only relevant for Linux systems
    if [[ "$os" != "linux" ]]; then
        print_info "Swap configuration is only applicable to Linux systems"
        return 0
    fi

    # Check if running inside an LXC container
    if [[ -f /proc/1/environ ]] && grep -qa container=lxc /proc/1/environ; then
        print_info "Detected LXC environment: Swap configuration is not recommended inside LXC containers"
        return 0
    fi

    # Additional LXC detection methods as fallback
    if [[ -f /.dockerenv ]] || [[ -f /run/systemd/container ]] || grep -q lxc /proc/1/cgroup 2>/dev/null; then
        print_info "Detected container environment: Swap configuration is not recommended inside containers"
        return 0
    fi

    print_info "Checking swap configuration..."

    # Check if swap is currently enabled
    local swap_status
    swap_status=$(swapon --show 2>/dev/null)

    if [[ -n "$swap_status" ]]; then
        print_info "- Swap is already enabled:"
        echo "- $swap_status"
        return 0
    fi

    print_info "- Swap is currently disabled"
    echo ""
    print_info "Recommended swap sizes:"
    echo "          • ≤2 GB RAM: 2x RAM"
    echo "          • >2 GB RAM: 1.5x RAM"
    echo ""

    local response
    read -p "Would you like to set up swap? (y/N): " -r response

    if [[ ! $response =~ ^[Yy]$ ]]; then
        print_info "- Keeping swap disabled (no changes made)"
        return 0
    fi
    echo ""

    print_info "Configuring swap memory..."

    # Get total RAM in GB
    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_gb=$((ram_kb / 1024 / 1024))

    # Calculate swap size based on RAM
    local swap_gb
    if [[ $ram_gb -le 2 ]]; then
        swap_gb=$((ram_gb * 2))
    else
        # 1.5x RAM (using integer math: multiply by 3 and divide by 2)
        swap_gb=$(((ram_gb * 3) / 2))
    fi

    # Convert to MB for dd count
    local swap_mb=$((swap_gb * 1024))

    print_info "- Detected RAM: ${ram_gb} GB"
    print_info "- Calculated swap size: ${swap_gb} GB (${swap_mb} MB)"
    echo ""

    # Set swapfile location in /var
    local swapfile="/var/swapfile"

    print_info "Creating swap file at ${swapfile}..."

    # Create swap file
    if ! dd if=/dev/zero of="$swapfile" bs=1M count="$swap_mb" 2>&1 | grep -v "records in\|records out"; then
        print_error "Failed to create swap file"
        return 1
    fi

    print_success "- Swap file created (${swap_gb} GB)"

    # Set correct permissions
    print_info "- Setting permissions on swap file (chmod)..."
    if ! chmod 600 "$swapfile"; then
        print_error "Failed to set permissions on swap file"
        rm -f "$swapfile"
        return 1
    fi

    # Format as swap
    print_info "- Formatting swap file (mkswap)..."
    if ! mkswap "$swapfile" 2>&1 | tail -n 1; then
        print_error "Failed to format swap file"
        rm -f "$swapfile"
        return 1
    fi

    # Enable swap
    print_info "- Enabling swap (swapon)..."
    if ! swapon "$swapfile"; then
        print_error "Failed to enable swap"
        rm -f "$swapfile"
        return 1
    fi

    print_success "Swap enabled successfully"
    echo ""

    # Show current swap status
    print_info "Current swap status:"
    swapon --show || true
    echo ""

    # Check if fstab entry exists
    local fstab_entry="${swapfile} none swap sw 0 0"
    if grep -q "^${swapfile}" /etc/fstab 2>/dev/null; then
        print_info "Swap entry already exists in /etc/fstab"
    else
        print_info "Adding swap entry to /etc/fstab for persistence across reboots..."

        # Backup fstab before modification
        backup_file /etc/fstab

        # Add entry to fstab
        echo "" >> /etc/fstab
        echo "# Swap file - managed by system-setup.sh" >> /etc/fstab
        echo "# Added: $(date)" >> /etc/fstab
        echo "$fstab_entry" >> /etc/fstab

        print_success "- Swap entry added to /etc/fstab"
    fi
    echo ""

    print_info "Swap configuration complete"
    print_info "- Swap is automatically activated on reboot"
    print_info "- Swap file: ${swapfile}"
    print_info "- Size: ${swap_gb} GB"
}

# Configure SSH to use socket-based activation instead of service
configure_ssh_socket() {
    local os="$1"

    # SSH socket configuration is only relevant for Linux systems with systemd
    if [[ "$os" != "linux" ]]; then
        print_info "SSH socket configuration is only applicable to Linux systems with systemd"
        return 0
    fi

    # Check if systemd is available
    if ! command -v systemctl &>/dev/null; then
        print_warning "systemctl not found - cannot configure SSH socket (systemd required)"
        return 0
    fi

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
            print_success "- ssh.service disabled and stopped"
            print_success "- SSH is now using socket-based activation only"
        else
            print_error "Could not disable ssh.service"
            return 1
        fi
        return 0
    fi

    # Case 2: ssh.socket is already enabled and ssh.service is disabled
    # Action: Nothing to do
    if [[ "$ssh_socket_enabled" == true ]]; then
        print_info "ssh.socket is already enabled - SSH is already using socket-based activation"
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
    echo "  • ssh.socket: Starts SSH daemon on-demand when connections arrive (saves resources)"
    echo "  • ssh.service: Keeps SSH daemon running constantly (traditional approach)"
    echo ""

    local response
    read -p "Would you like to configure and enable ssh.socket? (y/N): " -r response

    if [[ ! $response =~ ^[Yy]$ ]]; then
        print_info "Keeping current SSH configuration (no changes made)"
        return 0
    fi

    echo ""
    print_info "Configuring socket-based SSH activation..."

    # Disable and stop ssh.service if it's enabled
    if [[ "$ssh_service_enabled" == true ]]; then
        print_info "Disabling ssh.service..."
        if systemctl disable --now ssh.service 2>/dev/null; then
            print_success "- ssh.service disabled and stopped"
        else
            print_warning "Could not disable ssh.service (it may not be active)"
        fi
    fi

    # Open editor for ssh.socket configuration
    echo ""
    print_info "Opening systemd override editor for ssh.socket..."
    print_info "You can customize the socket configuration here (e.g., change port, add ListenStream)"
    print_info "Press Ctrl+X (or appropriate editor command) to save and exit when done"
    echo ""

    # Give user a moment to read the message
    sleep 3

    if systemctl edit ssh.socket; then
        print_success "ssh.socket configuration saved"
    else
        print_error "Failed to edit ssh.socket configuration"
        return 1
    fi
    echo ""

    # Enable and start ssh.socket
    print_info "Enabling and starting ssh.socket..."
    if systemctl enable --now ssh.socket; then
        print_success "- ssh.socket enabled and started"
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

# Main function
main() {
    print_info "System Setup and Configuration Script (Idempotent Mode)"
    print_info "======================================================="

    local os
    os=$(detect_os)
    print_info "Detected OS: $os"

    if [[ "$os" == "unknown" ]]; then
        print_error "Unknown operating system. This script supports Linux and macOS."
        exit 1
    fi

    # Check and install packages
    echo ""
    print_info "Step 1: Package Management"
    print_info "---------------------------"
    if ! check_and_install_packages "$os"; then
        print_error "Package management failed. Continuing with configuration for installed packages..."
    fi

    # Get user preferences
    echo ""
    print_info "Step 2: Configuration"
    print_info "---------------------"
    print_info "This script will configure:"
    if [[ "$NANO_INSTALLED" == true ]]; then
        echo "          ✓ nano editor settings"
    else
        echo "          ✗ nano editor (not installed, will be skipped)"
    fi
    if [[ "$SCREEN_INSTALLED" == true ]]; then
        echo "          ✓ GNU screen settings"
    else
        echo "          ✗ GNU screen (not installed, will be skipped)"
    fi
    if [[ "$OPENSSH_SERVER_INSTALLED" == true ]]; then
        echo "          ✓ OpenSSH Server (socket-based activation option)"
    else
        echo "          ✗ OpenSSH Server (not installed, will be skipped)"
    fi
    echo "          ✓ Shell aliases and configurations"
    echo ""
    print_info "The script will only add or update configurations that are missing or different."
    print_info "Existing configurations matching the desired values will be left unchanged."
    echo ""

    # Ask for scope (user vs system) for all components
    echo ""
    print_info "Choose configuration scope:"
    echo "          1) User-specific (recommended) - configures for current user only"
    echo "          2) System-wide (requires root) - nano/screen system-wide, shell for all users in /home/"
    echo "          Ctrl+C to cancel configuration and exit"
    echo ""
    read -p "          Enter choice (1-2): " -r scope_choice

    local scope
    case "$scope_choice" in
        1) scope="user" ;;
        2) scope="system" ;;
        *)
            print_warning "Invalid choice. Defaulting to user-specific."
            scope="user"
            ;;
    esac
    echo ""

    print_info "Using scope: $scope"

    # Configure each component
    echo ""
    if [[ "$NANO_INSTALLED" == true ]]; then
        configure_nano "$os" "$scope"
        echo ""
    else
        print_info "Skipping nano configuration (not installed)"
        echo ""
    fi

    if [[ "$SCREEN_INSTALLED" == true ]]; then
        configure_screen "$os" "$scope"
        echo ""
    else
        print_info "Skipping screen configuration (not installed)"
        echo ""
    fi

    configure_shell "$os" "$scope"
    echo ""

    # Configure swap memory if system scope (Linux only)
    if [[ "$scope" == "system" ]]; then
        configure_swap "$os"
        echo ""
    fi

    # Configure OpenSSH Server if installed (Linux only, system scope only)
    if [[ "$scope" == "system" ]]; then
        if [[ "$OPENSSH_SERVER_INSTALLED" == true ]]; then
            configure_ssh_socket "$os"
        else
            print_info "Skipping OpenSSH Server configuration (not installed)"
        fi
        echo ""
    fi

    print_success "Setup complete!"
    echo ""
    print_info "The script made only necessary changes to bring your configuration up to date."
    print_info "You may need to restart your terminal or source your shell configuration file for all changes to take effect."
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
