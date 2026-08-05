#!/usr/bin/env bash
#
# rsync-over-tunnel.sh - Transfer a directory tree to another host over an SSH tunnel
#
# Stands up a throwaway root rsync daemon on the TARGET host, bound to loopback
# and reachable only through an SSH local-forward tunnel from the SOURCE host.
# Writes root-owned files on a host where root SSH login is disabled, leaving
# zero persistent privilege or config behind:
#
#   * No sudoers drop-in on either host.  Privilege escalation stays interactive.
#   * No persistent config: the daemon config lives in the boot-scoped runtime
#     directory (/run on Linux, /var/run on macOS) and is removed on exit;
#     nothing survives a reboot even if you forget.
#   * Numeric ownership, hardlinks, sparseness — and ACLs/xattrs where both
#     rsync builds support them — are preserved. An unprivileged (idmapped) LXC
#     container rootfs is the motivating case, since it needs every one of
#     those, but any directory tree works.
#
# Single-user target hosts only. The module is unauthenticated and rsyncd's
# `hosts allow` cannot tell local users apart, so while the daemon is up ANY
# local user on the target can reach the module and write the destination as
# root. `max connections = 1` means a running transfer holds the only slot and
# the daemon is foreground/supervised, but do not run step 1 on a shared host.
# chroot confinement of the module path is claimed only where the daemon binary
# can actually take it: Linux, or macOS running Apple's signed /usr/bin/rsync.
#
# Usage: ./rsync-over-tunnel.sh <step> [options]   (no args prints the runbook)
#
# Exit codes (sysexits.h): 0 OK | 64 usage | 66 cannot open input |
#                          69 unavailable | 77 no permission
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
MODULE=xfer                     # rsyncd module name
CONF=/run/rsyncd-migrate.conf   # tmpfs: dies at reboot even if cleanup is missed
LOG_FILE=/dev/stdout            # daemon log target (--no-detach => your terminal)
CIPHER=''                       # ssh cipher; empty => let ssh negotiate (override: --cipher NAME)
TRANSFER_PATH=''                # REQUIRED (no default) for target-tunnel and source-transfer
REMOTE=''                       # [user@]target, source-tunnel only
SSH_KEY=''
DRY_RUN=0
DELETE=0
EXTRA=()                        # everything after `--` is handed to rsync/ssh

# Daemon config paths to reap on exit; set by cmd_target_tunnel, honored by cleanup().
DAEMON_CONF=''
DAEMON_LOCK=''

# Single source of truth for the daemon URL; built by main() once PORT and MODULE
# have been validated, then shared by the probe and the transfer.
DAEMON_URL=''

# What this host's rsync is and what it can do; populated by require_rsync from a
# single `--version` read, then consumed when the transfer flags are composed.
RSYNC_BIN=''                    # absolute path; set by require_rsync
RSYNC_IMPL=''                   # "openrsync" | "rsync" — advisory message only
RSYNC_HAS_ACLS=false
RSYNC_HAS_XATTRS=false
LOCAL_PROTOCOL=''               # this build's protocol; set by parse_rsync_protocol
REMOTE_PROTOCOL=''              # far-end protocol; set by probe_remote_protocol

# ----------------------------------------------------------------- cleanup --
# Superset EXIT handler. Overrides the library cleanup() BY NAME so a single EXIT
# trap reaps both the library's tracked temps (TEMP_FILES, populated by
# check_for_updates) AND this script's throwaway daemon config. A second
# `trap ... EXIT` would clobber the library's trap and leak its self-update temps.
# Re-audit this override whenever utils-misc.sh's cleanup() changes: it is one of
# the canonical cross-copy helpers, so its body does move over time.
# Every branch ends in a print_* (status 0), so the trap never masks a real `exit N`.
cleanup() {
    local f
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$f" 2>/dev/null || true
    done
    if [[ -n "$DAEMON_CONF" ]]; then
        # Report what actually happened. A transfer easily outlasts the sudo
        # timestamp, and announcing a removal that failed would contradict this
        # script's own "leaves nothing behind" guarantee while a root-owned
        # config quietly survives in /run.
        if sudo rm -f -- "$DAEMON_CONF" "$DAEMON_LOCK"; then
            print_info "Removed $DAEMON_CONF and $DAEMON_LOCK"
        else
            print_warning "⚠ Could NOT remove the daemon config — delete it by hand:"
            print_warning "      sudo rm -f -- '$DAEMON_CONF' '$DAEMON_LOCK'"
        fi
    fi
}
trap cleanup EXIT

