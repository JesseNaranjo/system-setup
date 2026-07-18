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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=utils-misc.sh
source "${SCRIPT_DIR}/utils-misc.sh"

readonly TERM_NAME="xterm-ghostty"
readonly SYSTEM_TERMINFO_DIR="/usr/share/terminfo"

REMOTE_TMP=""            # remote staging temp (system-wide mode); cleaned by trap
REMOTE_CLEANUP_HOST=""   # host to reach for remote temp cleanup
CTL_DIR=""               # private dir holding the SSH ControlMaster socket (rm'd by cleanup)
SSH_CTL=""               # ControlPath (socket) for connection multiplexing
SSH_OPTS=()              # ssh opts for every REUSE call; set by open_ssh_master once the master is up

# Runs on normal exit, SIGINT, SIGTERM. File scope so the trap is wired at load.
cleanup() {
    local f
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$f" 2>/dev/null || true
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
    # Fast path: help before any network/self-update work.
    local a
    for a in "$@"; do
        [[ "$a" == "-h" || "$a" == "--help" ]] && { show_usage; exit 0; }
    done

    sweep_stale_temps '~*.tmp.??????'
    check_for_updates "${BASH_SOURCE[0]}" "$@"

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
