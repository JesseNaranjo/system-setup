#!/usr/bin/env bash
# tools-update.sh - Updates developer tools and fixes container network issues
#
# Usage: ./tools-update.sh

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Self-update configuration
readonly REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/utils"
DOWNLOAD_CMD=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ============================================================================
# Output Functions
# ============================================================================

print_info() {
    echo -e "${BLUE}[ INFO    ]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[ SUCCESS ]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ WARNING ]${NC} $1"
}

print_error() {
    echo -e "${RED}[ ERROR   ]${NC} $1"
}

# Usage: print_warning_box "line1" "line2" "line3" ...
# Each line will be padded to fit within the box
print_warning_box() {
    local box_width=77
    local padding=8
    local content_width=$((box_width - padding - 1))

    echo ""
    echo -e "            ${YELLOW}╔$(printf '═%.0s' $(seq 1 $box_width))╗${NC}"
    echo -e "            ${YELLOW}║$(printf ' %.0s' $(seq 1 $box_width))║${NC}"

    for line in "$@"; do
        local line_len=${#line}
        local right_pad=$((content_width - line_len))
        if [[ $right_pad -lt 0 ]]; then
            right_pad=0
            line="${line:0:$content_width}"
        fi
        printf -v padded_line "%-${content_width}s" "$line"
        echo -e "            ${YELLOW}║        ${padded_line}║${NC}"
    done

    echo -e "            ${YELLOW}║$(printf ' %.0s' $(seq 1 $box_width))║${NC}"
    echo -e "            ${YELLOW}╚$(printf '═%.0s' $(seq 1 $box_width))╝${NC}"
    echo ""
}


# ============================================================================
# Utility Functions
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

    # Read from /dev/tty to work correctly in piped contexts
    read -p "$prompt_message $prompt_suffix: " -r user_reply </dev/tty

    # If user just pressed Enter (empty reply), use default
    if [[ -z "$user_reply" ]]; then
        [[ "${default,,}" == "y" ]]
    else
        [[ $user_reply =~ ^[Yy]$ ]]
    fi
}

RUNNING_IN_CONTAINER=false