# ----------------------------------------------------------------- helpers --
# die <exit_code> <message>  — sysexits.h code first, message second.
die()  { print_error "✖ $2"; exit "$1"; }
need() { command -v "$1" >/dev/null 2>&1 || die 69 "required command not found: $1"; }

# --------------------------------------------------- rsync capability probe --
# Classify an `rsync --version` blob. Sets RSYNC_IMPL.
# openrsync self-identifies on line 1 ("openrsync: protocol version 29" on
# macOS 15.4, "openrsync 2.6.9, protocol version 29" on 26) while ALSO claiming
# "rsync version 2.6.9 compatible" on line 2 — so match the announcement and
# never the compatibility claim, which is why this substring test comes first.
parse_rsync_impl() {
    local version_text="$1"
    if [[ "$version_text" == *openrsync* ]]; then
        RSYNC_IMPL=openrsync
    else
        RSYNC_IMPL=rsync
    fi
}

# True when capability $2 is advertised as supported in the --version blob $1.
# rsync prints a "Capabilities:" block where an UNSUPPORTED feature carries a
# "no " prefix (usage.c: `#ifndef SUPPORT_ACLS "no " #endif "ACLs",`), so the
# negative form must be tested FIRST — the bare word is present either way.
# openrsync prints no Capabilities block at all, so both tests fall through to
# "absent", which is correct.
_rsync_cap_present() {
    local version_text="$1" cap="$2"
    [[ "$version_text" == *"no $cap"* ]] && return 1
    [[ "$version_text" == *"$cap"* ]]
}

# Sets RSYNC_HAS_ACLS and RSYNC_HAS_XATTRS from an `rsync --version` blob.
# Tracked separately, not as one flag: a build can support one and not the
# other, and collapsing them would drop ACL preservation that was available.
parse_rsync_caps() {
    local version_text="$1"
    if _rsync_cap_present "$version_text" ACLs; then
        RSYNC_HAS_ACLS=true
    else
        RSYNC_HAS_ACLS=false
    fi
    if _rsync_cap_present "$version_text" xattrs; then
        RSYNC_HAS_XATTRS=true
    else
        RSYNC_HAS_XATTRS=false
    fi
}

# Extract this build's protocol number from an `rsync --version` blob into
# LOCAL_PROTOCOL. Returns 1 when the blob has no protocol line.
#
# Why the protocol number and not the dotted release version: --info=FLAGS
# shipped in rsync 3.1.0, which is exactly protocol 31 (OLDNEWS: 2.6.9 -> 29,
# 3.0.0 -> 30, 3.1.0 -> 31), and protocol numbers rise monotonically with
# releases. So `LOCAL_PROTOCOL >= 31` is an exact test for --info support, not a
# heuristic — and it needs no two-component version comparison and no `sed`,
# which matters here because this is the change that adds BSD support and GNU
# and BSD sed differ. Every implementation prints this line: GNU rsync as
# "rsync  version 3.4.4  protocol version 32", openrsync as either
# "openrsync: protocol version 29" or "openrsync 2.6.9, protocol version 29".
# The regex takes the FIRST match, which on openrsync 15.4 is its own line 1
# and not the "rsync version 2.6.9 compatible" claim on line 2.
parse_rsync_protocol() {
    local version_text="$1"
    [[ "$version_text" =~ protocol[[:space:]]+version[[:space:]]+([0-9]+) ]] || return 1
    LOCAL_PROTOCOL="${BASH_REMATCH[1]}"
}

