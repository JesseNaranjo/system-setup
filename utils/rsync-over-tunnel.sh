#!/usr/bin/env bash
#
# rsync-over-tunnel.sh - Migrate an LXC lxcpath to another host over an SSH tunnel
#
# Stands up a throwaway root rsync daemon on the TARGET host, bound to loopback
# and reachable only through an SSH local-forward tunnel from the SOURCE host.
# Writes a root-owned (idmapped) container rootfs on a host where root SSH login
# is disabled, leaving zero persistent privilege or config behind:
#
#   * No sudoers drop-in on either host.  Privilege escalation stays interactive.
#   * No persistent config: the daemon config lives on tmpfs (/run) and is
#     removed on exit; nothing survives a reboot even if you forget.
#   * Numeric ownership, hardlinks, ACLs, xattrs and sparseness are preserved,
#     which is what an unprivileged (idmapped) container rootfs actually needs.
#
# Usage: ./rsync-over-tunnel.sh <step> [options]   (no args prints the runbook)
#
# Exit codes (sysexits.h): 0 OK | 64 usage | 66 missing input | 69 unavailable |
#                          77 no permission
set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=utils-misc.sh
source "${SCRIPT_DIR}/utils-misc.sh"

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# ---------------------------------------------------------------- defaults --
PORT=8730                       # loopback port on BOTH hosts (tunnel is 1:1)
MODULE=lxc                      # rsyncd module name
CONF=/run/rsyncd-migrate.conf   # tmpfs: dies at reboot even if cleanup is missed
LOG_FILE=/dev/stdout            # daemon log target (--no-detach => your terminal)
CIPHER=''                       # ssh cipher; empty => let ssh negotiate (override: --cipher NAME)
LXCPATH=''                      # REQUIRED (no default) for target-tunnel and source-transfer
REMOTE=''                       # [user@]target, source-tunnel only
SSH_KEY=''
DRY_RUN=0
DELETE=0
declare -a EXTRA=()             # everything after `--` is handed to rsync/ssh

# Daemon config paths to reap on exit; set by cmd_target_tunnel, honored by cleanup().
DAEMON_CONF=''
DAEMON_LOCK=''