detect_container() {
    # Check for LXC container via environment variable
    if [[ -f /proc/1/environ ]] && grep -qa container=lxc /proc/1/environ 2>/dev/null; then
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

TEMP_FILES=()

make_temp_file() {
    local tmp
    tmp=$(mktemp)
    TEMP_FILES+=("$tmp")
    echo "$tmp"
}


# ============================================================================
# Self-Update Functionality
# ============================================================================

# Detect available download command (curl or wget)
detect_download_cmd() {
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
        return 0
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
        return 0
    else
        DOWNLOAD_CMD=""
        print_warning_box \
            "UPDATES NOT AVAILABLE" \
            "" \
            "Neither 'curl' nor 'wget' is installed on this system." \
            "Self-updating functionality requires one of these tools."
        return 1
    fi
}

# Download script from remote repository
download_script() {
    local script_file="$1"
    local output_file="$2"
    local http_status=""

    print_info "Fetching ${script_file}..."
    print_info "  → ${REMOTE_BASE}/${script_file}"

    if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
        http_status=$(curl -H 'Cache-Control: no-cache, no-store' -o "${output_file}" -w "%{http_code}" -fsSL "${REMOTE_BASE}/${script_file}" 2>/dev/null || echo "000")
        if [[ "$http_status" == "200" ]]; then
            # Validate that we got a script, not an error page
            # Check first 10 lines for shebang to handle files with leading comments/blank lines
            if head -n 10 "${output_file}" | grep -q "^#!/"; then
                return 0
            else
                print_error "✖ Invalid content received (not a script)"
                return 1
            fi
        elif [[ "$http_status" == "429" ]]; then
            print_error "✖ Rate limited by GitHub (HTTP 429)"
            return 1
        elif [[ "$http_status" != "000" ]]; then
            print_error "✖ HTTP ${http_status} error"
            return 1
        else
            print_error "✖ Download failed"
            return 1
        fi
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        if wget --no-cache --no-cookies -O "${output_file}" -q "${REMOTE_BASE}/${script_file}" 2>/dev/null; then
            # Validate that we got a script, not an error page
            # Check first 10 lines for shebang to handle files with leading comments/blank lines
            if head -n 10 "${output_file}" | grep -q "^#!/"; then
                return 0
            else
                print_error "✖ Invalid content received (not a script)"
                return 1
            fi
        else
            print_error "✖ Download failed"
            return 1
        fi
    fi

    return 1
}

# Check for script updates and restart if updated
self_update() {
    local SCRIPT_FILE="tools-update.sh"
    local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
    local TEMP_SCRIPT_FILE
    TEMP_SCRIPT_FILE="$(make_temp_file)"

    if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
        return 1
    fi

    # Compare versions
    if diff -q "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
        print_success "- Script is already up-to-date"
        return 0
    fi

    # Show diff
    echo ""
    echo -e "${CYAN}╭────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${NC}"
    diff -u --color "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" || true
    echo -e "${CYAN}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${NC}"
    echo ""

    if prompt_yes_no "→ Overwrite and restart with updated ${SCRIPT_FILE}?" "y"; then
        chmod +x "${TEMP_SCRIPT_FILE}"
        mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"
        print_success "✓ Updated ${SCRIPT_FILE} - restarting..."
        echo ""
        export scriptUpdated=1
        exec "${LOCAL_SCRIPT}" "$@"
        exit 0
    else
        print_warning "⚠ Skipped update - continuing with local version"
    fi
    echo ""
}


# ============================================================================
# Tool Update Functions
# ============================================================================

# Fix MTU in container environments to prevent git timeout issues
update_mtu() {
    local target_mtu=1200

    if [[ "$RUNNING_IN_CONTAINER" != true ]]; then
        print_info "- Not running in a container, skipping"
        return 0
    fi

    print_info "Running in container environment"

    if [[ ! -f /sys/class/net/eth0/mtu ]]; then
        print_warning "⚠ eth0 interface not found - skipping MTU configuration"
        return 0
    fi

    local current_mtu
    current_mtu=$(cat /sys/class/net/eth0/mtu)

    if [[ "$current_mtu" == "$target_mtu" ]]; then
        print_success "- MTU already set to ${target_mtu}"
        return 0
    fi

    # Low MTU fixes git timeouts caused by packet fragmentation in container networks
    print_info "Setting eth0 MTU from ${current_mtu} to ${target_mtu}..."
    sudo /usr/bin/ip link set dev eth0 mtu "$target_mtu"
    print_success "✓ MTU set to ${target_mtu}"
}

# Update nvm, Node.js, and global npm packages
update_nvm() {
    if [[ ! -f "$HOME/.nvm/nvm.sh" ]]; then
        print_info "- nvm not found, skipping"
        return 0
    fi

    # Download nvm install script to temp file for validation before execution
    print_info "Downloading nvm install script..."
    local nvm_script
    nvm_script="$(make_temp_file)"
    local nvm_url="https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh"
    local download_ok=false

    if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
        curl -fsSL -o "$nvm_script" "$nvm_url" 2>/dev/null && download_ok=true
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        wget -O "$nvm_script" -q "$nvm_url" 2>/dev/null && download_ok=true
    else
        print_warning "⚠ No download tool available - skipping nvm update"
        return 1
    fi

    if [[ "$download_ok" == true ]]; then
        # Same shebang validation as download_script()
        if head -n 10 "$nvm_script" | grep -q "^#!/"; then
            print_info "Updating nvm..."
            bash "$nvm_script"
        else
            print_warning "⚠ Downloaded nvm install script appears invalid - skipping"
            return 1
        fi
    else
        print_warning "⚠ Failed to download nvm install script"
        return 1
    fi

    if [[ -z "${NVM_DIR:-}" ]]; then
        export NVM_DIR="$HOME/.nvm"
    fi
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"

    print_info "Installing latest stable Node.js..."
    nvm install --latest-npm stable
    nvm use stable

    print_info "Updating global npm packages..."
    npm install -g typescript-language-server typescript || print_warning "⚠ Failed to install global npm packages"
    npm update -g || print_warning "⚠ Failed to update global npm packages"

    print_success "✓ nvm, Node.js, and npm packages updated"
}

# Update .NET global tools
update_dotnet() {
    if ! command -v dotnet &>/dev/null; then
        print_info "- dotnet not found, skipping"
        return 0
    fi

    print_info "Updating .NET global tools..."
    dotnet tool update --global --all
    # Install csharp-ls if not already present (install fails if already installed)
    dotnet tool install --global csharp-ls || print_warning "⚠ Failed to install csharp-ls"

    print_success "✓ .NET tools updated"
}

# Update Claude CLI, plugins, and merge default settings
update_claude() {
    if ! command -v claude &>/dev/null; then
        print_info "- Claude CLI not found, skipping"
        return 0
    fi

    # Merge default settings if jq and settings file are available
    if command -v jq &>/dev/null && [[ -f "$HOME/.claude/settings.json" ]]; then
        print_info "Merging default Claude settings..."
        local DEFAULT_SETTINGS
        DEFAULT_SETTINGS=$(cat <<'SETTINGS_EOF'
{
    "attribution": {
        "commit": "",
        "pr": ""
    },
    "effortLevel": "max",
    "enabledPlugins": {
        "claude-code-setup@claude-plugins-official": true,
        "claude-md-management@claude-plugins-official": true,
        "code-review@jesse-naranjo-claude-plugins": true,
        "code-simplifier@claude-plugins-official": true,
        "feature-dev@claude-plugins-official": true,
        "frontend-design@claude-plugins-official": true,
        "learning-output-style@claude-plugins-official": false,
        "microsoft-docs@claude-plugins-official": true,
        "mongodb@claude-plugins-official": true,
        "superpowers@claude-plugins-official": true,
        "typescript-lsp@claude-plugins-official": true
    },
    "env": {
        "CLAUDE_CODE_EFFORT_LEVEL": "max",
        "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
        "ENABLE_LSP_TOOL": "1"
    },
    "permissions": {
        "allow": [
            "Bash(cat:*)",
            "Bash(echo:*)",
            "Bash(find:*)",
            "Bash(git check-ignore:*)",
            "Bash(git diff:*)",
            "Bash(git log:*)",
            "Bash(git rev-parse:*)",
            "Bash(git show:*)",
            "Bash(git status:*)",
            "Bash(git worktree:*)",
            "Bash(grep:*)",
            "Bash(head:*)",
            "Bash(ln:*)",
            "Bash(ls:*)",
            "Bash(node --check:*)",
            "Bash(node --version:*)",
            "Bash(npm info:*)",
            "Bash(npm ls:*)",
            "Bash(npm run build:*)",
            "Bash(shellcheck:*)",
            "Bash(sort:*)",
            "Bash(wc:*)",
            "Skill(code-review:*)",
            "Skill(frontend-design:*)",
            "Skill(superpowers:*)",
            "WebSearch"
        ],
        "defaultMode": "plan",
        "disableBypassPermissionsMode": "disable"
    }
}
SETTINGS_EOF
)
        local tmp_settings
        tmp_settings="$(make_temp_file)"
        # Merge: defaults as base, user settings override, arrays (permissions.allow) are unioned
        if jq --sort-keys --argjson default "$DEFAULT_SETTINGS" \
            '$default * . | .permissions.allow = ([$default.permissions.allow[], .permissions.allow[]] | unique)' \
            "$HOME/.claude/settings.json" > "$tmp_settings"; then
            mv "$tmp_settings" "$HOME/.claude/settings.json"
            print_success "✓ Claude settings merged"
        else
            print_warning "⚠ Failed to merge Claude settings - jq error"
        fi
    elif ! command -v jq &>/dev/null; then
        print_warning "⚠ jq not found - skipping Claude settings merge"
    elif [[ ! -f "$HOME/.claude/settings.json" ]]; then
        print_warning "⚠ ~/.claude/settings.json not found - skipping settings merge"
    fi

    print_info "Updating Claude CLI..."
    claude update
    # Brief pause between update commands to avoid rate limiting
    sleep 0.5s

    print_info "Updating plugin marketplaces..."
    claude plugins marketplace update || print_warning "⚠ Marketplace update failed"

    print_info "Updating installed plugins..."
    claude plugins list --json 2>/dev/null \
        | jq -r '.[] | select(.enabled == true) | .id' \
        | while read -r plugin; do
            claude plugin update "$plugin" || print_warning "⚠ Failed to update $plugin"
            sleep 0.5s
        done || print_warning "⚠ Failed to retrieve plugin list"

    print_success "✓ Claude CLI and plugins updated"
}


# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    cleanup() {
        for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
            rm -f "$f" 2>/dev/null
        done
    }
    trap cleanup EXIT

    # Self-update check
    if detect_download_cmd && [[ ${scriptUpdated:-0} -eq 0 ]]; then
        self_update "$@" || true
        echo ""
    fi

    detect_container

    print_info "Step 1: Network Configuration"
    print_info "-----------------------------"
    if ! update_mtu; then
        print_error "✖ MTU configuration failed. Continuing..."
    fi
    echo ""

    print_info "Step 2: nvm & Node.js"
    print_info "---------------------"
    if ! update_nvm; then
        print_error "✖ nvm update failed. Continuing..."
    fi
    echo ""

    print_info "Step 3: .NET Tools"
    print_info "------------------"
    if ! update_dotnet; then
        print_error "✖ .NET tools update failed. Continuing..."
    fi
    echo ""

    print_info "Step 4: Claude CLI"
    print_info "------------------"
    if ! update_claude; then
        print_error "✖ Claude CLI update failed. Continuing..."
    fi
    echo ""

    print_success "Tools update complete!"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