# Extract the protocol version from an rsync daemon greeting line into
# REMOTE_PROTOCOL. rsync's own client parses this with
# sscanf(buf, "@RSYNCD: %d.%d", …) (clientserver.c), so the shape is stable
# across implementations. Returns 1 when the line is not a greeting.
parse_rsyncd_greeting() {
    local line="$1"
    [[ "$line" =~ ^@RSYNCD:[[:space:]]+([0-9]+) ]] || return 1
    REMOTE_PROTOCOL="${BASH_REMATCH[1]}"
}

# --path is required going forward: no auto-detection, no assumptions.
resolve_transfer_path() {
    [[ -n "$TRANSFER_PATH" ]] || die 64 "--path is required (no default). Pass the directory explicitly, e.g. --path ~/data"
    # A leading '-' turns the path into an option bundle for every command it
    # reaches — `stat` in step 1, `sudo rsync` in step 3. rsync's man page
    # documents no `--` end-of-options marker, so guard the shape rather than
    # depend on one; same defense the ssh target gets in cmd_source_tunnel.
    [[ "$TRANSFER_PATH" == -* ]] && die 64 "refusing a path that begins with '-': $TRANSFER_PATH
       (pass './$TRANSFER_PATH' or an absolute path instead)"
    TRANSFER_PATH="${TRANSFER_PATH%/}"
    [[ -d "$TRANSFER_PATH" ]] || die 66 "directory not found: $TRANSFER_PATH  (check --path)"
}

# Speak just enough of the rsync protocol to prove the tunnel and module exist.
# Retries: a server child from a previous pass can still hold a connection slot
# for a second or two after the client has already exited. The last attempt's
# output is kept for the failure message, so the diagnostic costs no extra probe.
probe_daemon() {
    local i probe_output
    for i in 1 2 3; do
        if probe_output=$(rsync --contimeout=5 --list-only "$DAEMON_URL" 2>&1); then
            return 0
        fi
        ((i < 3)) && sleep 2
    done
    die 69 "no rsync daemon answering on 127.0.0.1:${PORT} module '${MODULE}'.
       Check that '$SCRIPT_NAME source-tunnel <target>' is running in another shell,
       that '$SCRIPT_NAME target-tunnel' is running on the target, and that --port/--module match.
       Raw error: $(printf '%s\n' "$probe_output" | tail -2)"
}

