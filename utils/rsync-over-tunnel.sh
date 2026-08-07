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
# Anywhere else the operator is shown what that costs and must consent to it.
#
# Usage: ./rsync-over-tunnel.sh <step> [options]   (no args prints the runbook)
#
# Requires bash 5+ (enforced by utils-misc.sh).
#
# Exit codes (sysexits.h): 0 OK | 64 usage | 66 cannot open input |
#                          69 unavailable | 73 cannot create output |
#                          77 no permission
set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# utils-misc.sh enforces the bash 5+ baseline for every utils/ script.
# shellcheck source=utils-misc.sh
source "${SCRIPT_DIR}/utils-misc.sh"

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# detect_os arrived in utils-misc.sh alongside this script's macOS support, and
# check_for_updates updates the library and the caller as two separate prompts —
# so a library predating it is a reachable state, not a hypothetical. A bare call
# would die right here at file scope under `set -e` with "detect_os: command not
# found", before main() runs. Self-repairing is not possible: the repair
# machinery lives in the same file that is stale. Raw printf, not print_error,
# because a library that old may not have that either.
if ! declare -F detect_os >/dev/null; then
    printf 'stale utils-misc.sh in %s: detect_os() is missing.\n' "$SCRIPT_DIR" >&2
    printf 'Update it first:  %s/_download-utils-scripts.sh\n' "$SCRIPT_DIR" >&2
    exit 69
fi

# Must run before the defaults block below: CONF branches on DETECTED_OS, and
# the defaults execute at file scope.
detect_os

# ---------------------------------------------------------------- defaults --
PORT=8730                       # loopback port on BOTH hosts (tunnel is 1:1)
MODULE=xfer                     # rsyncd module name
CONF=/run/rsyncd-migrate.conf   # boot-scoped: dies at reboot even if cleanup is missed
# macOS has no top-level /run (hier(7)); /var/run is the boot-scoped equivalent.
# NOT /var/tmp — hier(7) documents that one as surviving reboots, which would
# defeat the "dies at reboot even if cleanup is missed" property above.
[[ "$DETECTED_OS" == macos ]] && CONF=/var/run/rsyncd-migrate.conf
# rsyncd's `max connections` lock. Derived from CONF here and re-derived once in
# main() after --conf is parsed — and NOWHERE else. Three independent copies of
# this expression previously fed three different consumers (the generated
# config, cleanup(), and the help text); a divergence between the first two
# orphans a root-owned lock file that cleanup() then never removes.
LOCK_FILE="${CONF%.conf}.lock"
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

# The transfer argv and the capability decisions behind it; all three are set by
# compose_transfer_args and consumed by cmd_source_transfer.
TRANSFER_ARGS=()                # rsync argv, minus the source path and the URL
DROPPED_CAPS=()                 # human-readable list of what could not be preserved
DROPPED_BY_REMOTE=false         # true when the far end forced the drop, not this build

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
            print_success "✓ Removed $DAEMON_CONF and $DAEMON_LOCK"
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
    # Clear before matching, the way parse_rsync_impl and parse_rsync_caps
    # unconditionally assign theirs. Without this a failed parse leaves the
    # PREVIOUS call's number standing, so an unreadable --version silently
    # inherits an unrelated build's protocol — and require_rsync's own comment
    # ("Leave LOCAL_PROTOCOL empty") would be false.
    LOCAL_PROTOCOL=''
    [[ "$version_text" =~ protocol[[:space:]]+version[[:space:]]+([0-9]+) ]] || return 1
    LOCAL_PROTOCOL="${BASH_REMATCH[1]}"
}

