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

set -euo pipefail

# Colors for output (must be defined early for self-update section)
readonly BLUE='\033[0;34m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color
readonly LINE_COLOR='\033[0;36m' # Cyan for lines/borders
readonly CODE_COLOR='\033[0;37m' # White for code blocks

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

if [[ ${scriptUpdated:-0} -eq 0 ]]; then
    REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main"
    SCRIPT_FILE="system-setup.sh"
    TEMP_SCRIPT_FILE="$(mktemp)"
    trap 'rm -f "${TEMP_SCRIPT_FILE}"' EXIT     # ensure cleanup on script exit

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
                echo -e "${LINE_COLOR}╭───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╮${NC}${CODE_COLOR}"
                cat "${TEMP_SCRIPT_FILE}"
                echo -e "${NC}${LINE_COLOR}╰────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${NC}"
                diff -u --color "${BASH_SOURCE[0]}" "${TEMP_SCRIPT_FILE}" || true
                echo -e "${LINE_COLOR}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${NC}"; echo

                if prompt_yes_no "→ Overwrite and run updated ${SCRIPT_FILE}?" "y"; then
                    echo ""
                    chmod +x "$TEMP_SCRIPT_FILE"
                    mv -f "$TEMP_SCRIPT_FILE" "${BASH_SOURCE[0]}"
                    export scriptUpdated=1
                    exec "${BASH_SOURCE[0]}" "$@"
                    exit 0
                else
                    echo ""
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

# Global variables
BACKED_UP_FILES=()
CREATED_BACKUP_FILES=()
HEADER_ADDED_FILES=()
NANO_INSTALLED=false
SCREEN_INSTALLED=false
OPENSSH_SERVER_INSTALLED=false
RUNNING_IN_CONTAINER=false

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
    echo -e "${GRAY}[ BACKUP] $1${NC}"
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

