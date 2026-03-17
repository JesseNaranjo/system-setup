#!/usr/bin/env bash

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
        print_warning "Neither 'curl' nor 'wget' found - self-update disabled"
        print_info "Install curl or wget to enable automatic updates"
        return 1
    fi
}

# Download script from remote repository
download_script() {
    local script_file="$1"
    local output_file="$2"
    local http_status=""

    print_info "Fetching ${script_file}..."
    echo "            ▶ ${REMOTE_BASE}/${script_file}..."

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
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
    local TEMP_SCRIPT_FILE="$(mktemp)"

    if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
        rm -f "${TEMP_SCRIPT_FILE}"
        echo ""
        return 1
    fi

    # Compare versions
    if diff -q "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
        print_success "- Script is already up-to-date"
        rm -f "${TEMP_SCRIPT_FILE}"
        return 0
    fi

    # Show diff
    echo ""
    echo -e "${CYAN}╭────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${NC}"
    diff -u --color "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" || true
    echo -e "${CYAN}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${NC}"
    echo ""

    read -p "→ Overwrite and restart with updated ${SCRIPT_FILE}? [Y/n] " -n 1 -r
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        echo ""
        chmod +x "${TEMP_SCRIPT_FILE}"
        mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"
        print_success "✓ Updated ${SCRIPT_FILE} - restarting..."
        echo ""
        export scriptUpdated=1
        exec "${LOCAL_SCRIPT}" "$@"
        exit 0
    else
        print_warning "⚠ Skipped update - continuing with local version"
        rm -f "${TEMP_SCRIPT_FILE}"
    fi
    echo ""
}


# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    # Check for updates if download tool available
    if detect_download_cmd && [[ ${scriptUpdated:-0} -eq 0 ]]; then
        self_update "$@"
        echo ""
    fi

    # ====================================================================================================
    # This script sets the MTU of the eth0 interface to 1200 to fix issues with git commands.

    # The problem stems from the MTU being too high in certain network configurations,
    # leading to timeouts / failed connections / stalls (no output) when performing git operations.

    # Simple commands like `git fetch` or `git clone` may fail due to packet fragmentation or loss.
    # To resolve this, set the MTU to a lower value.
    MTU=1200
    current_mtu=$(cat /sys/class/net/eth0/mtu)
    if [[ "$current_mtu" != "$MTU" ]]; then
        echo "Setting MTU to $MTU..."
        sudo ip link set dev eth0 mtu "$MTU"
        echo
    fi
    # ====================================================================================================

    echo "Downloading / Updating nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash

    echo
    if [[ -z "$NVM_DIR" ]]; then export NVM_DIR="$HOME/.nvm"; fi
    . "$NVM_DIR/nvm.sh"                # This loads nvm
    nvm install --latest-npm stable    # install and use stable
    nvm use stable

    echo
    npm install -g typescript-language-server typescript
    npm update -g

    echo
    dotnet tool update --global --all
    dotnet tool install --global csharp-ls

    DEFAULT_SETTINGS=$(cat <<EOF
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
        "playwright@claude-plugins-official": true,
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
            "Bash(git check-ignore:*)",
            "Bash(git log:*)",
            "Bash(git rev-parse:*)",
            "Bash(git show:*)",
            "Bash(git status:*)",
            "Bash(git worktree:*)",
            "Bash(npm info:*)",
            "Skill(code-review:*)",
            "Skill(frontend-design:*)",
            "Skill(superpowers:*)",
            "WebSearch"
        ],
        "defaultMode": "plan",
        "disableBypassPermissionsMode": "disable"
    }
}
EOF
)
    jq --sort-keys --argjson default "$DEFAULT_SETTINGS" '. * $default' ~/.claude/settings.json > ~/.claude/settings.tmp.json && mv ~/.claude/settings.tmp.json ~/.claude/settings.json

    echo
    claude update
    sleep 1s
    claude plugins marketplace update
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