# Extract the protocol version from an rsync daemon greeting line into
# REMOTE_PROTOCOL. rsync's own client parses this with
# sscanf(buf, "@RSYNCD: %d.%d", …) (clientserver.c), so the shape is stable
# across implementations. Returns 1 when the line is not a greeting.
parse_rsyncd_greeting() {
    local line="$1"
    # Cleared before matching for the same reason as parse_rsync_protocol above:
    # a failed probe must report "unknown", not the last host's protocol.
    REMOTE_PROTOCOL=''
    [[ "$line" =~ ^@RSYNCD:[[:space:]]+([0-9]+) ]] || return 1
    REMOTE_PROTOCOL="${BASH_REMATCH[1]}"
}

# Resolve rsync once and record what this build can do.
# Resolving to an absolute path is load-bearing: `sudo` looks a bare command
# name up in its own secure_path, not the caller's PATH, so `sudo rsync` can
# execute /usr/bin/rsync (openrsync) even when Homebrew's rsync is first in
# PATH — the probe would pass and the daemon would still be the wrong binary.
# secure_path constrains lookup only, so an absolute path is immune.
require_rsync() {
    RSYNC_BIN=$(command -v rsync) || die 69 "required command not found: rsync"

    # No `|| true` here. A non-zero --version means this is not an rsync we can
    # reason about, and version_text would then hold an ERROR STRING that the
    # parsers below happily turn into a fabricated capability profile — which
    # decides the flags a root-privileged rsync runs with. Fail loudly instead.
    local version_text
    version_text=$("$RSYNC_BIN" --version 2>&1) ||
        die 69 "'$RSYNC_BIN --version' failed — cannot determine rsync capabilities:
       $(printf '%s' "$version_text" | head -2 | _sanitize_ansi)"

    parse_rsync_impl "$version_text"
    parse_rsync_caps "$version_text"
    # A --version blob with no protocol line means an rsync we do not understand.
    # Leave LOCAL_PROTOCOL empty; cmd_source_transfer treats unknown as "assume
    # capable" and lets rsync itself raise the authoritative error.
    parse_rsync_protocol "$version_text" || true

    if [[ "$RSYNC_IMPL" == openrsync ]]; then
        print_warning "⚠ $RSYNC_BIN is openrsync (protocol ${LOCAL_PROTOCOL:-29}, no -A/-X, no --info=)."
        print_warning "  For full fidelity install rsync 3.x:  brew install rsync"
    fi
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

# Read the far end's protocol version into REMOTE_PROTOCOL.
# Local capability detection cannot see the far end: a GNU rsync 3.x source
# pushing to an openrsync target would add -A/-X and only then die at protocol
# negotiation. The daemon announces itself the instant a client connects, so
# read the greeting straight off the socket. `--debug=proto` would also report
# it, but openrsync has no --debug flag — that path would break in exactly the
# case this exists to catch.
#
# Costs one connection against `max connections = 1`, and closing without
# completing the handshake leaves the daemon briefly tearing that child down.
# Returns 1 when undeterminable (bash without net redirections, unexpected
# greeting) — callers treat unknown as "do not block".
probe_remote_protocol() {
    local greeting=''
    # The redirect must be wrapped in a group, NOT written as
    # `exec 3<>… 2>/dev/null`: bash applies redirections left to right, so the
    # /dev/tcp open fails and prints "Connection refused" BEFORE the 2>/dev/null
    # takes effect, leaking two lines of raw bash error into the operator's
    # terminal on every closed-port probe. A `{ …; } 2>/dev/null` group scopes
    # the suppression over the whole exec while still leaving fd 3 open in this
    # shell (a subshell would not). Verified: the un-grouped form prints
    # "connect: Connection refused"; the grouped form prints nothing.
    { exec 3<>"/dev/tcp/127.0.0.1/${PORT}"; } 2>/dev/null || return 1
    IFS= read -r -t 5 greeting <&3 || true
    exec 3<&-
    parse_rsyncd_greeting "$greeting"
}

# Speak just enough of the rsync protocol to prove the tunnel and module exist.
# Retries: a server child from a previous pass can still hold a connection slot
# for a second or two after the client has already exited. The last attempt's
# output is kept for the failure message, so the diagnostic costs no extra probe.
# That output comes from the far end, so it is untrusted: it goes through
# _sanitize_ansi before reaching the terminal (print_error uses printf, not
# `echo -e`, so backslash escapes in it stay literal).
probe_daemon() {
    local i probe_output
    for i in 1 2 3; do
        if probe_output=$("$RSYNC_BIN" --contimeout=5 --list-only "$DAEMON_URL" 2>&1); then
            return 0
        fi
        ((i < 3)) && sleep 2
    done
    die 69 "no rsync daemon answering on 127.0.0.1:${PORT} module '${MODULE}'.
       Check that '$SCRIPT_NAME source-tunnel <target>' is running in another shell,
       that '$SCRIPT_NAME target-tunnel' is running on the target, and that --port/--module match.
       Raw error: $(printf '%s\n' "$probe_output" | tail -2 | _sanitize_ansi)"
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
  ${GRAY}--conf must name a path that does NOT exist: the file is a throwaway and is
  DELETED on exit, along with the '.lock' beside it. Pointing it at a real
  rsyncd.conf is refused rather than obeyed.${NC}
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
        plus -A -X (ACLs/xattrs) when BOTH hosts support them — this host's rsync
        must be built with them and the target must speak protocol 30+ — and
        --info=progress2 when THIS host's rsync is 3.1+ (protocol 31; the target
        is not consulted for that one). The exact command is printed before it runs.

${CYAN}Both hosts must run the same version of this script${NC}
  The module name travels on the wire — it is the rsyncd.conf section header on
  the target and the last path element of the rsync:// URL on the source. It
  changed from 'lxc' to '$MODULE' when this script stopped being LXC-specific, so a
  half-upgraded pair fails with "no rsync daemon answering … module '$MODULE'".
  Escape hatch until both sides are updated: pass ${CYAN}--module lxc${NC} on BOTH hosts.

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
  no leftovers:  ls $CONF $LOCK_FILE ; pgrep -af 'rsync [-][-]daemon'
  (bracketed so the pattern cannot match the pgrep command line itself)
EOF
}

