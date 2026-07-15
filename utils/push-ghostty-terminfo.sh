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
# All per-run SSH connections are multiplexed over one ControlMaster socket, so you
# authenticate to the host at most once. On a TTY that single auth may be interactive (SSH
# password or key passphrase); without a TTY (cron, ssh -T) it falls back to
# BatchMode and requires key-based auth. The remote sudo password (system-wide mode)
# is entered on a TTY via `ssh -t` over the same shared connection.
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
CTL_DIR=""               # private dir holding the SSH ControlMaster socket (rm'd by cleanup)
SSH_CTL=""               # ControlPath (socket) for connection multiplexing
SSH_OPTS=()              # ssh opts for every REUSE call; set by open_ssh_master once the master is up

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
    # the privileged compile. Reuse the master (always up when a temp exists);
    # BatchMode + ConnectTimeout so cleanup never blocks on a prompt.
    if [[ -n "$REMOTE_TMP" && -n "$REMOTE_CLEANUP_HOST" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=5 -o ControlPath="$SSH_CTL" \
            "$REMOTE_CLEANUP_HOST" "rm -f '${REMOTE_TMP}'" 2>/dev/null || true
    fi
    # Close the SSH master and remove its private socket dir. ControlPersist=60 is
    # the backstop if this never runs (SIGKILL/power-loss).
    if [[ -n "$SSH_CTL" && -S "$SSH_CTL" ]]; then
        ssh -o ControlPath="$SSH_CTL" -O exit "$REMOTE_CLEANUP_HOST" 2>/dev/null || true
    fi
    # `if/fi` (not bare `[[ ]] &&`), always paired with `|| true`: this is the EXIT
    # trap, so its own exit status becomes the script's exit status unless it's 0
    # (bash preserves the original `exit N` only when the trap's last command
    # succeeds). A bare `&&` here would silently clobber every exit code (0/64/etc.)
    # to 1 whenever CTL_DIR is unset (e.g. --help, bad args — before
    # open_ssh_master ever runs).
    if [[ -n "$CTL_DIR" ]]; then
        rm -rf "$CTL_DIR" 2>/dev/null || true
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

${YELLOW}Auth:${NC} connections are multiplexed over one SSH ControlMaster, so you
  authenticate to the host at most once. Interactive auth (password/passphrase) works
  on a TTY; non-interactive runs (cron, ssh -T) require key-based auth. System-wide
  mode also prompts once for the remote sudo password (see Default above).

${YELLOW}Exit codes:${NC} 0 OK | 64 usage | 68 no-host | 69 missing-tool | 70 install-failed
EOF
}

# open_ssh_master <host>  -> establish a multiplexed SSH master connection.
# Sets CTL_DIR, SSH_CTL, SSH_OPTS. This IS the connectivity + auth gate: on a TTY
# it allows ONE interactive prompt (SSH password or key passphrase) that every
# later connection then shares; without a TTY (cron, ssh -T, setsid) it uses
# BatchMode and fails cleanly if key auth isn't set up. `-f` backgrounds the master
# AFTER auth (ssh(1)), so a prompt shows in the foreground first. Fatal on failure.
open_ssh_master() {
    local host="$1"
    CTL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pgt-ssh.XXXXXX")"
    SSH_CTL="${CTL_DIR}/cm.sock"

    # No openable TTY -> require non-interactive (key) auth so we never hang a
    # cron/ssh -T run on a password prompt. Same open(2) probe as prompt_yes_no.
    local batch=()
    if ! { : </dev/tty; } 2>/dev/null; then
        batch=(-o BatchMode=yes)
    fi

    print_info "Connecting to ${host}..."
    if ! ssh "${batch[@]+"${batch[@]}"}" \
        -o ControlMaster=yes -o ControlPath="$SSH_CTL" \
        -o ControlPersist=60 -o ConnectTimeout=10 -fN "$host"; then
        print_error "✖ Cannot establish an SSH connection to ${host}"
        print_info "Verify the host is reachable and your SSH credentials are valid."
        print_info "Non-interactive runs (cron, ssh -T) require key-based auth."
        exit 68
    fi

    # Every later connection reuses the now-authenticated master. BatchMode is a
    # safety net: if the master died, reuse calls fail cleanly instead of prompting.
    SSH_OPTS=(-o BatchMode=yes -o ControlPath="$SSH_CTL")
    print_success "✓ Connected to ${host}"
}

# entry_present <host> <user_mode>  -> 0 if xterm-ghostty resolves at the target scope.
# Uses `infocmp -A <dir>` to scope the lookup to exactly <dir> (verified: no fallback to the
# system db or $HOME/.terminfo), so it is layout-agnostic (directory-tree AND hashed
# terminfo.db) and a per-user copy can't mask a missing system entry. Reuses infocmp, already
# required by the remote preflight.
entry_present() {
    local host="$1" user_mode="$2"
    if [[ "$user_mode" == true ]]; then
        ssh "${SSH_OPTS[@]}" "$host" 'infocmp -A "$HOME/.terminfo" -x '"${TERM_NAME}"' >/dev/null 2>&1'
    else
        # SYSTEM_TERMINFO_DIR/TERM_NAME are local readonly constants, intentionally
        # expanded client-side into the remote command string.
        # shellcheck disable=SC2029
        ssh "${SSH_OPTS[@]}" "$host" "infocmp -A ${SYSTEM_TERMINFO_DIR} -x ${TERM_NAME} >/dev/null 2>&1"
    fi
}

# install_entry <host> <user_mode> <local_ti>
install_entry() {
    local host="$1" user_mode="$2" ti="$3"

    if [[ "$user_mode" == true ]]; then
        print_info "Installing ${TERM_NAME} for the login user on ${host} (~/.terminfo)..."
        if ! printf '%s\n' "$ti" | ssh "${SSH_OPTS[@]}" "$host" 'mkdir -p "$HOME/.terminfo" && tic -x -o "$HOME/.terminfo" -'; then
            print_error "✖ Per-user terminfo install failed on ${host}"
            exit 70
        fi
        return 0
    fi

    # System-wide. If the remote login user is already root, write the system dir
    # directly — no sudo (may be absent on minimal images), no TTY needed.
    local remote_uid
    remote_uid="$(ssh "${SSH_OPTS[@]}" "$host" 'id -u' 2>/dev/null || echo)"
    if [[ "$remote_uid" == "0" ]]; then
        print_info "Installing ${TERM_NAME} system-wide on ${host} (remote user is root)..."
        # SYSTEM_TERMINFO_DIR is a local readonly constant, intentionally expanded
        # client-side into the remote command string.
        # shellcheck disable=SC2029
        if ! printf '%s\n' "$ti" | ssh "${SSH_OPTS[@]}" "$host" "tic -x -o ${SYSTEM_TERMINFO_DIR} -"; then
            print_error "✖ System-wide terminfo install failed on ${host}"
            exit 70
        fi
        return 0
    fi

    # Non-root: (1) stage to a remote temp non-interactively, capturing its path;
    # (2) privileged compile on a TTY so sudo can prompt; (3) remove the temp.
    print_info "Staging terminfo on ${host}..."
    if ! REMOTE_TMP="$(printf '%s\n' "$ti" | ssh "${SSH_OPTS[@]}" "$host" \
        'f=$(mktemp "${TMPDIR:-/tmp}/ghostty-terminfo.XXXXXX") && { cat >"$f" && printf %s "$f" || { rm -f "$f"; exit 1; }; }')" \
        || [[ -z "$REMOTE_TMP" ]]; then
        print_error "✖ Failed to stage terminfo on ${host}"
        exit 70
    fi

    print_info "Installing system-wide (may prompt for the sudo password on ${host})..."
    if ! ssh -t "${SSH_OPTS[@]}" "$host" "sudo tic -x -o ${SYSTEM_TERMINFO_DIR} '${REMOTE_TMP}'; rc=\$?; rm -f '${REMOTE_TMP}'; exit \$rc"; then
        print_error "✖ System-wide terminfo install failed on ${host}"
        exit 70     # trap best-effort removes REMOTE_TMP
    fi
    REMOTE_TMP=""  # step 2 already removed it; disarm the trap
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
        self_update "${original_args[@]+"${original_args[@]}"}" || true
        echo ""
    fi

    local host="" user_mode=false force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)  user_mode=true ;;
            --force) force=true ;;
            -*)      print_error "✖ Unknown option: $1"; show_usage; exit 64 ;;
            *)
                if [[ -n "$host" ]]; then
                    print_error "✖ Only one host may be specified (got '$host' and '$1')"
                    exit 64
                fi
                host="$1"
                ;;
        esac
        shift
    done
    [[ -z "$host" ]] && { print_error "✖ No host specified"; show_usage; exit 64; }
    REMOTE_CLEANUP_HOST="$host"

    command -v ssh >/dev/null 2>&1 || { print_error "✖ 'ssh' not found"; exit 69; }
    command -v infocmp >/dev/null 2>&1 || { print_error "✖ 'infocmp' not found (install ncurses)"; exit 69; }

    local local_ti
    if ! local_ti="$(infocmp -x "$TERM_NAME" 2>/dev/null)"; then
        print_error "✖ Local '${TERM_NAME}' terminfo not found — is Ghostty installed on this host?"
        exit 69
    fi

    open_ssh_master "$host"

    if ! ssh "${SSH_OPTS[@]}" "$host" \
        'command -v tic >/dev/null 2>&1 && command -v infocmp >/dev/null 2>&1'; then
        print_error "✖ ${host} lacks 'tic'/'infocmp' — install ncurses (Debian/Ubuntu: ncurses-bin)"
        exit 69
    fi

    local scope_label="system-wide (all users incl. root)"
    [[ "$user_mode" == true ]] && scope_label="the login user only (~/.terminfo)"

    if [[ "$force" == false ]] && entry_present "$host" "$user_mode"; then
        print_success "- ${TERM_NAME} already installed ${scope_label} on ${host} — use --force to reinstall"
        exit 0
    fi

    # No confirmation prompt: the action is low-risk, explicitly targeted, and
    # idempotent (the pre-check above already skips redundant installs). Requiring
    # a y/n would also make --user a silent no-op in non-interactive automation.
    install_entry "$host" "$user_mode" "$local_ti"

    if entry_present "$host" "$user_mode"; then
        print_success "✓ ${TERM_NAME} installed ${scope_label} on ${host}"
    else
        print_error "✖ Post-install verification failed: entry not found at the target scope on ${host}"
        exit 70
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