# Modernize APT sources configuration (Debian/Ubuntu)
# Converts old sources.list format to DEB822 format and configures non-free components
modernize_apt_sources() {
    local os="$1"

    # Only run on Linux systems
    if [[ "$os" != "linux" ]]; then
        return 0
    fi

    # Only run if apt is available
    if ! command -v apt &>/dev/null; then
        return 0
    fi

    print_info "Modernizing APT sources configuration..."

    # Run apt modernize-sources
    if ! apt modernize-sources 2>/dev/null; then
        print_warning "apt modernize-sources failed or is not available"
        return 0
    fi

    # Remove backup file if it exists
    if [[ -f /etc/apt/sources.list.bak ]]; then
        rm -f /etc/apt/sources.list.bak
        print_success "✓ Removed /etc/apt/sources.list.bak"
    fi

    # Check if the new DEB822 format file exists
    local sources_file="/etc/apt/sources.list.d/debian.sources"
    if [[ ! -f "$sources_file" ]]; then
        print_warning "DEB822 sources file not found at $sources_file"
        return 0
    fi

    # Read the current Suites line and extract the release name
    local suites_line=$(grep -E "^Suites:" "$sources_file" | head -n 1)

    if [[ -z "$suites_line" ]]; then
        print_warning "Could not find Suites line in $sources_file"
        return 0
    fi

    # Extract the first suite name (the release)
    local release=$(echo "$suites_line" | sed -E 's/^Suites:\s*([a-z]+).*/\1/')

    # Validate release name
    local valid_releases=("bookworm" "trixie" "forky" "duke")
    local is_valid_release=false
    for valid_rel in "${valid_releases[@]}"; do
        if [[ "$release" == "$valid_rel" ]]; then
            is_valid_release=true
            break
        fi
    done

    if [[ "$is_valid_release" != true ]]; then
        local releases_list=$(IFS=', '; echo "${valid_releases[*]}")
        print_warning "Release '$release' is not a recognized Debian release ($releases_list)"
        return 0
    fi

    print_info "Detected Debian release: $release"

    # Create a temporary file for the new sources configuration
    local temp_sources=$(mktemp)

    # Process the file: buffer each stanza and process based on content
    local suites_modified=false
    local components_modified=false
    local current_stanza_lines=()
    local skip_current_stanza=false
    local is_release_stanza=false
    local is_security_stanza=false
    local last_line_was_blank=false

    while read -r line || [[ -n "$line" ]]; do
        # Detect stanza boundaries (empty lines separate stanzas)
        if [[ -z "$line" ]]; then
            if [[ ${#current_stanza_lines[@]} -gt 0 ]]; then
                # End of a stanza - write it out if not skipped
                if [[ "$skip_current_stanza" != true ]]; then
                    for stanza_line in "${current_stanza_lines[@]}"; do
                        echo "$stanza_line" >> "$temp_sources"
                    done
                    # Write the empty line separator only if we haven't just written one
                    if [[ "$last_line_was_blank" != true ]]; then
                        echo "$line" >> "$temp_sources"
                        last_line_was_blank=true
                    fi
                fi

                # Reset for next stanza
                current_stanza_lines=()
                skip_current_stanza=false
                is_release_stanza=false
                is_security_stanza=false
            else
                # Empty line between stanzas or at beginning - only write if not duplicate
                if [[ "$last_line_was_blank" != true ]]; then
                    echo "$line" >> "$temp_sources"
                    last_line_was_blank=true
                fi
            fi
            continue
        fi

        # Non-empty line, reset blank line tracking
        last_line_was_blank=false

        # Check if this is a Suites line to identify the stanza type
        if [[ "$line" =~ ^Suites: ]]; then
            local current_stanza_suite=$(echo "$line" | sed -E 's/^Suites:\s*//')

            # Check if this stanza should be skipped (updates or backports only)
            if [[ "$current_stanza_suite" == "${release}-updates" ]] || [[ "$current_stanza_suite" == "${release}-backports" ]]; then
                skip_current_stanza=true
            fi

            # Check if this is the main release stanza (contains the release name)
            if [[ "$current_stanza_suite" =~ (^|[[:space:]])${release}([[:space:]]|$) ]]; then
                is_release_stanza=true
            fi

            # Check if this is the security stanza
            if [[ "$current_stanza_suite" == "${release}-security" ]]; then
                is_security_stanza=true
            fi
        fi

        # Skip processing lines if this stanza is marked to skip
        if [[ "$skip_current_stanza" == true ]]; then
            continue
        fi

        # Process lines based on type
        if [[ "$line" =~ ^Suites: ]]; then
            if [[ "$is_release_stanza" == true ]]; then
                # Modify the release stanza - check if updates and backports are already present
                local new_line="$line"
                if [[ ! "$line" =~ ${release}-updates ]]; then
                    new_line="$new_line ${release}-updates"
                    suites_modified=true
                fi
                if [[ ! "$line" =~ ${release}-backports ]]; then
                    new_line="$new_line ${release}-backports"
                    suites_modified=true
                fi
                current_stanza_lines+=("$new_line")
            else
                # Keep Suites lines in other stanzas unchanged
                current_stanza_lines+=("$line")
            fi
        elif [[ "$line" =~ ^Components: ]]; then
            if [[ "$is_release_stanza" == true ]] || [[ "$is_security_stanza" == true ]]; then
                # Modify the release/security stanzas - only Components
                local new_line="$line"
                if [[ ! "$line" =~ (^|[[:space:]])non-free([[:space:]]|$) ]]; then
                    new_line="$new_line non-free"
                    components_modified=true
                fi
                if [[ ! "$line" =~ non-free-firmware ]]; then
                    new_line="$new_line non-free-firmware"
                    components_modified=true
                fi
                current_stanza_lines+=("$new_line")
            else
                # Keep Components lines in other stanzas unchanged
                current_stanza_lines+=("$line")
            fi
        else
            # Keep non-Suite/non-Components lines as-is
            current_stanza_lines+=("$line")
        fi
    done < "$sources_file"

    # Handle the last stanza if file doesn't end with empty line
    if [[ ${#current_stanza_lines[@]} -gt 0 ]] && [[ "$skip_current_stanza" != true ]]; then
        for stanza_line in "${current_stanza_lines[@]}"; do
            echo "$stanza_line" >> "$temp_sources"
        done
    fi

    # Replace the original file with the modified one
    if [[ "$suites_modified" == true ]] || [[ "$components_modified" == true ]]; then
        # Backup the original
        backup_file "$sources_file"

        # Replace with new content
        mv "$temp_sources" "$sources_file"

        if [[ "$suites_modified" == true ]]; then
            print_success "✓ Updated Suites to include: $release ${release}-updates ${release}-backports"
        fi
        if [[ "$components_modified" == true ]]; then
            print_success "✓ Updated Components to include: non-free non-free-firmware"
        fi
        print_success "✓ APT sources modernization complete"
    else
        rm -f "$temp_sources"
        print_success "APT sources already configured correctly"
    fi
    echo ""

    # Offer to manually edit the sources file
    if prompt_yes_no "Would you like to manually edit $sources_file with nano?" "n"; then
        if command -v nano &>/dev/null; then
            nano "$sources_file"
            print_info "Manual edit completed"
        else
            print_warning "nano is not installed"
        fi
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
            print_success "✓ All packages installed successfully"
            return 0
        fi
    else
        if apt update && apt install -y "${packages[@]}"; then
            print_success "✓ All packages installed successfully"
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
            if prompt_yes_no "          - Would you like to install $display_name?" "n"; then
                packages_to_install+=("$package")
                track_special_packages "$package"
            fi
        fi
    done < <(get_package_list "$os")

    # Check if there are any packages to install
    if [[ ${#packages_to_install[@]} -eq 0 ]]; then
        echo ""
        return 0
    fi

    # Display packages to be installed and confirm
    echo ""
    print_info "The following packages will be installed:"
    for package in "${packages_to_install[@]}"; do
        echo "          - $package"
    done
    echo ""

    if ! prompt_yes_no "          Do you want to proceed with the installation?" "y"; then
        print_info "Package installation cancelled"
        echo ""
        return 0
    fi

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
    local already_backed_up=false

    # Check if already backed up in this session
    for backed_up_file in "${BACKED_UP_FILES[@]}"; do
        if [[ "$backed_up_file" == "$file" ]]; then
            already_backed_up=true
            break
        fi
    done

    if [[ "$already_backed_up" == true ]]; then
        return 0
    fi

    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"

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
    for added_file in "${HEADER_ADDED_FILES[@]}"; do
        if [[ "$added_file" == "$file" ]]; then
            already_added=true
            break
        fi
    done

    if [[ "$already_added" == true ]]; then
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
    HEADER_ADDED_FILES+=("$file")
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

# Add or update a configuration line in a file. This is the new generic handler.
# It uses a flexible pattern for finding the setting and a command to extract the current value.
update_config_line() {
    local config_type="$1"
    local file="$2"
    local setting_pattern="$3" # Regex pattern to find the line
    local full_line="$4"       # The full line to be added/updated
    local description="$5"
    local value_extractor="$6" # A command string to extract the value for comparison
    local desired_value="$7"   # The desired value to compare against

    if config_exists "$file" "$setting_pattern"; then
        # Setting exists, extract its value for comparison
        local current_value=$(grep -E "^[[:space:]]*${setting_pattern}" "$file" | head -n 1 | eval "sed -E ${value_extractor}")

        if [[ "$current_value" == "$desired_value" ]]; then
            print_success "- $description already configured correctly"
            return 0
        else
            print_info "✗ $description has different value: '$current_value' (expected: '$desired_value')"
            print_warning "Updating $description in $file"
            backup_file "$file"
            add_change_header "$file" "$config_type"

            # Comment out the old line
            local temp_file
            temp_file=$(mktemp)
            sed "s|^\([[:space:]]*\)\(${setting_pattern}.*\)|\1# \2  # Replaced by system-setup.sh on $(date +%Y-%m-%d)|" "$file" > "$temp_file"
            mv "$temp_file" "$file"
        fi
    else
        print_info "+ Adding $description to $file"
        backup_file "$file"
        add_change_header "$file" "$config_type"
    fi

    echo "$full_line" >> "$file"
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
    local setting_pattern="${setting}"
    # The extractor grabs everything after the key
    local value_extractor="'s/^[[:space:]]*${setting}[[:space:]]*//'"

    update_config_line "$config_type" "$file" "$setting_pattern" "$full_setting" "$description" "$value_extractor" "$value"
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
    # The extractor grabs the value inside the quotes
    local value_extractor="\"s/^[[:space:]]*alias[[:space:]]+${alias_name}='//; s/'$//\""

    update_config_line "shell" "$file" "$setting_pattern" "$full_alias" "$description" "$value_extractor" "$alias_value"
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
    # The extractor grabs everything after the '='
    local value_extractor="'s/^[[:space:]]*export[[:space:]]+${var_name}=//'"

    update_config_line "shell" "$file" "$setting_pattern" "$full_export" "$description" "$value_extractor" "$var_value"
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
            print_success "homebrew nano syntax definitions already configured"
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

# Configure /etc/issue with network interface information
configure_issue_network() {
    local os="$1"

    # /etc/issue configuration is only relevant for Linux systems
    if [[ "$os" != "linux" ]]; then
        print_info "/etc/issue configuration is only applicable to Linux systems"
        return 0
    fi

    print_info "Reviewing network interface information in /etc/issue..."

    # Check if running inside a container
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        print_warning "Detected container environment: /etc/issue configuration may not be useful inside containers"
        # Don't return - still allow configuration if user wants it
    fi

    # Check if /etc/issue exists and is writable
    if [[ ! -f /etc/issue ]]; then
        print_warning "/etc/issue does not exist"
        return 1
    fi

    if [[ ! -w /etc/issue ]]; then
        print_error "No write permission to /etc/issue. Run as root."
        return 1
    fi

    print_info "Detecting network interfaces:"

    # Get list of network interfaces (excluding loopback)
    local interfaces=()
    local wire_interfaces=()
    local wifi_interfaces=()
    local other_interfaces=()

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
            loopback)
                # Skip loopback
                ;;
            *)
                other_interfaces+=("$iface_name:$iface_type")
                ;;
        esac
    done

    # Display detected interfaces
    if [[ ${#wire_interfaces[@]} -gt 0 ]]; then
        echo "          - Wired interfaces: ${wire_interfaces[*]}"
    fi
    if [[ ${#wifi_interfaces[@]} -gt 0 ]]; then
        echo "          - Wireless interfaces: ${wifi_interfaces[*]}"
    fi
    if [[ ${#other_interfaces[@]} -gt 0 ]]; then
        echo "          - Other interfaces: ${other_interfaces[*]}"
    fi

    if [[ ${#wire_interfaces[@]} -eq 0 && ${#wifi_interfaces[@]} -eq 0 && ${#other_interfaces[@]} -eq 0 ]]; then
        print_warning "No network interfaces detected (excluding loopback)"
        return 0
    fi

    # Check if /etc/issue already has a network interface box and compare interfaces
    if grep -q "║ Network Interfaces" /etc/issue; then
        print_info "Network interfaces found in /etc/issue, checking for changes..."

        # Extract interface names from current /etc/issue
        local existing_interfaces=()
        while IFS= read -r line; do
            # Match lines like: "  ║ - wire: \4{eth0} / \6{eth0} (eth0)"
            if [[ "$line" =~ \(([a-zA-Z0-9_-]+)\)[[:space:]]*$ ]]; then
                existing_interfaces+=("${BASH_REMATCH[1]}")
            fi
        done < <(sed -n '/║ Network Interfaces/,/^\s*╚═/p' /etc/issue)

        # Build list of current interfaces (all types combined)
        local current_interfaces=()
        current_interfaces+=("${wire_interfaces[@]}")
        current_interfaces+=("${wifi_interfaces[@]}")
        for iface_info in "${other_interfaces[@]}"; do
            current_interfaces+=("${iface_info%%:*}")
        done

        # Check for new interfaces (in current but not in existing)
        local new_interfaces=()
        for iface in "${current_interfaces[@]}"; do
            local found=false
            for existing in "${existing_interfaces[@]}"; do
                if [[ "$iface" == "$existing" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                new_interfaces+=("$iface")
            fi
        done

        # Check for removed interfaces (in existing but not in current)
        local removed_interfaces=()
        for existing in "${existing_interfaces[@]}"; do
            local found=false
            for iface in "${current_interfaces[@]}"; do
                if [[ "$existing" == "$iface" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                removed_interfaces+=("$existing")
            fi
        done

        # Check if update is needed - if no changes, return early
        if [[ ${#new_interfaces[@]} -eq 0 ]] && [[ ${#removed_interfaces[@]} -eq 0 ]]; then
            print_success "Network interfaces in /etc/issue are up to date"
            return 0
        fi

        # Build reason message for changes
        local update_reason=""
        if [[ ${#new_interfaces[@]} -gt 0 ]]; then
            update_reason="New interface(s) detected: ${new_interfaces[*]}"
        fi

        if [[ ${#removed_interfaces[@]} -gt 0 ]]; then
            if [[ -n "$update_reason" ]]; then
                update_reason="${update_reason}; "
            fi
            update_reason="${update_reason}Interface(s) no longer exist: ${removed_interfaces[*]}"
        fi

        print_warning "$update_reason"
    else
        # No existing configuration
        print_info "No network interface configuration found in /etc/issue"
    fi

    echo ""

    # Prompt user to update
    # Default to 'n' inside containers, 'y' everywhere else
    local default_update="y"
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        default_update="n"
    fi

    print_info "Login banner (/etc/issue) network interface configuration:"
    echo "          - This will add network interface IP addresses to /etc/issue login banner."
    echo "          - The addresses will be displayed dynamically at login time."
    echo ""

    if ! prompt_yes_no "          Would you like to update /etc/issue?" "$default_update"; then
        print_info "- Keeping current /etc/issue configuration (no changes made)"
        return 0
    fi

    echo ""

    # Backup /etc/issue
    backup_file /etc/issue

    # Check if previous network section exists and track its position
    local box_exists=false
    local insert_line=""

    if grep -q "║ Network Interfaces" /etc/issue; then
        box_exists=true
        print_info "Removing previous network interface configuration from /etc/issue..."

        # Find line with Network Interfaces header
        local header_line=$(grep -n "║ Network Interfaces" /etc/issue | cut -d: -f1 | head -1)

        if [[ -n "$header_line" ]] && [[ $header_line -gt 1 ]]; then
            # Find the top border (line before header)
            local top_border=$((header_line - 1))
            insert_line=$top_border

            # Find the bottom border (line with ╚═══...), accounting for leading whitespace
            local bottom_border=$(tail -n +$top_border /etc/issue | grep -n "^\s*╚═" | head -1 | cut -d: -f1)

            if [[ -n "$bottom_border" ]]; then
                # Calculate absolute line number of bottom border
                bottom_border=$((top_border + bottom_border - 1))

                # Delete only the box lines (from top border to bottom border)
                sed -i.bak "${top_border},${bottom_border}d" /etc/issue && rm -f /etc/issue.bak
            fi
        fi
    fi

    # Add network interface section
    print_info "Adding network interface information to /etc/issue..."

    # Create temporary file with new box content
    local temp_box=$(mktemp)

    # Add box with network interfaces (left-side only, right-side open for dynamic IP lengths)
    echo "  ╔═══════════════════════════════════════════════════════════════════════════" > "$temp_box"
    echo "  ║ Network Interfaces" >> "$temp_box"
    echo "  ╠═══════════════════════════════════════════════════════════════════════════" >> "$temp_box"

    # Add wired interfaces
    for iface in "${wire_interfaces[@]}"; do
        echo "  ║ - wire: \\4{${iface}} / \\6{${iface}} (${iface})" >> "$temp_box"
    done

    # Add wireless interfaces
    for iface in "${wifi_interfaces[@]}"; do
        echo "  ║ - wifi: \\4{${iface}} / \\6{${iface}} (${iface})" >> "$temp_box"
    done

    # Add other interfaces with their type
    for iface_info in "${other_interfaces[@]}"; do
        local iface="${iface_info%%:*}"
        local type="${iface_info##*:}"
        echo "  ║ - ${type}: \\4{${iface}} / \\6{${iface}} (${iface})" >> "$temp_box"
    done

    echo "  ╚═══════════════════════════════════════════════════════════════════════════" >> "$temp_box"

    # Insert the box at the appropriate position
    if [[ "$box_exists" == true ]] && [[ -n "$insert_line" ]]; then
        # Insert at the same line position where the old box was
        # Since sed 'r' inserts after the line, we need to insert after the line before our target
        local insert_after=$((insert_line - 1))
        if [[ $insert_after -lt 1 ]]; then
            # Special case: insert at beginning of file
            cat "$temp_box" /etc/issue > /etc/issue.tmp && mv -f /etc/issue.tmp /etc/issue
        else
            sed -i.bak "${insert_after}r ${temp_box}" /etc/issue && rm -f /etc/issue.bak
        fi
    else
        # Initial setup: append to end with blank lines for spacing
        # Ensure there's a blank line before our section
        if [[ -s /etc/issue ]] && [[ $(tail -c 1 /etc/issue | wc -l) -eq 0 ]]; then
            echo "" >> /etc/issue
        fi

        cat "$temp_box" >> /etc/issue

        # Add trailing blank lines for better visibility (only on initial setup)
        echo "" >> /etc/issue
    fi

    # Clean up temporary file
    rm -f "$temp_box"

    print_success "✓ /etc/issue updated with network interface information"
    echo ""
    print_info "Current /etc/issue content:"
    cat /etc/issue
}

# Configure shell prompt colors for system-wide configuration
configure_shell_prompt_colors_system() {
    local os="$1"

    # Determine shell config file based on OS
    local shell_config
    if [[ "$os" == "macos" ]]; then
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
    local ps1_check_pattern
    local custom_ps1_pattern
    if [[ "$os" == "macos" ]]; then
        # macOS zsh prompt
        custom_ps1_pattern="PS1='[%F{247}%m%f:%F{%(!.red.green)}%n%f] %B%F{cyan}%~%f%b %#%(!.%F{red}%B!!%b%f.) '"
        ps1_check_pattern="$custom_ps1_pattern"
    else
        # Linux bash prompt - conditional for root vs non-root
        # We'll use a marker comment to check if it's already configured
        ps1_check_pattern="# Custom PS1 - conditional for root/non-root"
        custom_ps1_pattern="    # Custom PS1 - conditional for root/non-root
    if [ \"\$EUID\" -eq 0 ]; then
        # Root user - red username with !! warning
        PS1='[\[\e[90m\]\h\[\e[0m\]:\[\e[91m\]\u\[\e[0m\]] \[\e[96;1m\]\w\[\e[0m\] \\$\[\e[91;1m\]!!\[\e[0m\] '
    else
        # Non-root user - green username
        PS1='[\[\e[90m\]\h\[\e[0m\]:\[\e[92m\]\u\[\e[0m\]] \[\e[96;1m\]\w\[\e[0m\] \\$ '
    fi"
    fi

    # Check if we already have our custom PS1
    if grep -qF "$ps1_check_pattern" "$shell_config" 2>/dev/null; then
        print_success "- Custom PS1 prompt already configured"
        return 0
    fi

    # Backup the config file
    backup_file "$shell_config"

    # Check how many PS1 definitions exist
    local ps1_count
    ps1_count=$(grep -c "^[[:space:]]*PS1=" "$shell_config" 2>/dev/null || echo "0")

    if [[ "$ps1_count" -eq 0 ]]; then
        # No existing PS1, just add at the end
        add_change_header "$shell_config" "shell"
        echo "# Custom colored prompt - managed by system-setup.sh" >> "$shell_config"
        echo "$custom_ps1_pattern" >> "$shell_config"
        echo "" >> "$shell_config"
        print_success "✓ Custom colored PS1 prompt configured in $shell_config"
    elif [[ "$ps1_count" -eq 1 ]]; then
        # Exactly one PS1 definition - comment it out and add new one immediately after
        print_info "Commenting out existing PS1 definition..."

        # Find the line number of the PS1 definition
        local ps1_line_num
        ps1_line_num=$(grep -n "^[[:space:]]*PS1=" "$shell_config" | cut -d: -f1)

        # Comment out the line
        sed -i.bak "${ps1_line_num}s/^\([[:space:]]*\)\(PS1=.*\)/\1# \2  # Replaced by system-setup.sh on $(date +%Y-%m-%d)/" "$shell_config" && rm -f "${shell_config}.bak"

        # Create a temporary file with the new PS1 content
        local temp_ps1
        temp_ps1=$(mktemp)
        {
            echo ""
            echo "    # ─────────────────────────────────────────────────────────────────────────────"
            echo "    # shell configuration - managed by system-setup.sh"
            echo "    # Last updated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "    # ─────────────────────────────────────────────────────────────────────────────"
            echo "    # Custom colored prompt - managed by system-setup.sh"
            echo "$custom_ps1_pattern"
        } > "$temp_ps1"

        # Insert the new content after the commented line
        sed -i.bak "${ps1_line_num}r ${temp_ps1}" "$shell_config" && rm -f "${shell_config}.bak"
        rm -f "$temp_ps1"

        print_success "✓ Custom colored PS1 prompt configured immediately after commented line"
    else
        # Multiple PS1 definitions - comment them all out, add at end, and prompt user
        print_warning "Found $ps1_count PS1 definitions in $shell_config"
        print_info "Commenting out all PS1 definitions..."

        # Comment out all PS1 lines
        sed -i.bak "s/^\([[:space:]]*\)\(PS1=.*\)/\1# \2  # Replaced by system-setup.sh on $(date +%Y-%m-%d)/" "$shell_config" && rm -f "${shell_config}.bak"

        # Add new PS1 at the end
        add_change_header "$shell_config" "shell"
        echo "# Custom colored prompt - managed by system-setup.sh" >> "$shell_config"
        echo "$custom_ps1_pattern" >> "$shell_config"
        echo "" >> "$shell_config"

        # Provide instructions and wait
        echo ""
        echo -e "${YELLOW}╔═════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║                                                                         ║${NC}"
        echo -e "${YELLOW}║    Multiple PS1 definitions were found and commented out.               ║${NC}"
        echo -e "${YELLOW}║    The new PS1 has been added at the end of the file.                   ║${NC}"
        echo -e "${YELLOW}║                                                                         ║${NC}"
        echo -e "${YELLOW}║    Please review the file to ensure proper placement.                   ║${NC}"
        echo -e "${YELLOW}║    nano will open for manual verification and adjustment.               ║${NC}"
        echo -e "${YELLOW}║                                                                         ║${NC}"
        echo -e "${YELLOW}╚═════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -n 1 -s -r -p "Press any key to open nano and review $shell_config..."
        echo ""

        # Open nano for user to review/edit
        nano "$shell_config"

        print_success "✓ File reviewed and saved"
    fi
}

# Comment out PS1 definitions in user config files (system scope only)
configure_shell_prompt_colors_user() {
    local os="$1"
    local home_dir="$2"
    local username="$3"

    # Determine shell config file based on OS
    local shell_config
    if [[ "$os" == "macos" ]]; then
        shell_config="${home_dir}/.zshrc"
    else
        shell_config="${home_dir}/.bashrc"
    fi

    # Skip if home directory doesn't exist
    if [[ ! -d "$home_dir" ]]; then
        return 0
    fi

    # Skip if config file doesn't exist
    if [[ ! -f "$shell_config" ]]; then
        return 0
    fi

    # Check if there are any uncommented PS1 definitions that we would actually modify
    local has_ps1_to_comment=false
    if [[ "$os" == "macos" ]]; then
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
    if [[ "$os" == "macos" ]]; then
        # macOS: Comment out ALL PS1 definitions
        sed -i.bak "s/^\([[:space:]]*\)\(PS1=.*\)/\1# \2  # Commented out by system-setup.sh on $(date +%Y-%m-%d)/" "$shell_config" && rm -f "${shell_config}.bak"
    else
        # Linux: Comment out all PS1 definitions EXCEPT those starting with: PS1="\[\e]0;
        # This preserves the terminal title escape sequences
        sed -i.bak "/^[[:space:]]*PS1=\"\\\\\[\\\\e\]0;/! s/^\([[:space:]]*\)\(PS1=.*\)/\1# \2  # Commented out by system-setup.sh on $(date +%Y-%m-%d)/" "$shell_config" && rm -f "${shell_config}.bak"
    fi

    # Restore ownership if running as root
    if [[ $EUID -eq 0 ]] && [[ "$username" != "root" ]]; then
        chown "$username:$username" "$shell_config" 2>/dev/null || true
    fi

    print_success "✓ PS1 definitions commented out in $shell_config"
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
}

# Configure shell
configure_shell() {
    local os="$1"
    local scope="$2"  # "user" or "system"

    print_info "Configuring shell..."
    echo ""

    if [[ "$scope" == "system" ]]; then
        # Configure root user
        print_info "Configuring shell for root..."
        configure_shell_for_user "$os" "/root" "root"
        configure_shell_prompt_colors_user "$os" "/root" "root"
        echo ""

        # System-wide configuration: iterate over all users in /home/
        if [[ -d "/home" ]]; then
            # Find all user home directories in /home
            local user_count=0
            for user_home in /home/*; do
                if [[ -d "$user_home" ]]; then
                    local username=$(basename "$user_home")
                    print_info "Configuring shell for $username..."
                    configure_shell_for_user "$os" "$user_home" "$username"
                    configure_shell_prompt_colors_user "$os" "$user_home" "$username"
                    echo ""
                    ((user_count++)) || true
                fi
            done

            if [[ $user_count -gt 0 ]]; then
                print_success "Configured shell for root and $user_count user(s)"
            fi
        fi
    else
        # User-specific configuration: configure for current user only
        print_info "Configuring shell for current user..."
        configure_shell_for_user "$os" "$HOME" "$(whoami)"
    fi

    print_info "Note: Users may need to run 'source ~/.bashrc' (or ~/.zshrc) or restart their terminal for changes to take effect."

    if [[ "$scope" == "system" ]]; then
        echo ""
        # Configure system-wide prompt colors
        configure_shell_prompt_colors_system "$os"
    fi
}

# Configure swap memory
configure_swap() {
    local os="$1"

    # Swap configuration is only relevant for Linux systems
    if [[ "$os" != "linux" ]]; then
        print_info "Swap configuration is only applicable to Linux systems"
        return 0
    fi

    # Check if running inside a container
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        print_info "Detected container environment: Swap configuration is not recommended inside containers"
        return 0
    fi

    print_info "Checking swap configuration..."

    # Check if swap is currently enabled
    local swap_status=$(swapon --show 2>/dev/null)

    if [[ -n "$swap_status" ]]; then
        print_success "- Swap is already enabled:"
        echo "- $swap_status"
        return 0
    fi

    print_info "- Swap is currently disabled"
    echo ""
    print_info "Recommended swap sizes:"
    echo "          • ≤2 GB RAM: 2x RAM"
    echo "          • >2 GB RAM: 1.5x RAM"
    echo ""

    if ! prompt_yes_no "          Would you like to set up swap?" "n"; then
        print_info "- Keeping swap disabled (no changes made)"
        return 0
    fi
    echo ""

    print_info "Configuring swap memory..."

    # Get total RAM in GB
    local ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
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
    print_success "✓ Swap file created (${swap_gb} GB)"

    # Set correct permissions
    if ! chmod 600 "$swapfile"; then
        print_error "Failed to set permissions on swap file"
        rm -f "$swapfile"
        return 1
    fi
    print_success "✓ Updated permissions on swap file (chmod)"

    # Format as swap
    if ! mkswap "$swapfile" 2>&1 | tail -n 1; then
        print_error "Failed to format swap file"
        rm -f "$swapfile"
        return 1
    fi
    print_success "✓ Formatted swap file (mkswap)"

    # Enable swap
    if ! swapon "$swapfile"; then
        print_error "Failed to enable swap"
        rm -f "$swapfile"
        return 1
    fi
    print_success "✓ Swap enabled successfully"
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

        print_success "✓ Swap entry added to /etc/fstab"
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
    echo -e "${YELLOW}╔═════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║                                                                         ║${NC}"
    echo -e "${YELLOW}║    You can customize the socket configuration here.                     ║${NC}"
    echo -e "${YELLOW}║    Examples: change port, add ListenStream, etc.                        ║${NC}"
    echo -e "${YELLOW}║                                                                         ║${NC}"
    echo -e "${YELLOW}║    nano will open for manual configuration and adjustment.              ║${NC}"
    echo -e "${YELLOW}║                                                                         ║${NC}"
    echo -e "${YELLOW}╚═════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -n 1 -s -r -p "Press any key to open nano and configure ssh.socket..."
    echo ""

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

# Configure static IP address for containers
configure_container_static_ip() {
    local os="$1"

    # Only applicable for Linux containers
    if [[ "$os" != "linux" ]]; then
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

    if [[ -f "$network_file" ]]; then
        if grep -q "^\[Address\]" "$network_file" 2>/dev/null; then
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
            for octet in "${OCTETS[@]}"; do
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

# Print a summary of all changes made
print_summary() {
    if [[ ${#BACKED_UP_FILES[@]} -eq 0 && ${#CREATED_BACKUP_FILES[@]} -eq 0 ]]; then
        print_info "No files were modified during this session."
        return
    fi

    echo ""
    print_info "─────────────────── Session Summary ───────────────────"
    echo ""

    if [[ ${#BACKED_UP_FILES[@]} -gt 0 ]]; then
        print_success "Files Modified:"
        for file in "${BACKED_UP_FILES[@]}"; do
            echo "          - $file"
        done
        echo ""
    fi

    if [[ ${#CREATED_BACKUP_FILES[@]} -gt 0 ]]; then
        print_backup "Backup Files Created:"
        for file in "${CREATED_BACKUP_FILES[@]}"; do
            echo "          - $file"
        done
        echo ""
    fi
    print_info "───────────────────────────────────────────────────────"
}

# Main function
main() {
    print_info "System Setup and Configuration Script (Idempotent Mode)"
    echo "          ======================================================="

    local os=$(detect_os)
    echo "          - Detected OS: $os"

    if [[ "$os" == "unknown" ]]; then
        print_error "Unknown operating system. This script supports Linux and macOS."
        exit 1
    fi

    # Detect if running in a container (sets RUNNING_IN_CONTAINER global variable)
    detect_container
    if [[ "$RUNNING_IN_CONTAINER" == true ]]; then
        echo "          - Running inside a container environment"

        # Offer to configure static IP for containers
        echo ""
        configure_container_static_ip "$os"
    fi
    echo ""

    # Modernize APT sources (Linux only)
    if [[ "$os" == "linux" ]]; then
        modernize_apt_sources "$os"
        echo ""
    fi

    # Check and install packages
    print_info "Step 1: Package Management"
    print_info "---------------------------"
    if ! check_and_install_packages "$os"; then
        print_error "Package management failed. Continuing with configuration for installed packages..."
    fi
    echo ""

    # Get user preferences
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
    print_info "Choose configuration scope:"
    echo "          1) User-specific - nano/screen/shell for current user"
    echo "          2) System-wide (root) - nano/screen system-wide, /etc/issue, shell all users, swap, SSH socket"
    echo "          Ctrl+C to cancel configuration and exit"
    echo ""
    read -p "          Enter choice (1-2): " -r scope_choice

    local scope
    case "$scope_choice" in
        1) scope="user" ;;
        2) scope="system" ;;
        *)
            print_error "Invalid choice. Aborting."
            exit 1
            ;;
    esac

    print_info "Using scope: $scope"
    echo ""

    # Configure each component
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

    # Configure /etc/issue with network interfaces if system scope (Linux only)
    if [[ "$scope" == "system" ]]; then
        configure_issue_network "$os"
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

    print_summary
    echo ""

    print_info "The script made only necessary changes to bring your configuration up to date."
    print_info "You may need to restart your terminal or source your shell configuration file for all changes to take effect."
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