# -------------------------------------------------------------------- help --
show_usage() {
    cat <<EOF
${CYAN}$SCRIPT_NAME${NC} — transfer a directory tree to another host over an SSH tunnel,
leaving zero persistent privilege or config changes behind.

Run the three steps ${CYAN}in this order${NC}, each in its own shell. Steps 1 and 2 stay
running for the whole transfer — use tmux, or a dropped SSH kills the copy.

${CYAN}STEP 1 — on the TARGET host (destination): start the throwaway root rsync daemon${NC}
  $SCRIPT_NAME target-tunnel --path DIR [--port N] [--module NAME] [--conf FILE] [--log FILE]
  -P, --path    DIR   destination directory      ${CYAN}(required)${NC}
  -p, --port    N     loopback port to listen on (default: $PORT)
  -m, --module  NAME  rsyncd module name         (default: $MODULE)
  -C, --conf    FILE  generated daemon config    (default: $CONF)
  -l, --log     FILE  daemon log target          (default: $LOG_FILE)
  Prompts for sudo, runs in the foreground, deletes its config on Ctrl-C.
  ${GRAY}The destination directory must exist before the daemon starts (chroot), and
  must be created as the user who will own the files, not with sudo:
      mkdir -p ~/data && chmod 0755 ~/data${NC}

${CYAN}STEP 2 — on the SOURCE host, terminal 1: open the tunnel${NC}
  $SCRIPT_NAME source-tunnel <[user@]target> [--port N] [--identity KEY] [--cipher NAME] [-- SSH_ARGS...]
      <[user@]target> ssh target, e.g. jesse@target-host
  -p, --port    N     forwarded on both ends     (default: $PORT)
  -i, --identity KEY  ssh private key            (default: ssh's own selection)
      --cipher  NAME  ssh cipher                 (default: ssh's negotiated choice)
  ExitOnForwardFailure + keepalives are set, so a silent half-open tunnel
  cannot masquerade as a working one.

${CYAN}STEP 3 — on the SOURCE host, terminal 2: run the transfer${NC}
  $SCRIPT_NAME source-transfer --path DIR [--port N] [--module NAME] [-n] [--delete] [-- RSYNC_ARGS...]
  -P, --path    DIR   source directory           ${CYAN}(required)${NC}
  -p, --port    N     tunnel entrance            (default: $PORT)
  -m, --module  NAME  rsyncd module name         (default: $MODULE)
  -n, --dry-run       change nothing; pair with '-- --itemize-changes' to verify
      --delete        mirror deletions — OFF by default, think before using it
  Runs: sudo rsync -aHS --numeric-ids -W --partial-dir=.rsync-migrate
        plus -A -X (ACLs/xattrs) and --info=progress2 when both hosts support them;
        the exact command is printed before it runs.

${CYAN}Examples${NC}
  ${GRAY}# on the target${NC}
  $SCRIPT_NAME target-tunnel --path ~/data
  ${GRAY}# on the source, terminal 1${NC}
  $SCRIPT_NAME source-tunnel jesse@target-host
  ${GRAY}# on the source, terminal 2 — first (long) pass${NC}
  $SCRIPT_NAME source-transfer --path ~/data
  ${GRAY}# on the source, terminal 2 — resume/delta pass: drop -W so only the tail moves${NC}
  $SCRIPT_NAME source-transfer --path ~/data -- --no-whole-file
  ${GRAY}# on the source, terminal 2 — verify with no writes${NC}
  $SCRIPT_NAME source-transfer --path ~/data -n -- --itemize-changes

${CYAN}Afterwards${NC}
  Ctrl-C step 3 if still running, then step 2, then step 1. Confirm the target has
  no leftovers:  ls $CONF ${CONF%.conf}.lock ; pgrep -af 'rsync [-][-]daemon'
  (bracketed so the pattern cannot match the pgrep command line itself)
EOF
}

# -------------------------------------------------------- step 1: target ----
cmd_target_tunnel() {
    need rsync
    resolve_transfer_path

    print_info "destination directory : $TRANSFER_PATH"
    print_info "listening on          : 127.0.0.1:$PORT  (module '$MODULE')"

    # `rsync SRC/ DST/` syncs the CONTENTS of DST, never DST itself. If this
    # directory was created with sudo it stays root-owned, and an unprivileged
    # user will not be able to traverse it after the transfer.
    local owner
    owner=$(stat -c '%U' "$TRANSFER_PATH") || die 66 "cannot stat lxcpath: $TRANSFER_PATH"
    if [[ "$owner" == root && "${SUDO_USER:-$(id -un)}" != root ]]; then
        print_warning "⚠ $TRANSFER_PATH is owned by root, but you are not running as root."
        print_warning "  Fix before using the copy:  sudo chown ${SUDO_USER:-$(id -un)}: '$TRANSFER_PATH'"
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
        "    path = $TRANSFER_PATH" \
        "    comment = temporary transfer target" \
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
    resolve_transfer_path
    probe_daemon

    local -a args=(
        -aHAXS                          # archive + hardlinks + ACLs + xattrs + sparse
        --numeric-ids                   # ownership must transfer verbatim (an idmapped
                                        # container rootfs is the motivating case)
        -W                              # LAN: delta scan costs more than it saves
        --partial-dir=.rsync-migrate    # auto-excluded; resumable without half files
        --info=progress2
    )
    ((DRY_RUN)) && args+=(--dry-run)
    ((DELETE))  && args+=(--delete)
    args+=("${EXTRA[@]+"${EXTRA[@]}"}")

    print_info "source directory : $TRANSFER_PATH/"
    print_info "destination      : $DAEMON_URL"
    ((DRY_RUN)) && print_warning "⚠ DRY RUN — nothing will be written"
    ((DELETE))  && print_warning "⚠ --delete is ACTIVE: files absent on the source will be removed on the target"

    exec sudo rsync "${args[@]}" "${TRANSFER_PATH}/" "$DAEMON_URL"
}

# -------------------------------------------------------------------- main --
main() {
    # Help / no-args fast-path BEFORE any network/self-update work.
    if [[ $# -eq 0 ]]; then show_usage; exit 0; fi
    case "$1" in -h|--help|help) show_usage; exit 0 ;; esac

    sweep_stale_temps '~*.tmp.??????'
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    local mode="$1"; shift

    # Each value-taking arm checks its own arity. Bash's `${2:?...}` exits 1 with
    # a raw "line NN: 2: ..." message, which contradicts both the sysexits header
    # above and this repo's print_error convention.
    while (($#)); do
        case "$1" in
            -p|--port)     [[ $# -ge 2 ]] || die 64 "missing value for $1"; PORT="$2";     shift 2 ;;
            -m|--module)   [[ $# -ge 2 ]] || die 64 "missing value for $1"; MODULE="$2";   shift 2 ;;
            -P|--path)     [[ $# -ge 2 ]] || die 64 "missing value for $1"; TRANSFER_PATH="$2";  shift 2 ;;
            -C|--conf)     [[ $# -ge 2 ]] || die 64 "missing value for $1"; CONF="$2";     shift 2 ;;
            -l|--log)      [[ $# -ge 2 ]] || die 64 "missing value for $1"; LOG_FILE="$2"; shift 2 ;;
            -i|--identity) [[ $# -ge 2 ]] || die 64 "missing value for $1"; SSH_KEY="$2";  shift 2 ;;
            --cipher)      [[ $# -ge 2 ]] || die 64 "missing value for $1"; CIPHER="$2";   shift 2 ;;
            -n|--dry-run)  DRY_RUN=1;                                                      shift   ;;
            --delete)      DELETE=1;                                                       shift   ;;
            -h|--help)     show_usage; exit 0 ;;
            --)            shift; EXTRA+=("$@"); break ;;
            -*)            die 64 "unknown option: $1" ;;
            *)             [[ -z "$REMOTE" ]] || die 64 "unexpected argument: $1"
                           REMOTE="$1";                                                    shift   ;;
        esac
    done

    # ^[1-9] (not ^[0-9]) rejects a leading zero outright: bash arithmetic reads
    # 08/077 as octal, so `((PORT < 1))` errored out — and, sitting in an `if`
    # condition where set -e does not fire, let the bad port through to the daemon
    # config, the ssh forward and the rsync URL. Capping at 5 digits also keeps
    # the comparison clear of integer overflow.
    if [[ ! "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || ((PORT > 65535)); then
        die 64 "invalid port: $PORT  (expected 1-65535, no leading zeros)"
    fi

    # MODULE lands in an rsyncd.conf section header AND in the rsync:// URL.
    [[ "$MODULE" =~ ^[A-Za-z0-9._-]+$ ]] || die 64 "invalid module name: $MODULE  (allowed: A-Z a-z 0-9 . _ -)"

    # rsyncd.conf is line-oriented and has no escape syntax, so a newline in any
    # value interpolated into it injects daemon directives — a second [module], a
    # `pre-xfer exec = ...` — defeating the chroot/loopback confinement.
    [[ "${TRANSFER_PATH}${LOG_FILE}${CONF}" == *[[:cntrl:]]* ]] &&
        die 64 "control characters are not allowed in --path/--log/--conf values"

    # Only source-tunnel takes a positional. Swallowing one in the other steps
    # hides a wrong-terminal mistake in the middle of a migration.
    if [[ -n "$REMOTE" && "$mode" != "source-tunnel" ]]; then
        die 64 "unexpected argument '$REMOTE' — only 'source-tunnel' takes an ssh target"
    fi

    DAEMON_URL="rsync://127.0.0.1:${PORT}/${MODULE}/"

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
