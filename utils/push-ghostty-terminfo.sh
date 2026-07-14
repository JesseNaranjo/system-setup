#!/usr/bin/env bash

# push-ghostty-terminfo.sh - Install the local xterm-ghostty terminfo on a remote SSH host
#
# Usage: ./push-ghostty-terminfo.sh [--user] [--force] <user@host>
#
# Copies the local `xterm-ghostty` terminfo entry to a remote host so terminal
# apps (nano, htop, vim) work over SSH. Installs SYSTEM-WIDE by default
# (/usr/share/terminfo, via remote sudo) so all users incl. root/su resolve it;
# --user installs to the login user's ~/.terminfo (no sudo).
#
# Requires non-interactive (key-based) SSH auth. The only interactive step is the
# remote sudo password (system-wide mode), entered on a TTY via `ssh -t`.
#
# Exit codes (sysexits.h, per .ai/AI-AGENT-INSTRUCTIONS.md § standalone conventions):
#   0 OK | 64 EX_USAGE (bad args) | 68 EX_NOHOST (cannot connect)
#   | 69 EX_UNAVAILABLE (missing tool: local ssh/infocmp, remote tic/infocmp, or
#     the local xterm-ghostty terminfo entry) | 70 EX_SOFTWARE (install/verify failed)

set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

# ANSI-C ($'…') quoting so the constants hold real ESC bytes and render color in
# BOTH `echo -e` (the print_* helpers) and plain `cat` heredocs (show_usage) —
# single-quoted '\033' would print literally through `cat`. GRAY/MAGENTA are
# intentionally omitted: unused here, and an unused readonly trips shellcheck SC2034.
readonly BLUE=$'\033[0;34m'
readonly CYAN=$'\033[0;36m'
readonly GREEN=$'\033[0;32m'
readonly RED=$'\033[0;31m'
readonly YELLOW=$'\033[1;33m'
readonly NC=$'\033[0m'

readonly TERM_NAME="xterm-ghostty"
readonly SYSTEM_TERMINFO_DIR="/usr/share/terminfo"

# Self-update configuration
readonly REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/utils"
DOWNLOAD_CMD=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

TEMP_FILES=()
REMOTE_TMP=""            # remote staging temp (system-wide mode); cleaned by trap
REMOTE_CLEANUP_HOST=""   # host to reach for remote temp cleanup

# ============================================================================
# Standard Output Functions
# ============================================================================

print_error()   { echo -e "${RED}[ ERROR   ]${NC} $1" >&2; if [[ -t 2 ]]; then printf '\a' >&2; sleep 2; fi; }
print_info()    { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[ WARNING ]${NC} $1"; }

# Usage: print_warning_box "line1" "line2" "line3" ...
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

    # Non-interactive context (cron, systemd, ssh -T, CI, setsid): signal "no"
    # rather than fall through to the empty-reply branch and silently auto-accept
    # the default. Use the `{ : </dev/tty; }` open(2) probe, NOT `[[ -r /dev/tty ]]`
    # — the latter only checks permissions and stays true under setsid while
    # open() fails with ENXIO, so the read below would then misbehave.
    { : </dev/tty; } 2>/dev/null || return 1

    if [[ "${default,,}" == "y" ]]; then
        prompt_suffix="(Y/n)"
    else
        prompt_suffix="(y/N)"
    fi

    read -p "$prompt_message $prompt_suffix: " -r user_reply </dev/tty

    if [[ -z "$user_reply" ]]; then
        [[ "${default,,}" == "y" ]]
    else
        [[ $user_reply =~ ^[Yy]$ ]]
    fi
}