# Emit the throwaway rsyncd.conf on stdout.
# Extracted from cmd_target_tunnel so the generated config is directly
# assertable in tests — no root, no daemon, no second host. The timestamp is a
# parameter rather than an internal `date` call so output is deterministic.
# Reads globals: SCRIPT_NAME, PORT, MODULE, TRANSFER_PATH, LOCK_FILE, LOG_FILE.
#
# Single source of truth for daemon settings: everything lives in the file,
# nothing is duplicated on the rsync command line.
#
# EVERY key here must exist in openrsync's parameter table as well as GNU
# rsyncd's: openrsync treats an unknown key as an UNRECOVERABLE error, so one
# stray directive kills step 1 on every macOS host running Apple's
# /usr/bin/rsync. Check any new key against `rsync_daemon_params[]` in
# openrsync/daemon_cfg.c (apple-oss-distributions/rsync) BEFORE adding it.
#
# Verified 2026-08-06 against that table: all 16 keys emitted below — uid, gid,
# use chroot, munge symlinks, numeric ids, max connections, lock file, address,
# port, hosts allow, hosts deny, log file, path, comment, read only, list — are
# present. "reverse lookup" is NOT, which is why it is deliberately absent here;
# and with a loopback-only `address` and a numeric `hosts allow` there was no
# hostname to resolve, so it bought nothing on GNU rsync either.
build_daemon_config() {
    local use_chroot="$1" stamp="$2"

    # `munge symlinks` is emitted ONLY when chroot is off, and it is the one
    # directive here that is a deliberate security trade rather than a hardening.
    #
    # rsyncd's default is "disabled when 'use chroot' is on with an inside-chroot
    # path of '/' … otherwise it is enabled" (rsyncd.conf(5)). Under
    # `use chroot = yes` the daemon chroots to the module path, so the
    # inside-chroot path IS '/' and munging is already off — emitting it there
    # is a no-op that only adds a key for openrsync's parser to reject.
    #
    # Under `use chroot = no` the default flips ON, and munging rewrites every
    # received symlink to "/rsyncd-munged/<target>". For this tool that is not
    # protection, it is corruption: the motivating payload is a container rootfs
    # whose symlinks ARE the data. So munging is turned off explicitly — which
    # leaves the no-chroot daemon with no symlink confinement at all, and is
    # exactly why cmd_target_tunnel makes the operator consent to that path.
    local -a munge=()
    [[ "$use_chroot" == no ]] && munge=("munge symlinks = no")

    # uid/gid are NUMERIC, not names. There is no group named "root" on macOS —
    # gid 0 is "wheel" — so `gid = root` made every macOS target daemon reject
    # the connection with "@ERROR <module>: gid 'root' invalid". The failure is
    # deferred to connect time (the daemon resolves the module's user only once
    # a client attaches), so step 1 starts and listens perfectly and the error
    # surfaces on the SOURCE host in step 3, pointing at the wrong machine.
    #
    # 0 is the superuser id on both platforms and needs no name lookup at all.
    # Both daemons accept it: rsyncd.conf(5) documents uid as "the user name or
    # user ID" and gid as "group names/IDs", and openrsync's
    # daemon_chuser_resolve_name tries getpwnam/getgrnam FIRST and falls back to
    # strtoll, so a numeric string resolves on the fallback path.
    # Verified 2026-08-07: rsyncd.conf(5); openrsync/daemon_misc.c.
    printf '%s\n' \
        "# generated by $SCRIPT_NAME on ${stamp} — safe to delete" \
        "uid = 0" \
        "gid = 0" \
        "use chroot = ${use_chroot}" \
        "${munge[@]+"${munge[@]}"}" \
        "numeric ids = yes" \
        "max connections = 1" \
        "lock file = ${LOCK_FILE}" \
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
}

