#!/usr/bin/env bash

# utils.sh - Common utilities and variables for system-setup scripts
# This script provides shared functionality used across all system-setup modules

# Prevent multiple sourcing
if [[ -n "${UTILS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly UTILS_SH_LOADED=true

set -euo pipefail

# ============================================================================
# Colors and Output Constants
# ============================================================================

readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m' # Cyan for lines/borders
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly MAGENTA='\033[0;35m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# ============================================================================
# Global Variables
# ============================================================================

DEBUG_MODE=false
DETECTED_OS=""
BACKED_UP_FILES=()
CREATED_BACKUP_FILES=()
HEADER_ADDED_FILES=()
NANO_INSTALLED=false
SCREEN_INSTALLED=false
OPENSSH_SERVER_INSTALLED=false
RUNNING_IN_CONTAINER=false

# Package cache for performance optimization
declare -A PACKAGE_CACHE=()
PACKAGE_CACHE_POPULATED=false

# ============================================================================
# Output Functions
# ============================================================================

# Print colored output
print_backup() {
    echo -e "${GRAY}[ BACKUP  ] $1${NC}"
}

print_debug() {
    echo -e "${MAGENTA}[ DEBUG   ] $1${NC}"
}

print_error() {
    echo -e "${RED}[ ERROR   ]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[ INFO    ]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[ SUCCESS ]${NC} $1"
}

print_summary() {
    echo -e "${BLUE}[ SUMMARY ]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ WARNING ]${NC} $1"
}

# ============================================================================
# User Input Functions
# ============================================================================

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

# ============================================================================
# OS and Environment Detection
# ============================================================================

# Detect OS and populate DETECTED_OS global variable
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        DETECTED_OS="macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        DETECTED_OS="linux"
    else
        DETECTED_OS="unknown"
    fi
}

# Detect if running inside a container (LXC, Docker, or other)
# Sets the global RUNNING_IN_CONTAINER variable
detect_container() {
    # Check for LXC container via environment variable
    if [[ -f /proc/1/environ ]] && grep -qa container=lxc /proc/1/environ; then
        RUNNING_IN_CONTAINER=true
        return
    fi

    # Check for Docker container
    if [[ -f /.dockerenv ]]; then
        RUNNING_IN_CONTAINER=true
        return
    fi

    # Check for systemd container
    if [[ -f /run/systemd/container ]]; then
        RUNNING_IN_CONTAINER=true
        return
    fi

    # Check for LXC in cgroup
    if grep -q lxc /proc/1/cgroup 2>/dev/null; then
        RUNNING_IN_CONTAINER=true
        return
    fi

    # Not in a container
    RUNNING_IN_CONTAINER=false
}

# ============================================================================
# Privilege Management
# ============================================================================

# Check if we have necessary privileges for the operation
# Returns: 0 if privileges are sufficient, 1 otherwise
check_privileges() {
    local operation="$1"  # "package_install", "system_config", or "apt_operations"

    if [[ "$operation" == "package_install" ]]; then
        if [[ "$DETECTED_OS" == "linux" ]]; then
            # Linux requires root for apt
            if [[ $EUID -ne 0 ]]; then
                return 1
            fi
        fi
        # macOS doesn't need root for brew
    elif [[ "$operation" == "system_config" ]] || [[ "$operation" == "apt_operations" ]]; then
        # System-wide config and apt operations need root on Linux
        if [[ "$DETECTED_OS" == "linux" ]] && [[ $EUID -ne 0 ]]; then
            return 1
        fi
    fi
    return 0
}

# Run command with appropriate privileges (macOS only - uses sudo for system operations)
# On Linux, script should already be running as root for system operations
run_elevated() {
    if [[ $EUID -eq 0 ]]; then
        # Already running as root, just execute
        "$@"
    else
        if [[ "$DETECTED_OS" == "macos" ]]; then
            # On macOS, use sudo for system changes
            sudo "$@"
        else
            # On Linux, shouldn't get here (should already be root for system operations)
            print_error "Insufficient privileges to run: $*"
            return 1
        fi
    fi
}

# Check if a file operation needs elevation (macOS-specific)
# Returns 0 if elevation needed, 1 if not
needs_elevation() {
    local file="$1"

    # If already root or running Linux (which should already be root), no elevation needed
    if [[ $EUID -eq 0 ]] || [[ "$OSTYPE" == "linux"* ]]; then
        return 1
    fi

    # Check if file is in a system directory
    if [[ "$file" == /etc/* ]] || [[ "$file" == /usr/* ]] || [[ "$file" == /var/* ]]; then
        return 0
    fi

    # Check if parent directory requires elevated permissions
    local dir=$(dirname "$file")
    if [[ ! -w "$dir" ]]; then
        return 0
    fi

    return 1
}

# ============================================================================
# Package Management Functions
# ============================================================================

# Get package definitions for the given OS
get_package_list() {
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # macOS packages (brew)
        echo "7-zip:sevenzip"
        echo "AWK:awk"
        echo "Bash:bash"
        echo "CA Certificates:ca-certificates"
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

# Populate the package cache with installed packages from the package list
populate_package_cache() {
    if [[ "$DEBUG_MODE" == true ]]; then
        print_debug "Populating package cache..."
    fi

    # Get all package names from the package list
    local package_list=()
    while read -r line; do
        package_list+=("${line##*:}")
    done < <(get_package_list)

    local installed_packages
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # Get all installed packages from brew
        installed_packages=$(brew list --formula -1 2>/dev/null || true)
    else
        # Get all installed packages from dpkg
        installed_packages=$(dpkg -l 2>/dev/null | awk '/^ii/ {print $2}' || true)
    fi

    PACKAGE_CACHE=()
    # Check each package from our list against installed packages
    for package in "${package_list[@]}"; do
        if echo "$installed_packages" | grep -qx "$package"; then
            PACKAGE_CACHE["$package"]="installed"
        else
            PACKAGE_CACHE["$package"]="not_installed"
        fi
    done

    PACKAGE_CACHE_POPULATED=true
}

# Check if a package is installed (unified for both macOS and Linux)
# Uses cache for performance optimization
is_package_installed() {
    local package="$1"

    # Populate cache if not yet populated
    if [[ "$PACKAGE_CACHE_POPULATED" != "true" ]]; then
        populate_package_cache
    fi

    # Check cache first
    if [[ -n "${PACKAGE_CACHE[$package]:-}" ]]; then
        [[ "${PACKAGE_CACHE[$package]}" == "installed" ]]
        return $?
    fi

    # Fallback to direct check if not in cache (shouldn't happen normally)
    if [[ "$DETECTED_OS" == "macos" ]]; then
        brew list "$package" &>/dev/null
    else
        dpkg -l "$package" 2>/dev/null | grep -q "^ii"
    fi
}

# Verify package manager is available
verify_package_manager() {
    if [[ "$DETECTED_OS" == "macos" ]]; then
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

# ============================================================================
# File Management Functions
# ============================================================================

# Backup file if it exists (only once per session)
backup_file() {
    local file="$1"
    local already_backed_up=false

    # Check if already backed up in this session
    for backed_up_file in "${BACKED_UP_FILES[@]+"${BACKED_UP_FILES[@]}"}"; do
        if [[ "$backed_up_file" == "$file" ]]; then
            already_backed_up=true
            break
        fi
    done

    if [[ "$already_backed_up" == true ]]; then
        return 0
    fi

    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S).bak"

        # Copy file with preserved permissions (-p flag)
        if needs_elevation "$file"; then
            sudo cp -p "$file" "$backup"
        else
            cp -p "$file" "$backup"
        fi

        # Preserve ownership (requires appropriate permissions)
        # Get the owner and group of the original file
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS stat syntax
            local owner=$(stat -f "%u:%g" "$file")
            if needs_elevation "$file"; then
                sudo chown "$owner" "$backup" 2>/dev/null || true
            else
                chown "$owner" "$backup" 2>/dev/null || true
            fi
        else
            # Linux stat syntax
            local owner=$(stat -c "%u:%g" "$file")
            chown "$owner" "$backup" 2>/dev/null || true
        fi

        print_backup "- Created backup: $backup"
        BACKED_UP_FILES+=("$file")
        CREATED_BACKUP_FILES+=("$backup")
    fi
}

# Add change header to file (only once per session)
add_change_header() {
    local file="$1"
    local config_type="$2"  # "nano", "screen", or "shell"
    local already_added=false

    # Check if header already added in this session
    for added_file in "${HEADER_ADDED_FILES[@]+"${HEADER_ADDED_FILES[@]}"}"; do
        if [[ "$added_file" == "$file" ]]; then
            already_added=true
            break
        fi
    done

    if [[ "$already_added" == true ]]; then
        return 0
    fi

    # Prepare header content
    local header_content=""
    header_content+=$'\n'
    case "$config_type" in
        nano)
            header_content+="# nano configuration - managed by system-setup.sh"$'\n'
            ;;
        screen)
            header_content+="# GNU screen configuration - managed by system-setup.sh"$'\n'
            ;;
        shell)
            header_content+="# Shell configuration - managed by system-setup.sh"$'\n'
            ;;
    esac
    header_content+="# Updated: $(date)"$'\n'
    header_content+=$'\n'

    # Add header before changes
    if needs_elevation "$file"; then
        echo "$header_content" | sudo tee -a "$file" > /dev/null
    else
        echo "$header_content" >> "$file"
    fi

    # Mark this file as having header added
    HEADER_ADDED_FILES+=("$file")
}

# ============================================================================
# Configuration Management Functions
# ============================================================================

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

# Add or update a configuration line in a file.
update_config_line() {
    local config_type="$1"
    local file="$2"
    local setting_pattern="$3" # Regex pattern to find the line
    local full_line="$4"       # The full line to be added/updated
    local description="$5"

    if [[ "$DEBUG_MODE" == true && $full_line =~ ls ]]; then
        print_debug "update_config_line called with:"
        print_debug "  config_type: $config_type"
        print_debug "  file: $file"
        print_debug "  setting_pattern: $setting_pattern"
        print_debug "  full_line: $full_line"
        print_debug "  description: $description"
    fi

    if config_exists "$file" "$setting_pattern"; then
        # Setting exists, check if it's already correct
        if grep -qE "^[[:space:]]*${full_line}[[:space:]]*$" "$file"; then
            print_success "- $description already configured correctly"
            return 0
        else
            local current_value=$(grep -E "^[[:space:]]*${setting_pattern}" "$file" | head -n 1)
            print_warning "✖ $description has different value: '$current_value' in $file"
            backup_file "$file"
            add_change_header "$file" "$config_type"

            local temp_file=$(mktemp)

            # Use awk to find the line, comment it, and append the new line at the end of the file
            awk -v pattern="^[[:space:]]*${setting_pattern}" -v new_line="${full_line}" '
            BEGIN { found=0 }
            $0 ~ pattern {
                print "# " $0 " # Replaced by system-setup.sh on " ("date +%Y-%m-%d" | getline);
                found=1;
                next;
            }
            { print }
            END {
                if (found) {
                    print new_line;
                }
            }
            ' "$file" > "$temp_file"

            # Replace the original file with the updated temporary file
            if needs_elevation "$file"; then
                sudo mv "$temp_file" "$file"
            else
                mv "$temp_file" "$file"
            fi
            print_success "✓ $description updated in $file"
        fi
    else
        backup_file "$file"
        add_change_header "$file" "$config_type"
        if needs_elevation "$file"; then
            echo "$full_line" | sudo tee -a "$file" > /dev/null
        else
            echo "$full_line" >> "$file"
        fi
        print_success "✓ $description added to $file"
    fi
}

# Wrapper for simple key-value or key-only settings (e.g., nano, screen)
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

    # The pattern is the setting key itself
    if [[ $setting =~ ^[[:space:]]*set[[:space:]]+ ]]; then
        local setting_key=${setting#set }
        local setting_pattern="^[[:space:]]*set[[:space:]]+${setting_key}"
    else
        local setting_pattern="^[[:space:]]*${setting}"
    fi

    update_config_line "$config_type" "$file" "$setting_pattern" "$full_setting" "$description"
}

# Wrapper for shell aliases
add_alias_if_needed() {
    local file="$1"
    local alias_name="$2"
    local alias_value="$3"
    local description="$4"

    local full_alias="alias ${alias_name}='${alias_value}'"
    # The pattern finds 'alias name='
    local setting_pattern="alias[[:space:]]+${alias_name}="

    update_config_line "shell" "$file" "$setting_pattern" "$full_alias" "$description"
}

# Wrapper for shell exports
add_export_if_needed() {
    local file="$1"
    local var_name="$2"
    local var_value="$3"
    local description="$4"

    local full_export="export ${var_name}=${var_value}"
    # The pattern finds 'export NAME='
    local setting_pattern="export[[:space:]]+${var_name}="

    update_config_line "shell" "$file" "$setting_pattern" "$full_export" "$description"
}

# ============================================================================
# Summary Functions
# ============================================================================

# Print a summary of all changes made
print_session_summary() {
    if [[ ${#BACKED_UP_FILES[@]} -eq 0 && ${#CREATED_BACKUP_FILES[@]} -eq 0 ]]; then
        echo -e "            ${GRAY}No files were modified during this session.${NC}"
        return
    fi

    print_summary "─── Session ─────────────────────────────────────────────────────────"
    echo ""

    if [[ ${#BACKED_UP_FILES[@]} -gt 0 ]]; then
        print_success "${GREEN}Files Updated:${NC}"
        for file in "${BACKED_UP_FILES[@]+"${BACKED_UP_FILES[@]}"}"; do
            echo "            - $file"
        done
        echo ""
    fi

    if [[ ${#CREATED_BACKUP_FILES[@]} -gt 0 ]]; then
        print_backup "Backup Files:"
        for file in "${CREATED_BACKUP_FILES[@]+"${CREATED_BACKUP_FILES[@]}"}"; do
            echo "            - $file"
        done
        echo ""
    fi
    print_summary "─────────────────────────────────────────────────────────────────────"
}