# Runs on normal exit, SIGINT, SIGTERM. File scope so the trap is wired at load.
cleanup() {
    local f
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$f" 2>/dev/null
    done
    # Best-effort reap of the remote staging temp if we died between staging and
    # the privileged compile. BatchMode so cleanup never blocks on a prompt.
    if [[ -n "$REMOTE_TMP" && -n "$REMOTE_CLEANUP_HOST" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_CLEANUP_HOST" \
            "rm -f '${REMOTE_TMP}'" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Defense-in-depth: at startup, reap any same-FS temp files (e.g., from a
# prior SIGKILL / power-loss / interrupted self-update) older than a normal
# run window. The EXIT trap above handles in-flight cleanup; this function
# handles what the trap couldn't fire for. TTY-aware so cron/ssh -T runs
# don't block on the prompt.
sweep_stale_temps() {
    local pattern="$1"
    local stale_files=()
    while IFS= read -r -d '' f; do
        stale_files+=("$f")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name "$pattern" -type f -mmin +10 -print0 2>/dev/null)

    [[ ${#stale_files[@]} -eq 0 ]] && return 0

    print_warning "⚠ Found ${#stale_files[@]} stale temp file(s) from a prior interrupted run:"
    for f in "${stale_files[@]}"; do
        print_warning "  - $f"
    done

    # `[[ -r /dev/tty ]]` only checks file permissions; under setsid the device
    # is world-readable but `open(2)` fails with ENXIO, so a subsequent
    # `read </dev/tty` aborts under set -e. Probe with a no-op stdin redirect
    # to detect actual openability.
    if { : </dev/tty; } 2>/dev/null; then
        # `|| true` swallows EOF (Ctrl+D) so set -e doesn't abort mid-cleanup.
        read -p "Press any key to delete and continue, Ctrl+C to abort: " -n 1 -r </dev/tty || true
        echo ""
    else
        print_warning "⚠ Non-interactive context — deleting and continuing without prompt."
    fi

    for f in "${stale_files[@]}"; do
        rm -f "$f"
    done
    print_success "✓ Cleaned up ${#stale_files[@]} stale temp file(s)"
}

# Render a unified diff between two files inside a labeled box. Pages through
# `less -RFX` when stdout is a TTY (-R passes ANSI through, -F exits if content
# fits one screen, -X skips alt-screen so output stays in scrollback); falls
# back to inline `diff` when piped or `less` is missing. `--color=always`
# forces ANSI even when piped.
show_diff_box() {
    local local_file="$1"
    local temp_file="$2"
    local label="$3"
    echo ""
    echo -e "${CYAN}╭────────────────────── Δ detected in ${label} ──────────────────────╮${NC}"
    if [[ -t 1 ]] && command -v less &>/dev/null; then
        diff -u --color=always "${local_file}" "${temp_file}" | less -RFX || true
    else
        diff -u --color=always "${local_file}" "${temp_file}" || true
    fi
    echo -e "${CYAN}╰─────────────────────────── ${label} ──────────────────────────────╯${NC}"
    echo ""
}

# ============================================================================
# Self-Update Functionality
# ============================================================================

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

download_script() {
    local script_file="$1"
    local output_file="$2"
    local http_status=""

    print_info "Fetching ${script_file}..."
    print_info "  → ${REMOTE_BASE}/${script_file}"

    if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
        http_status=$(curl -H 'Cache-Control: no-cache, no-store' \
            --max-time 15 \
            -o "${output_file}" -w "%{http_code}" -sSL \
            "${REMOTE_BASE}/${script_file}" 2>/dev/null || true)
        [[ -z "$http_status" ]] && http_status="000"
        case "$http_status" in
            200) ;;
            429) print_error "✖ Rate limited by GitHub (HTTP 429)"; rm -f "${output_file}"; return 1 ;;
            000) print_error "✖ Download failed (network/timeout)"; rm -f "${output_file}"; return 1 ;;
            *)   print_error "✖ HTTP ${http_status} error"; rm -f "${output_file}"; return 1 ;;
        esac
        if head -n 10 "${output_file}" | grep -q "^#!/"; then
            return 0
        else
            print_error "✖ Invalid content received (not a script)"
            rm -f "${output_file}"
            return 1
        fi
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        local wget_exit=0
        wget --no-cache --no-cookies \
            --timeout=15 \
            -O "${output_file}" -q "${REMOTE_BASE}/${script_file}" 2>/dev/null \
            || wget_exit=$?
        [[ "$wget_exit" -ne 0 ]] && { print_error "✖ Download failed (wget exit ${wget_exit})"; rm -f "${output_file}"; return 1; }
        if head -n 10 "${output_file}" | grep -q "^#!/"; then
            return 0
        else
            print_error "✖ Invalid content received (not a script)"
            rm -f "${output_file}"
            return 1
        fi
    fi

    return 1
}

self_update() {
    local SCRIPT_FILE="push-ghostty-terminfo.sh"
    local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
    local TEMP_SCRIPT_FILE
    TEMP_SCRIPT_FILE=$(mktemp "${SCRIPT_DIR}/~${SCRIPT_FILE}.tmp.XXXXXX")
    TEMP_FILES+=("$TEMP_SCRIPT_FILE")

    if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
        rm -f "$TEMP_SCRIPT_FILE"
        return 1
    fi

    if diff -q "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
        print_success "- Script is already up-to-date"
        rm -f "$TEMP_SCRIPT_FILE"
        return 0
    fi

    show_diff_box "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" "${SCRIPT_FILE}"

    if prompt_yes_no "→ Overwrite and restart with updated ${SCRIPT_FILE}?" "y"; then
        chmod +x "${TEMP_SCRIPT_FILE}"
        if ! mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"; then
            rm -f "$TEMP_SCRIPT_FILE"
            print_error "✖ Failed to install update — keeping local version"
            return 1
        fi
        print_success "✓ Updated ${SCRIPT_FILE} - restarting..."
        echo ""
        export scriptUpdated=1
        exec "${LOCAL_SCRIPT}" "$@"
        exit 0
    else
        rm -f "$TEMP_SCRIPT_FILE"
        print_warning "⚠ Skipped update - continuing with local version"
    fi
    echo ""
}

show_usage() {
    cat << EOF
${GREEN}push-ghostty-terminfo.sh${NC} - Install xterm-ghostty terminfo on a remote host

${YELLOW}Usage:${NC}
  push-ghostty-terminfo.sh [--user] [--force] <user@host>

${YELLOW}Arguments:${NC}
  user@host     Remote target (a bare host or ~/.ssh/config alias also works)

${YELLOW}Options:${NC}
  --user        Install for the login user only (~/.terminfo), no remote sudo
  --force       Reinstall even if the entry already exists on the remote
  -h, --help    Show this help

${YELLOW}Default:${NC} system-wide install to ${SYSTEM_TERMINFO_DIR} (all users incl. root)
  via a two-step temp-file + 'ssh -t' flow (may prompt for the remote sudo password).

${YELLOW}Exit codes:${NC} 0 OK | 64 usage | 68 no-host | 69 missing-tool | 70 install-failed
EOF
}

main() {
    local original_args=("$@")

    # Fast path: help before any network/self-update work.
    local a
    for a in "$@"; do
        [[ "$a" == "-h" || "$a" == "--help" ]] && { show_usage; exit 0; }
    done

    sweep_stale_temps '~*.tmp.??????'

    if detect_download_cmd && [[ ${scriptUpdated:-0} -eq 0 ]]; then
        self_update "${original_args[@]}" || true
        echo ""
    fi

    # (Task 2 fills in: parse args, preflight, connectivity, install, verify.)
    :
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