# -------------------------------------------------------- step 1: target ----
cmd_target_tunnel() {
    require_rsync
    resolve_transfer_path

    print_info "destination directory : $TRANSFER_PATH"
    print_info "listening on          : 127.0.0.1:$PORT  (module '$MODULE')"

    # `rsync SRC/ DST/` syncs the CONTENTS of DST, never DST itself. If this
    # directory was created with sudo it stays root-owned, and an unprivileged
    # user will not be able to traverse it after the transfer.
    # GNU coreutils takes -c/%U; BSD (macOS) takes -f and needs the S modifier to
    # render the uid as a name. Same branch as lxc/setup-lxc.sh. Selecting flags
    # into an array keeps the failure path written once.
    local owner
    local stat_owner=(-c '%U')
    [[ "$DETECTED_OS" == macos ]] && stat_owner=(-f '%Su')
    owner=$(stat "${stat_owner[@]}" "$TRANSFER_PATH") ||
        die 66 "cannot read ownership of: $TRANSFER_PATH"
    if [[ "$owner" == root && "${SUDO_USER:-$(id -un)}" != root ]]; then
        print_warning "⚠ $TRANSFER_PATH is owned by root, but you are not running as root."
        print_warning "  Fix before using the copy:  sudo chown ${SUDO_USER:-$(id -un)}: '$TRANSFER_PATH'"
    fi

    # cleanup() DELETES both of these on exit, so writing over an existing file
    # destroys it outright. --conf is operator-supplied and previously validated
    # only for control characters, which made `--conf /etc/rsyncd.conf` clobber
    # and then remove the host's real daemon config — plus /etc/rsyncd.lock, a
    # path the operator never named and which is only derived from theirs.
    # Refuse rather than back up: this file is a throwaway by design, and a
    # backup would still leave the operator's daemon pointing at a deleted file.
    # Checked before `sudo -v` so the refusal costs no password prompt.
    [[ -e "$CONF" ]] && die 73 "refusing to overwrite an existing file: $CONF
       This config is a throwaway and is DELETED on exit. Point --conf at a path that does not exist."
    [[ -e "$LOCK_FILE" ]] && die 73 "refusing to reuse an existing lock file: $LOCK_FILE
       Derived from --conf, and DELETED on exit like the config. Point --conf somewhere else."

    sudo -v || die 77 "sudo authentication failed"

    # macOS restricts chroot(2) to binaries holding com.apple.private.vfs.chroot,
    # which only Apple's signed rsyncd carries — a Homebrew rsync gets EPERM, and
    # an explicit "yes" makes EPERM fatal rather than a fallback (openrsync
    # daemon.c; GNU rsyncd.conf(5)). Gate on the BINARY PATH, not on RSYNC_IMPL:
    # the entitlement attaches to Apple's signed binary, so a self-built
    # openrsync would identify as openrsync and still be denied.
    local use_chroot='yes'
    if [[ "$DETECTED_OS" == macos && "$RSYNC_BIN" != /usr/bin/rsync ]]; then
        use_chroot='no'
        print_warning_box \
            "DAEMON WILL RUN WITHOUT CHROOT CONFINEMENT" \
            "" \
            "macOS grants chroot(2) only to binaries carrying Apple's private" \
            "entitlement, which just /usr/bin/rsync holds. This one does not:" \
            "    $RSYNC_BIN" \
            "" \
            "While the daemon is up:" \
            "  • the module path is still the only exposed tree, but symlinks" \
            "    inside it are no longer confined to it" \
            "  • symlink munging stays OFF on purpose — turning it on would" \
            "    rewrite every symlink written to the destination" \
            "  • the module is unauthenticated, so any local user on this host" \
            "    can follow such a symlink and write as root" \
            "" \
            "Single-user target hosts only. To keep chroot, run step 1 with" \
            "Apple's /usr/bin/rsync instead — at the cost of -A/-X."
        # Same consent shape as the ACL/xattr degradation in cmd_source_transfer,
        # and for a stronger reason: that one costs fidelity, this one costs
        # confinement. prompt_yes_no returns 1 in non-interactive contexts, so
        # cron/ssh -T runs abort — the correct fail-safe when the default is "n".
        prompt_yes_no "→ Start the daemon without chroot confinement?" "n" ||
            die 69 "aborted — chroot confinement is unavailable for $RSYNC_BIN"
    fi

    local conf
    conf=$(build_daemon_config "$use_chroot" "$(date -Iseconds)")

    # Arm cleanup BEFORE writing, so an interrupt between tee and daemon start
    # still reaps the config on EXIT (see the cleanup() override above). Arming
    # unconditionally is safe now that both paths are proven not to pre-exist:
    # anything the trap finds there was created by this run.
    DAEMON_CONF="$CONF"
    DAEMON_LOCK="$LOCK_FILE"

    printf '%s\n' "$conf" | sudo tee "$CONF" >/dev/null
    sudo chmod 0600 "$CONF"
    print_success "✓ wrote $CONF"

    print_info "daemon in foreground — Ctrl-C when the transfer is done"
    sudo "$RSYNC_BIN" --daemon --no-detach --config="$CONF"
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
# Compose the transfer argv into TRANSFER_ARGS and record what could not be
# included in DROPPED_CAPS / DROPPED_BY_REMOTE.
#
# Extracted from cmd_source_transfer for the same reason build_daemon_config was
# extracted from cmd_target_tunnel: these are the flags a ROOT-privileged rsync
# is about to run with, and pulling them out makes them assertable with no
# daemon, no sudo and no second host. Decides only — it prompts for nothing and
# touches nothing, so the caller keeps ownership of the consent decision.
# Reads: RSYNC_HAS_ACLS, RSYNC_HAS_XATTRS, REMOTE_PROTOCOL, LOCAL_PROTOCOL,
#        DRY_RUN, DELETE, EXTRA.
compose_transfer_args() {
    # The archive flags are listed individually rather than bundled, so -A and -X
    # are ADDITIVE rather than negated: openrsync has no acls/xattrs options at
    # all, so --no-A would itself be an unknown option and hit usage(ERR_SYNTAX).
    TRANSFER_ARGS=(
        -a -H -S                        # archive + hardlinks + sparse
        --numeric-ids                   # ownership must transfer verbatim (an idmapped
                                        # container rootfs is the motivating case)
        -W                              # LAN: delta scan costs more than it saves
        --partial-dir=.rsync-migrate    # auto-excluded; resumable without half files
    )

    # Protocol 30 is required for -A/-X no matter what the local build supports.
    # REMOTE_PROTOCOL is empty when the probe could not determine it; default to
    # 30 so an unknown far end does not trigger the prompt — rsync will raise its
    # own error if it turns out to be too old.
    local remote_ok=true
    [[ "${REMOTE_PROTOCOL:-30}" -ge 30 ]] || remote_ok=false
    DROPPED_BY_REMOTE=false
    [[ "$remote_ok" == true ]] || DROPPED_BY_REMOTE=true

    # -A and -X are decided independently: a build can support one and not the
    # other, and collapsing them would drop preservation that was available.
    DROPPED_CAPS=()
    if [[ "$RSYNC_HAS_ACLS" == true && "$remote_ok" == true ]]; then
        TRANSFER_ARGS+=(-A)
    else
        DROPPED_CAPS+=("ACLs (-A)")
    fi
    if [[ "$RSYNC_HAS_XATTRS" == true && "$remote_ok" == true ]]; then
        TRANSFER_ARGS+=(-X)
    else
        DROPPED_CAPS+=("extended attributes (-X)")
    fi

    # --info=FLAGS shipped in rsync 3.1.0, which is exactly protocol 31, so this
    # is an exact test rather than a version heuristic (see parse_rsync_protocol).
    # THIS host's rsync formats the progress output, so only LOCAL_PROTOCOL is
    # consulted — the target has no say. An unknown local protocol assumes
    # capable: rsync then raises its own precise error, which beats silently
    # downgrading output on a build we misread.
    if ((${LOCAL_PROTOCOL:-31} >= 31)); then
        TRANSFER_ARGS+=(--info=progress2)
    else
        print_warning "⚠ --info=progress2 needs rsync 3.1+ (protocol 31); falling back to --progress"
        TRANSFER_ARGS+=(--progress)
    fi

    ((DRY_RUN)) && TRANSFER_ARGS+=(--dry-run)
    ((DELETE))  && TRANSFER_ARGS+=(--delete)
    TRANSFER_ARGS+=("${EXTRA[@]+"${EXTRA[@]}"}")
}

cmd_source_transfer() {
    require_rsync
    resolve_transfer_path
    # Probe BEFORE probe_daemon, not after. The module has `max connections = 1`,
    # so the abandoned greeting connection occupies the only slot until the
    # daemon reaps that child; probe_daemon already retries 3x with 2s sleeps for
    # exactly this reason, so probing first lets that loop absorb the slot.
    # Probing after would leave the abandoned child contending with the
    # retry-less `exec sudo rsync` transfer. A failed probe costs nothing here:
    # probe_daemon still produces its actionable error a moment later.
    probe_remote_protocol || true
    probe_daemon

    compose_transfer_args

    if ((${#DROPPED_CAPS[@]})); then
        # At most two entries, so join explicitly rather than reaching for IFS
        # tricks: "${arr[*]}" joins on the FIRST character of IFS only, so a
        # `local IFS=', '` would produce "a,b" and silently lose the space.
        local dropped_list="${DROPPED_CAPS[0]}"
        ((${#DROPPED_CAPS[@]} > 1)) && dropped_list+=", ${DROPPED_CAPS[1]}"

        # print_warning_box pads to a 69-character content width and truncates
        # anything longer (utils-misc.sh), so keep every line below that or it
        # loses its tail. In particular the binary path gets its own indented
        # line rather than being inlined into a sentence, because
        # "/opt/homebrew/bin/rsync" alone is 23 characters.
        local -a reason_lines
        if [[ "$DROPPED_BY_REMOTE" == true ]]; then
            reason_lines=("The target speaks protocol ${REMOTE_PROTOCOL}; -A/-X need 30 or higher.")
        else
            reason_lines=("This rsync does not support ${dropped_list}:" "    $RSYNC_BIN")
        fi

        print_warning_box \
            "METADATA CANNOT BE FULLY PRESERVED" \
            "" \
            "${reason_lines[@]}" \
            "" \
            "Dropping: ${dropped_list}" \
            "" \
            "This matters most for an idmapped container rootfs, where ACLs and" \
            "xattrs are part of the data. For an ordinary directory copy it is" \
            "usually harmless." \
            "" \
            "To preserve them, install rsync 3.x on BOTH hosts:" \
            "    brew install rsync" \
            "(macOS ships openrsync: protocol 29, no -A/-X)"
        # prompt_yes_no returns 1 in non-interactive contexts (cron, ssh -T), so
        # those runs abort — the correct fail-safe given the default is "n".
        prompt_yes_no "→ Continue without ${dropped_list}?" "n" ||
            die 69 "aborted — install rsync 3.x on both hosts to preserve ACLs/xattrs"
    fi

    print_info "source directory : $TRANSFER_PATH/"
    print_info "destination      : $DAEMON_URL"
    ((DRY_RUN)) && print_warning "⚠ DRY RUN — nothing will be written"
    ((DELETE))  && print_warning "⚠ --delete is ACTIVE: files absent on the source will be removed on the target"

    # The flag list is composed at runtime, so the help text can only describe the
    # always-present subset. Echo the real command so the operator can confirm at
    # a glance whether -A/-X survived capability detection — this is the tool
    # whose own docs tell you to verify with --itemize-changes.
    # Display only: the transfer execs the args array, never this string.
    print_info "running: sudo $RSYNC_BIN ${TRANSFER_ARGS[*]} ${TRANSFER_PATH}/ $DAEMON_URL"

    exec sudo "$RSYNC_BIN" "${TRANSFER_ARGS[@]}" "${TRANSFER_PATH}/" "$DAEMON_URL"
}

# -------------------------------------------------------------------- main --
# Validate every operator-supplied value that reaches a config file, a URL or a
# privileged command line. Split out of main() so it is testable without the
# self-update and stale-temp sweep main() performs first — same seam as
# build_daemon_config and compose_transfer_args.
# Reads: PORT, MODULE, TRANSFER_PATH, LOG_FILE, CONF. Exits on any failure.
validate_options() {
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

    return 0
}

main() {
    sweep_stale_temps '~*.tmp.??????'
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    # Help / no-args fast-path BEFORE any network/self-update work.
    if [[ $# -eq 0 ]]; then show_usage; exit 0; fi
    case "$1" in -h|--help|help) show_usage; exit 0 ;; esac

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

    validate_options

    # Only source-tunnel takes a positional. Swallowing one in the other steps
    # hides a wrong-terminal mistake in the middle of a migration.
    if [[ -n "$REMOTE" && "$mode" != "source-tunnel" ]]; then
        die 64 "unexpected argument '$REMOTE' — only 'source-tunnel' takes an ssh target"
    fi

    # Re-derive after parsing: --conf may have replaced CONF since the defaults
    # block set these. This and the defaults block are the ONLY two places the
    # lock path is computed (see the LOCK_FILE comment above).
    LOCK_FILE="${CONF%.conf}.lock"
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