# ----------------------------------------------------------------- cleanup --
# Superset EXIT handler. Overrides the library cleanup() BY NAME so a single EXIT
# trap reaps both the library's tracked temps (TEMP_FILES, populated by
# check_for_updates) AND this script's throwaway daemon config. A second
# `trap ... EXIT` would clobber the library's trap and leak its self-update temps.
# if/fi + `|| true` keep the trap's own status from masking a real `exit N`.
cleanup() {
    local f
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$f" 2>/dev/null || true
    done
    if [[ -n "$DAEMON_CONF" ]]; then
        print_info "Removing $DAEMON_CONF and $DAEMON_LOCK"
        sudo rm -f -- "$DAEMON_CONF" "$DAEMON_LOCK" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ----------------------------------------------------------------- helpers --
# die <exit_code> <message>  — sysexits.h code first, message second.
die()  { print_error "✖ $2"; exit "$1"; }
need() { command -v "$1" >/dev/null 2>&1 || die 69 "required command not found: $1"; }

# --path is required going forward: no auto-detection, no assumptions.
resolve_lxcpath() {
    [[ -n "$LXCPATH" ]] || die 64 "--path is required (no default). Pass the lxcpath explicitly, e.g. --path ~/.local/share/lxc
       (tip: 'lxc-config lxc.lxcpath' prints liblxc's configured path)"
    LXCPATH="${LXCPATH%/}"
    [[ -d "$LXCPATH" ]] || die 66 "lxcpath not found: $LXCPATH  (check --path)"
}

# Speak just enough of the rsync protocol to prove the tunnel and module exist.
# Retries: a server child from a previous pass can still hold a connection slot
# for a second or two after the client has already exited.
probe_daemon() {
    local i
    for i in 1 2 3; do
        if rsync --contimeout=5 --list-only "rsync://127.0.0.1:${PORT}/${MODULE}/" >/dev/null 2>&1; then
            return 0
        fi
        ((i < 3)) && sleep 2
    done
    die 69 "no rsync daemon answering on 127.0.0.1:${PORT} module '${MODULE}'.
       Check that '$SCRIPT_NAME source-tunnel <target>' is running in another shell,
       that '$SCRIPT_NAME target-tunnel' is running on the target, and that --port/--module match.
       Raw error: $(rsync --contimeout=5 --list-only "rsync://127.0.0.1:${PORT}/${MODULE}/" 2>&1 | tail -2)"
}

# -------------------------------------------------------------------- help --
show_usage() {
    cat <<EOF
${CYAN}$SCRIPT_NAME${NC} — migrate an LXC lxcpath to another host over an SSH tunnel,
leaving zero persistent privilege or config changes behind.

Run the three steps ${CYAN}in this order${NC}, each in its own shell. Steps 1 and 2 stay
running for the whole transfer — use tmux, or a dropped SSH kills the copy.

${CYAN}STEP 1 — on the TARGET host (destination): start the throwaway root rsync daemon${NC}
  $SCRIPT_NAME target-tunnel --path DIR [--port N] [--module NAME] [--conf FILE] [--log FILE]
      --path    DIR   destination lxcpath        ${CYAN}(required)${NC}
      --port    N     loopback port to listen on (default: $PORT)
      --module  NAME  rsyncd module name         (default: $MODULE)
      --conf    FILE  generated daemon config    (default: $CONF)
      --log     FILE  daemon log target          (default: $LOG_FILE)
  Prompts for sudo, runs in the foreground, deletes its config on Ctrl-C.
  ${GRAY}The destination lxcpath must exist before the daemon starts (chroot), and
  must be created AS THE CONTAINER OWNER, not with sudo:
      mkdir -p ~/.local/share/lxc && chmod 0755 ~/.local/share/lxc${NC}

${CYAN}STEP 2 — on the SOURCE host, terminal 1: open the tunnel${NC}
  $SCRIPT_NAME source-tunnel <[user@]target> [--port N] [--identity KEY] [--cipher NAME] [-- SSH_ARGS...]
      <[user@]target> ssh target, e.g. jesse@target-host
      --port    N     forwarded on both ends     (default: $PORT)
      --identity KEY  ssh private key            (default: ssh's own selection)
      --cipher  NAME  ssh cipher                 (default: ssh's negotiated choice)
  ExitOnForwardFailure + keepalives are set, so a silent half-open tunnel
  cannot masquerade as a working one.

${CYAN}STEP 3 — on the SOURCE host, terminal 2: run the transfer${NC}
  $SCRIPT_NAME source-transfer --path DIR [--port N] [--module NAME] [-n] [--delete] [-- RSYNC_ARGS...]
      --path    DIR   source lxcpath             ${CYAN}(required)${NC}
      --port    N     tunnel entrance            (default: $PORT)
      --module  NAME  rsyncd module name         (default: $MODULE)
      -n, --dry-run   change nothing; pair with '-- --itemize-changes' to verify
      --delete        mirror deletions — OFF by default, think before using it
  Runs: sudo rsync -aHAXS --numeric-ids -W --partial-dir --info=progress2

${CYAN}Examples${NC}
  ${GRAY}# on the target${NC}
  $SCRIPT_NAME target-tunnel --path ~/.local/share/lxc
  ${GRAY}# on the source, terminal 1${NC}
  $SCRIPT_NAME source-tunnel jesse@target-host
  ${GRAY}# on the source, terminal 2 — first (long) pass${NC}
  $SCRIPT_NAME source-transfer --path ~/.local/share/lxc
  ${GRAY}# on the source, terminal 2 — resume/delta pass: drop -W so only the tail moves${NC}
  $SCRIPT_NAME source-transfer --path ~/.local/share/lxc -- --no-whole-file
  ${GRAY}# on the source, terminal 2 — verify with no writes${NC}
  $SCRIPT_NAME source-transfer --path ~/.local/share/lxc -n -- --itemize-changes

${CYAN}Afterwards${NC}
  Ctrl-C step 3 if still running, then step 2, then step 1. Confirm the target has
  no leftovers:  ls $CONF ; pgrep -af 'rsync [-][-]daemon'
  (bracketed so the pattern cannot match the pgrep command line itself)
EOF
}

# -------------------------------------------------------- step 1: target ----
cmd_target_tunnel() {
    need rsync
    resolve_lxcpath

    print_info "destination lxcpath : $LXCPATH"
    print_info "listening on        : 127.0.0.1:$PORT  (module '$MODULE')"

    # `rsync SRC/ DST/` syncs the CONTENTS of DST, never DST itself. If this
    # directory was created with sudo it stays root-owned and unprivileged
    # lxc-ls will not be able to traverse it after the migration.
    local owner
    owner=$(stat -c '%U' "$LXCPATH")
    if [[ "$owner" == root && "${SUDO_USER:-$(id -un)}" != root ]]; then
        print_warning "⚠ $LXCPATH is owned by root, but containers here are unprivileged."
        print_warning "  Fix before starting containers:  sudo chown ${SUDO_USER:-$(id -un)}: '$LXCPATH'"
    fi

    sudo -v || die 77 "sudo authentication failed"

    # Single source of truth for daemon settings: everything lives in the file,
    # nothing is duplicated on the rsync command line.
    local conf
    printf -v conf '%s\n' \
        "# generated by $SCRIPT_NAME on $(date -Is) — safe to delete" \
        "uid = root" \
        "gid = root" \
        "use chroot = yes" \
        "munge symlinks = no" \
        "numeric ids = yes" \
        "max connections = 1" \
        "lock file = ${CONF%.conf}.lock" \
        "reverse lookup = no" \
        "address = 127.0.0.1" \
        "port = $PORT" \
        "hosts allow = 127.0.0.1" \
        "hosts deny = *" \
        "log file = $LOG_FILE" \
        "" \
        "[$MODULE]" \
        "    path = $LXCPATH" \
        "    comment = temporary LXC migration target" \
        "    read only = false" \
        "    list = false"

    # Arm cleanup BEFORE writing, so an interrupt between tee and daemon start
    # still reaps the config on EXIT (see the cleanup() override above).
    DAEMON_CONF="$CONF"
    DAEMON_LOCK="${CONF%.conf}.lock"

    printf '%s' "$conf" | sudo tee "$CONF" >/dev/null
    sudo chmod 0600 "$CONF"
    print_info "wrote $CONF"

    print_info "daemon in foreground — Ctrl-C when the transfer is done"
    sudo rsync --daemon --no-detach --config="$CONF"
}

# --------------------------------------------------- step 2: source term 1 --
cmd_source_tunnel() {
    need ssh
    [[ -n "$REMOTE" ]] || die 64 "source-tunnel needs an ssh target, e.g. '$SCRIPT_NAME source-tunnel jesse@target-host'"
    # Option-injection guard (defense-in-depth). The arg parser's `-*)` arm already
    # rejects any dash-leading token, so REMOTE cannot normally start with `-`; this
    # is a belt-and-suspenders check because ssh has no `--` end-of-options marker and
    # a target like `-oProxyCommand=...` would otherwise be parsed as an ssh option and
    # run an arbitrary command (cf. CVE-2023-51385 / CVE-2025-61984).
    [[ "$REMOTE" == -* ]] && die 64 "refusing ssh target that begins with '-' (option-injection guard): $REMOTE"

    local -a args=(
        -N -T -x
        -o ExitOnForwardFailure=yes
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=6
        -o Compression=no
        -L "127.0.0.1:${PORT}:127.0.0.1:${PORT}"
    )
    [[ -z "$CIPHER"  ]] || args+=(-c "$CIPHER")
    [[ -z "$SSH_KEY" ]] || args+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
    args+=("${EXTRA[@]+"${EXTRA[@]}"}" "$REMOTE")

    print_info "tunnel 127.0.0.1:${PORT} -> ${REMOTE}:127.0.0.1:${PORT}  (Ctrl-C to close)"
    exec ssh "${args[@]}"
}

# --------------------------------------------------- step 3: source term 2 --
cmd_source_transfer() {
    need rsync
    resolve_lxcpath
    probe_daemon

    local -a args=(
        -aHAXS                          # archive + hardlinks + ACLs + xattrs + sparse
        --numeric-ids                   # 100000-range ownership must transfer verbatim
        -W                              # LAN: delta scan costs more than it saves
        --partial-dir=.rsync-migrate    # auto-excluded; resumable without half files
        --info=progress2
    )
    ((DRY_RUN)) && args+=(--dry-run)
    ((DELETE))  && args+=(--delete)
    args+=("${EXTRA[@]+"${EXTRA[@]}"}")

    print_info "source lxcpath : $LXCPATH/"
    print_info "destination    : rsync://127.0.0.1:${PORT}/${MODULE}/"
    ((DRY_RUN)) && print_warning "⚠ DRY RUN — nothing will be written"
    ((DELETE))  && print_warning "⚠ --delete is ACTIVE: files absent on the source will be removed on the target"

    exec sudo rsync "${args[@]}" "${LXCPATH}/" "rsync://127.0.0.1:${PORT}/${MODULE}/"
}

# -------------------------------------------------------------------- main --
main() {
    # Help / no-args fast-path BEFORE any network/self-update work.
    if [[ $# -eq 0 ]]; then show_usage; exit 0; fi
    case "$1" in -h|--help|help) show_usage; exit 0 ;; esac

    sweep_stale_temps '~*.tmp.??????'
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    local mode="$1"; shift

    while (($#)); do
        case "$1" in
            -p|--port)     PORT=${2:?missing value for --port};        shift 2 ;;
            -m|--module)   MODULE=${2:?missing value for --module};    shift 2 ;;
            -P|--path)     LXCPATH=${2:?missing value for --path};     shift 2 ;;
            -C|--conf)     CONF=${2:?missing value for --conf};        shift 2 ;;
            -l|--log)      LOG_FILE=${2:?missing value for --log};     shift 2 ;;
            -i|--identity) SSH_KEY=${2:?missing value for --identity}; shift 2 ;;
            --cipher)      CIPHER=${2:?missing value for --cipher};    shift 2 ;;
            -n|--dry-run)  DRY_RUN=1;                                  shift   ;;
            --delete)      DELETE=1;                                   shift   ;;
            -h|--help)     show_usage; exit 0 ;;
            --)            shift; EXTRA+=("$@"); break ;;
            -*)            die 64 "unknown option: $1" ;;
            *)             [[ -z "$REMOTE" ]] || die 64 "unexpected argument: $1"
                           REMOTE="$1";                               shift   ;;
        esac
    done

    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
        die 64 "invalid port: $PORT"
    fi

    case "$mode" in
        target-tunnel)   cmd_target_tunnel   ;;
        source-tunnel)   cmd_source_tunnel   ;;
        source-transfer) cmd_source_transfer ;;
        *) die 64 "unknown step '$mode' — run '$SCRIPT_NAME' with no arguments for the runbook" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
