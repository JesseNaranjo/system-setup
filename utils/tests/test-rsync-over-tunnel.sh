#!/usr/bin/env bash
# test-rsync-over-tunnel.sh - Unit tests for rsync-over-tunnel.sh pure functions
#
# Zero dependencies: no bats, no network, no root, no second host. Sources the
# script under test (its `BASH_SOURCE == $0` guard keeps main() from running)
# and asserts on the pure parsers and the generated daemon config.
#
# Usage: ./test-rsync-over-tunnel.sh
set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../rsync-over-tunnel.sh
source "${TESTS_DIR}/../rsync-over-tunnel.sh"

TESTS_RUN=0
TESTS_FAILED=0

# The sourced script installs `trap cleanup EXIT`, and that handler only `rm -f`s
# TEMP_FILES entries — it cannot reap the `mktemp -d` DIRECTORIES this suite
# creates. Those used to be removed by straight-line calls at the end of each
# section, so any `set -e` abort in between leaked one. Replace the trap with a
# superset that reaps the directories and then delegates.
TEST_TEMP_DIRS=()
_test_cleanup() {
    local d
    for d in "${TEST_TEMP_DIRS[@]+"${TEST_TEMP_DIRS[@]}"}"; do
        rm -rf "$d"
    done
    cleanup
}
trap _test_cleanup EXIT

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    ((TESTS_RUN++)) || true
    if [[ "$expected" == "$actual" ]]; then
        printf '  ok   %s\n' "$label"
    else
        printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' \
            "$label" "$expected" "$actual"
        ((TESTS_FAILED++)) || true
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    ((TESTS_RUN++)) || true
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  ok   %s\n' "$label"
    else
        printf '  FAIL %s\n         missing: %s\n' "$label" "$needle"
        ((TESTS_FAILED++)) || true
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="$3"
    ((TESTS_RUN++)) || true
    if [[ "$haystack" != *"$needle"* ]]; then
        printf '  ok   %s\n' "$label"
    else
        printf '  FAIL %s\n         unexpectedly present: %s\n' "$label" "$needle"
        ((TESTS_FAILED++)) || true
    fi
}

# ---------------------------------------------------------------- fixtures --
# Real `--version` output. openrsync has two shapes: macOS 15.4 and macOS 26.
readonly FIXTURE_OPENRSYNC_154=$'openrsync: protocol version 29\nrsync version 2.6.9 compatible'
readonly FIXTURE_OPENRSYNC_26=$'openrsync 2.6.9, protocol version 29'
readonly FIXTURE_RSYNC_269=$'rsync  version 2.6.9  protocol version 29'
# 3.0.9 is the load-bearing boundary case for --info: protocol 30, so ACLs/xattrs
# are fine but --info=FLAGS does not exist yet (it arrived with 3.1.0/protocol 31).
readonly FIXTURE_RSYNC_309=$'rsync  version 3.0.9  protocol version 30
Capabilities:
    64-bit files, 64-bit inums, 64-bit timestamps, socketpairs,
    hardlinks, symlinks, IPv6, batchfiles, inplace, append, ACLs,
    xattrs, iconv, symtimes'
readonly FIXTURE_RSYNC_344=$'rsync  version 3.4.4  protocol version 32
Capabilities:
    64-bit files, 64-bit inums, 64-bit timestamps, socketpairs,
    symlinks, symtimes, hardlinks, IPv6, batchfiles, inplace, ACLs,
    xattrs, optional protect-args, iconv, prealloc, no crtimes'
readonly FIXTURE_RSYNC_344_NOACL=$'rsync  version 3.4.4  protocol version 32
Capabilities:
    64-bit files, symlinks, hardlinks, IPv6, inplace, no ACLs,
    no xattrs, iconv, prealloc, no crtimes'
# Asymmetric build: ACLs compiled in, xattrs not. Proves the two are tracked
# independently rather than collapsed into a single flag.
readonly FIXTURE_RSYNC_344_ACL_ONLY=$'rsync  version 3.4.4  protocol version 32
Capabilities:
    64-bit files, symlinks, hardlinks, IPv6, inplace, ACLs,
    no xattrs, iconv, prealloc, no crtimes'

# die() calls exit, so guard-failure cases must run in a subshell or they would
# terminate this suite. The subshell also discards TRANSFER_PATH mutations, so
# the positive cases call resolve_transfer_path directly instead.
# The 2>&1 redirect is load-bearing beyond quieting output: print_error only
# rings the bell and sleeps 2 when `[[ -t 2 ]]`, so sending fd 2 to /dev/null
# keeps each expected-failure assertion instant instead of costing 2 seconds.
rc() {
    local status=0
    ( "$@" ) >/dev/null 2>&1 || status=$?
    printf '%s' "$status"
}

echo "== parse_rsync_impl =="
parse_rsync_impl "$FIXTURE_OPENRSYNC_154"; assert_eq openrsync "$RSYNC_IMPL" "macOS 15.4 openrsync"
parse_rsync_impl "$FIXTURE_OPENRSYNC_26";  assert_eq openrsync "$RSYNC_IMPL" "macOS 26 openrsync"
parse_rsync_impl "$FIXTURE_RSYNC_344";     assert_eq rsync     "$RSYNC_IMPL" "GNU rsync 3.4.4"
parse_rsync_impl "$FIXTURE_RSYNC_269";     assert_eq rsync     "$RSYNC_IMPL" "GNU rsync 2.6.9"

echo "== parse_rsync_caps =="
parse_rsync_caps "$FIXTURE_OPENRSYNC_154"
assert_eq false "$RSYNC_HAS_ACLS"   "openrsync: no ACLs"
assert_eq false "$RSYNC_HAS_XATTRS" "openrsync: no xattrs"
parse_rsync_caps "$FIXTURE_RSYNC_269"
assert_eq false "$RSYNC_HAS_ACLS"   "2.6.9: no ACLs"
assert_eq false "$RSYNC_HAS_XATTRS" "2.6.9: no xattrs"
parse_rsync_caps "$FIXTURE_RSYNC_344"
assert_eq true  "$RSYNC_HAS_ACLS"   "3.4.4: ACLs"
assert_eq true  "$RSYNC_HAS_XATTRS" "3.4.4: xattrs"
# A 3.x build compiled without support prints "no ACLs" — the bare word is not enough.
parse_rsync_caps "$FIXTURE_RSYNC_344_NOACL"
assert_eq false "$RSYNC_HAS_ACLS"   "3.4.4 built without ACLs"
assert_eq false "$RSYNC_HAS_XATTRS" "3.4.4 built without xattrs"
# The asymmetric case is the whole reason these are two flags.
parse_rsync_caps "$FIXTURE_RSYNC_344_ACL_ONLY"
assert_eq true  "$RSYNC_HAS_ACLS"   "asymmetric build: ACLs kept"
assert_eq false "$RSYNC_HAS_XATTRS" "asymmetric build: xattrs dropped"

echo "== parse_rsync_protocol =="
# --info=FLAGS shipped in rsync 3.1.0, which is exactly protocol 31, so the
# protocol number is a precise proxy for --info support and needs no dotted
# version comparison. 3.0.9 (protocol 30) is the boundary that proves it.
parse_rsync_protocol "$FIXTURE_OPENRSYNC_154"; assert_eq 29 "$LOCAL_PROTOCOL" "openrsync 15.4 -> 29"
parse_rsync_protocol "$FIXTURE_OPENRSYNC_26";  assert_eq 29 "$LOCAL_PROTOCOL" "openrsync 26 -> 29"
parse_rsync_protocol "$FIXTURE_RSYNC_269";     assert_eq 29 "$LOCAL_PROTOCOL" "rsync 2.6.9 -> 29"
parse_rsync_protocol "$FIXTURE_RSYNC_309";     assert_eq 30 "$LOCAL_PROTOCOL" "rsync 3.0.9 -> 30 (no --info)"
parse_rsync_protocol "$FIXTURE_RSYNC_344";     assert_eq 32 "$LOCAL_PROTOCOL" "rsync 3.4.4 -> 32"
if parse_rsync_protocol 'totally unparseable'; then
    assert_eq "returns 1" "returned 0" "unparseable --version rejected"
else
    assert_eq "returns 1" "returns 1" "unparseable --version rejected"
fi

echo "== parse_rsyncd_greeting =="
parse_rsyncd_greeting '@RSYNCD: 31.0 md5 md4'; assert_eq 31 "$REMOTE_PROTOCOL" "GNU daemon proto 31"
parse_rsyncd_greeting '@RSYNCD: 29';           assert_eq 29 "$REMOTE_PROTOCOL" "openrsync proto 29"
if parse_rsyncd_greeting 'garbage'; then
    assert_eq "returns 1" "returned 0" "non-greeting rejected"
else
    assert_eq "returns 1" "returns 1" "non-greeting rejected"
fi

echo "== detect_os =="
# Drive all three branches by overriding OSTYPE, rather than asserting that
# detect_os agrees with the host it happens to run on — that would only ever
# exercise one branch and would pass even if the other two were broken.
# OSTYPE is an ordinary shell variable, so it can be set and restored.
_saved_ostype="$OSTYPE"
OSTYPE=darwin24.0; detect_os; assert_eq macos   "$DETECTED_OS" "darwin* -> macos"
OSTYPE=linux-gnu;  detect_os; assert_eq linux   "$DETECTED_OS" "linux-gnu* -> linux"
OSTYPE=freebsd14;  detect_os; assert_eq unknown "$DETECTED_OS" "other -> unknown"
OSTYPE="$_saved_ostype"; detect_os   # restore, so later assertions see the real host

echo "== require_rsync =="
# Verify the wiring, not the parsers (covered above): that require_rsync resolves
# an ABSOLUTE path (load-bearing — `sudo` resolves bare names against its own
# secure_path, so `sudo rsync` could run /usr/bin/rsync even with Homebrew's
# first in PATH) and feeds one --version read into all three parsers.
# A shim is used rather than the host's rsync because openrsync cannot be
# installed on Linux at all, and that is the case this script exists to handle.
_shim_dir=$(mktemp -d)
TEST_TEMP_DIRS+=("$_shim_dir")
_make_rsync_shim() {
    printf '#!/usr/bin/env bash\ncat <<%s\n%s\n%s\n' 'SHIMEOF' "$1" 'SHIMEOF' > "${_shim_dir}/rsync"
    chmod +x "${_shim_dir}/rsync"
}
_saved_path="$PATH"

_make_rsync_shim "$FIXTURE_OPENRSYNC_154"
PATH="${_shim_dir}:${_saved_path}"; require_rsync >/dev/null 2>&1
assert_eq "${_shim_dir}/rsync" "$RSYNC_BIN"        "resolves to an absolute path"
assert_eq openrsync "$RSYNC_IMPL"                  "openrsync shim classified"
assert_eq 29        "$LOCAL_PROTOCOL"              "openrsync shim protocol"
assert_eq false     "$RSYNC_HAS_ACLS"              "openrsync shim has no ACLs"

_make_rsync_shim "$FIXTURE_RSYNC_344"
PATH="${_shim_dir}:${_saved_path}"; require_rsync >/dev/null 2>&1
assert_eq rsync "$RSYNC_IMPL"                      "GNU shim classified"
assert_eq 32    "$LOCAL_PROTOCOL"                  "GNU shim protocol"
assert_eq true  "$RSYNC_HAS_ACLS"                  "GNU shim has ACLs"

# An rsync whose --version we cannot parse must not abort: LOCAL_PROTOCOL stays
# empty and the caller treats unknown as "assume capable".
LOCAL_PROTOCOL=''
_make_rsync_shim 'some totally unknown rsync fork'
PATH="${_shim_dir}:${_saved_path}"; require_rsync >/dev/null 2>&1
assert_eq '' "$LOCAL_PROTOCOL"                     "unparseable --version leaves protocol empty"

PATH="$_saved_path"

echo "== resolve_transfer_path =="
TRANSFER_PATH=''
assert_eq 64 "$(rc resolve_transfer_path)" "empty path -> EX_USAGE"

# The leading-dash guard: without it this reaches `stat` and `sudo rsync` as an
# option bundle, the same class as CVE-2023-51385 / CVE-2025-61984.
TRANSFER_PATH='-oProxyCommand=touch /tmp/pwned'
assert_eq 64 "$(rc resolve_transfer_path)" "leading dash -> EX_USAGE"

TRANSFER_PATH='/nonexistent/definitely/not/here'
assert_eq 66 "$(rc resolve_transfer_path)" "missing dir -> EX_NOINPUT"

# Positive cases run in-process so the TRANSFER_PATH mutation is observable.
tmpdir=$(mktemp -d)
TEST_TEMP_DIRS+=("$tmpdir")
TRANSFER_PATH="$tmpdir"
resolve_transfer_path
assert_eq "$tmpdir" "$TRANSFER_PATH" "existing dir accepted"

TRANSFER_PATH="${tmpdir}/"
resolve_transfer_path
assert_eq "$tmpdir" "$TRANSFER_PATH" "trailing slash stripped"

echo "== validate_options =="
# Everything here reaches a generated config file, an rsync:// URL, or a
# privileged command line, so each rejection is asserted rather than assumed.
# validate_options is split out of main() precisely so this needs no network,
# no daemon and no temp sweep.
PORT=8730; MODULE=xfer; TRANSFER_PATH=/tmp; LOG_FILE=/dev/stdout; CONF=/run/x.conf
assert_eq 0 "$(rc validate_options)"            "valid options accepted"

# Leading zero is the load-bearing case: bash reads 08/077 as OCTAL, so a
# numeric-only check let a bad port reach the daemon config and the ssh forward.
PORT=08;    assert_eq 64 "$(rc validate_options)" "leading-zero port rejected"
PORT=0;     assert_eq 64 "$(rc validate_options)" "port 0 rejected"
PORT=65536; assert_eq 64 "$(rc validate_options)" "port 65536 rejected"
PORT=99999; assert_eq 64 "$(rc validate_options)" "5-digit over-range port rejected"
PORT=abc;   assert_eq 64 "$(rc validate_options)" "non-numeric port rejected"
PORT=65535; assert_eq 0  "$(rc validate_options)" "port 65535 accepted (boundary)"
PORT=1;     assert_eq 0  "$(rc validate_options)" "port 1 accepted (boundary)"
PORT=8730

# MODULE becomes an rsyncd.conf section header AND the last URL path element.
MODULE='xfer/../etc'; assert_eq 64 "$(rc validate_options)" "module with slashes rejected"
MODULE='x y';         assert_eq 64 "$(rc validate_options)" "module with space rejected"
MODULE='';            assert_eq 64 "$(rc validate_options)" "empty module rejected"
MODULE='a.b_c-1';     assert_eq 0  "$(rc validate_options)" "module charset accepted"
MODULE=xfer

# rsyncd.conf is line-oriented with no escape syntax, so a newline in any
# interpolated value injects daemon directives (a second [module], a
# `pre-xfer exec = …`) and defeats the chroot/loopback confinement.
TRANSFER_PATH=$'/tmp\npre-xfer exec = /bin/sh'
assert_eq 64 "$(rc validate_options)" "newline in --path rejected"
TRANSFER_PATH=/tmp
LOG_FILE=$'/dev/stdout\nuid = root'
assert_eq 64 "$(rc validate_options)" "newline in --log rejected"
LOG_FILE=/dev/stdout
CONF=$'/run/x.conf\n[evil]'
assert_eq 64 "$(rc validate_options)" "newline in --conf rejected"
CONF=/run/x.conf

echo "== cmd_source_tunnel option-injection guard =="
# ssh has no `--` end-of-options marker, so a target beginning with `-` is
# parsed as an option and `-oProxyCommand=…` runs an arbitrary local command
# (cf. CVE-2023-51385 / CVE-2025-61984). The identical guard in
# resolve_transfer_path was already covered; this one was not.
REMOTE=''
assert_eq 64 "$(rc cmd_source_tunnel)" "missing ssh target -> EX_USAGE"
REMOTE='-oProxyCommand=touch /tmp/pwned'
assert_eq 64 "$(rc cmd_source_tunnel)" "option-like ssh target rejected"
REMOTE=''

echo "== build_daemon_config =="
# NOTE: do NOT assign SCRIPT_NAME or SCRIPT_DIR here — both are `readonly` in
# the sourced script, so assigning aborts the suite under `set -e`. When sourced
# from this file, SCRIPT_NAME resolves to this test's own basename, so the
# generated header line is asserted on the injected stamp only, never the name.
PORT=8730
MODULE=xfer
TRANSFER_PATH=/tmp/example
CONF=/run/rsyncd-migrate.conf
# Set explicitly rather than inherited: main() derives LOCK_FILE from CONF after
# parsing, and build_daemon_config reads the derived global, not CONF.
LOCK_FILE=/run/rsyncd-migrate.lock
LOG_FILE=/dev/stdout

conf_yes=$(build_daemon_config yes 2026-08-04T00:00:00Z)
assert_contains     "$conf_yes" 'use chroot = yes'      "chroot yes honored"
assert_contains     "$conf_yes" '[xfer]'                "module section header"
assert_contains     "$conf_yes" 'path = /tmp/example'   "module path"
assert_contains     "$conf_yes" 'port = 8730'           "port"
assert_contains     "$conf_yes" 'lock file = /run/rsyncd-migrate.lock' "lock derived from CONF"
assert_contains     "$conf_yes" '2026-08-04T00:00:00Z'  "stamp is injected, not read from clock"
# This config grants root write access over a socket. Every directive that
# confines it is asserted, so a careless edit to the printf block trips a test
# rather than silently widening exposure.
assert_contains     "$conf_yes" 'uid = 0'               "runs as root (intended)"
assert_contains     "$conf_yes" 'gid = 0'               "runs as the superuser group (intended)"
# Regression guard for the macOS↔macOS acceptance run: macOS has no group named
# "root" (gid 0 is "wheel"), so a name here made every macOS target daemon
# answer "@ERROR <module>: gid 'root' invalid" at connect time — long after
# step 1 had started and reported success. Numeric 0 needs no name lookup and
# resolves on both platforms via openrsync's strtoll fallback.
assert_not_contains "$conf_yes" 'uid = root'            "uid is numeric, not a name"
assert_not_contains "$conf_yes" 'gid = root'            "gid is numeric, not a name"
assert_contains     "$conf_yes" 'address = 127.0.0.1'   "binds loopback only"
assert_contains     "$conf_yes" 'hosts allow = 127.0.0.1' "loopback allow-list"
assert_contains     "$conf_yes" 'hosts deny = *'        "deny-by-default"
assert_contains     "$conf_yes" 'max connections = 1'   "single connection slot"
assert_contains     "$conf_yes" 'read only = false'     "writable (intended)"
assert_contains     "$conf_yes" 'list = false'          "module not listable"
assert_contains     "$conf_yes" 'numeric ids = yes'     "ownership verbatim"
# Regression guard for macOS bug #4: openrsync rejects unknown keys fatally.
assert_not_contains "$conf_yes" 'reverse lookup'        "no reverse lookup directive"

conf_no=$(build_daemon_config no 2026-08-04T00:00:00Z)
assert_contains     "$conf_no"  'use chroot = no'       "chroot no honored"

# `munge symlinks` is the one directive that is a security TRADE, so both
# branches are pinned. rsyncd defaults munging off when chroot is on with an
# inside-chroot path of "/" (rsyncd.conf(5)) — which is exactly the chroot=yes
# case — so emitting it there is a no-op that only gives openrsync's parser one
# more key to reject. With chroot off the default flips ON, and munging would
# rewrite every received symlink to /rsyncd-munged/… — corruption, for a tool
# whose payload is a rootfs. So it is disabled explicitly, and only there.
assert_not_contains "$conf_yes" 'munge symlinks'        "munge directive omitted under chroot"
assert_contains     "$conf_no"  'munge symlinks = no'   "symlinks preserved without chroot"
# The invariant behind both: never claim chroot AND leave munging on, and never
# emit a munge line the chrooted daemon would ignore.
if [[ "$conf_yes" == *'use chroot = yes'* && "$conf_yes" != *'munge symlinks'* ]] &&
   [[ "$conf_no"  == *'use chroot = no'*  && "$conf_no"  == *'munge symlinks = no'* ]]; then
    assert_eq "invariant holds" "invariant holds" "chroot/munge pairing is never contradictory"
else
    assert_eq "invariant holds" "VIOLATED"        "chroot/munge pairing is never contradictory"
fi

echo "== cmd_target_tunnel refuses to clobber existing files =="
# The generated config and its derived .lock are DELETED by the EXIT trap, so
# writing over an existing file destroys it. `--conf /etc/rsyncd.conf` used to
# clobber and then remove the host's real daemon config plus /etc/rsyncd.lock —
# a path the operator never named. Both guards sit before `sudo -v`, so nothing
# here elevates or starts a daemon. rsync and sudo are shimmed so the section
# runs identically on a host that has neither.
_guard_dir=$(mktemp -d)
TEST_TEMP_DIRS+=("$_guard_dir")
mkdir -p "${_guard_dir}/dest" "${_guard_dir}/bin"
printf '#!/usr/bin/env bash\ncat <<%s\n%s\n%s\n' 'SHIMEOF' "$FIXTURE_RSYNC_344" 'SHIMEOF' > "${_guard_dir}/bin/rsync"
# `sudo -v` is the first thing past the guards, so an exit-77 shim marks that
# boundary: 73 means a guard fired, 77 means both guards passed.
printf '#!/usr/bin/env bash\nexit 77\n' > "${_guard_dir}/bin/sudo"
chmod +x "${_guard_dir}/bin/rsync" "${_guard_dir}/bin/sudo"
_saved_path2="$PATH"
PATH="${_guard_dir}/bin:${_saved_path2}"

TRANSFER_PATH="${_guard_dir}/dest"
PORT=8730; MODULE=xfer; LOG_FILE=/dev/stdout

: > "${_guard_dir}/pre-existing.conf"
CONF="${_guard_dir}/pre-existing.conf"
LOCK_FILE="${CONF%.conf}.lock"
assert_eq 73 "$(rc cmd_target_tunnel)" "existing --conf target refused (EX_CANTCREAT)"

CONF="${_guard_dir}/fresh.conf"
LOCK_FILE="${CONF%.conf}.lock"
: > "$LOCK_FILE"
assert_eq 73 "$(rc cmd_target_tunnel)" "existing derived .lock refused (EX_CANTCREAT)"
rm -f "$LOCK_FILE"

# The guards must NOT fire on clean paths, or they would break the normal case.
assert_eq 77 "$(rc cmd_target_tunnel)" "clean paths pass the guards and reach sudo"
PATH="$_saved_path2"

echo "== compose_transfer_args =="
# These are the flags a ROOT-privileged rsync is about to run with, so every
# branch is pinned rather than eyeballed. ARGV_STR is joined with a leading and
# trailing space so a search for " -A " cannot match inside "--partial-dir".
#
# Result goes to a GLOBAL rather than stdout, and callers use `_argv …; x=$ARGV_STR`
# rather than `x=$(_argv …)`: command substitution runs the function in a
# SUBSHELL, so DROPPED_CAPS / DROPPED_BY_REMOTE would be set there and the
# parent would still see the previous call's values.
ARGV_STR=''
_argv() {
    RSYNC_HAS_ACLS="$1"
    RSYNC_HAS_XATTRS="$2"
    REMOTE_PROTOCOL="$3"
    LOCAL_PROTOCOL="$4"
    DRY_RUN="$5"
    DELETE="$6"
    EXTRA=()
    compose_transfer_args >/dev/null
    ARGV_STR=" ${TRANSFER_ARGS[*]} "
}

# Everything a transfer always carries, whatever the capability probe found.
_argv true true 32 32 0 0; base="$ARGV_STR"
for flag in ' -a ' ' -H ' ' -S ' ' --numeric-ids ' ' -W ' ' --partial-dir=.rsync-migrate '; do
    assert_contains "$base" "$flag" "always present:${flag% }"
done

# Modern rsync on both ends: full fidelity, nothing dropped.
assert_contains "$base" ' -A '                "3.4.4 <-> proto 32: ACLs kept"
assert_contains "$base" ' -X '                "3.4.4 <-> proto 32: xattrs kept"
assert_contains "$base" ' --info=progress2 '  "proto 32 local: --info=progress2"
assert_eq 0 "${#DROPPED_CAPS[@]}"             "nothing dropped when both ends are capable"
assert_eq false "$DROPPED_BY_REMOTE"          "remote not blamed when it is fine"

# openrsync locally (no -A/-X compiled in, protocol 29) talking to openrsync.
_argv false false 29 29 0 0; oprsync="$ARGV_STR"
assert_not_contains "$oprsync" ' -A '               "openrsync: no -A"
assert_not_contains "$oprsync" ' -X '               "openrsync: no -X"
assert_not_contains "$oprsync" ' --info=progress2 ' "proto 29: no --info=progress2"
assert_contains     "$oprsync" ' --progress '       "proto 29 falls back to --progress"
assert_eq 2 "${#DROPPED_CAPS[@]}"                   "openrsync drops both capabilities"

# Asymmetric build — the whole reason -A and -X are two decisions, not one.
_argv true false 32 32 0 0; asym="$ARGV_STR"
assert_contains     "$asym" ' -A '   "asymmetric build keeps -A"
assert_not_contains "$asym" ' -X '   "asymmetric build drops -X"
assert_eq 1 "${#DROPPED_CAPS[@]}"    "asymmetric build drops exactly one"
assert_eq "extended attributes (-X)" "${DROPPED_CAPS[0]}" "asymmetric build names the right one"

# Capable local build, far end too old: protocol 30 is required for -A/-X no
# matter what this side supports. The operator must be told which side is at fault.
_argv true true 29 32 0 0; oldremote="$ARGV_STR"
assert_not_contains "$oldremote" ' -A ' "remote proto 29 blocks -A"
assert_not_contains "$oldremote" ' -X ' "remote proto 29 blocks -X"
assert_eq true "$DROPPED_BY_REMOTE"     "remote is blamed when the remote is at fault"

# Unknown far end (probe failed) must NOT trigger the prompt: rsync raises its
# own precise error if it really is too old.
_argv true true "" 32 0 0; unknown="$ARGV_STR"
assert_contains "$unknown" ' -A '     "unknown remote assumed capable"
assert_eq 0 "${#DROPPED_CAPS[@]}"     "unknown remote drops nothing"

# 3.0.9 is the boundary: protocol 30, so ACLs/xattrs are fine but --info is not.
_argv true true 30 30 0 0; b309="$ARGV_STR"
assert_contains     "$b309" ' -A '                "proto 30: ACLs kept"
assert_not_contains "$b309" ' --info=progress2 '  "proto 30: --info not yet available"
assert_contains     "$b309" ' --progress '        "proto 30 falls back to --progress"

# Unknown LOCAL protocol assumes capable, same rationale as the remote.
_argv true true 32 "" 0 0; localunknown="$ARGV_STR"
assert_contains "$localunknown" ' --info=progress2 ' "unknown local protocol assumed 3.1+"

_argv true true 32 32 1 1; flags="$ARGV_STR"
assert_contains "$flags" ' --dry-run ' "--dry-run forwarded"
assert_contains "$flags" ' --delete '  "--delete forwarded"
assert_not_contains "$base" ' --delete ' "--delete absent unless asked for"

# Everything after `--` is appended verbatim, and must land AFTER the composed
# flags so it can override them.
RSYNC_HAS_ACLS=true; RSYNC_HAS_XATTRS=true; REMOTE_PROTOCOL=32; LOCAL_PROTOCOL=32
DRY_RUN=0; DELETE=0; EXTRA=(--no-whole-file --itemize-changes)
compose_transfer_args >/dev/null
assert_eq "--itemize-changes" "${TRANSFER_ARGS[-1]}"   "EXTRA is appended last"
assert_contains " ${TRANSFER_ARGS[*]} " ' --no-whole-file ' "EXTRA passed through"
EXTRA=()

echo "== download_script content gate =="
# The downloaded file is about to be chmod +x'd, mv'd over a running script and
# exec'd, so this gate is a security boundary. It lives in utils-misc.sh, which
# the script under test sources, so it is in scope here. curl is shimmed: the
# body is whatever $DL_BODY holds and the HTTP status whatever $DL_STATUS holds.
_dl_dir=$(mktemp -d)
TEST_TEMP_DIRS+=("$_dl_dir")
mkdir -p "${_dl_dir}/bin"
cat > "${_dl_dir}/bin/curl" <<'SHIM'
#!/usr/bin/env bash
# Mimic the real invocation: write the body to the -o path, print the status.
out=""
while (($#)); do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s' "$DL_BODY" > "$out"
printf '%s' "${DL_STATUS:-200}"
SHIM
chmod +x "${_dl_dir}/bin/curl"
_saved_path3="$PATH"
PATH="${_dl_dir}/bin:${_saved_path3}"
DOWNLOAD_CMD=curl

_gate() {   # $1 = body, $2 = http status -> "<rc>:<file exists?>"
    local target="${_dl_dir}/out.sh" rc=0
    rm -f "$target"
    DL_BODY="$1" DL_STATUS="$2" download_script fake.sh "$target" >/dev/null 2>&1 || rc=$?
    printf '%s:%s' "$rc" "$( [[ -e "$target" ]] && echo kept || echo removed )"
}

assert_eq '0:kept'    "$(_gate $'#!/usr/bin/env bash\necho hi\n' 200)" "a real script is accepted"
assert_eq '1:removed' "$(_gate $'<html>\n<code>#!/bin/sh</code>\n</html>\n' 200)" \
    "an HTML page quoting a shebang below line 1 is rejected and deleted"
assert_eq '1:removed' "$(_gate $'#!/usr/bin/env bash\r\necho hi\n' 200)" \
    "a CRLF-terminated shebang is rejected and deleted"
assert_eq '1:removed' "$(_gate $'' 200)"                    "an empty body is rejected and deleted"
assert_eq '1:removed' "$(_gate $'#!/bin/sh\n' 404)"         "HTTP 404 is rejected even with a valid shebang"
assert_eq '1:removed' "$(_gate $'#!/bin/sh\n' 000)"         "a transport failure is rejected"
assert_eq '1:removed' "$(_gate $'#!/bin/sh\n' 429)"         "rate limiting is rejected"

PATH="$_saved_path3"
DOWNLOAD_CMD=""

echo "== _sanitize_ansi =="
# The diff preview renders freshly downloaded file content, so a hostile file
# must not be able to repaint the screen over the default-yes overwrite prompt.
# SGR colour has to survive — that is what the box is for.
_san() { printf '%s' "$1" | _sanitize_ansi | cat -v; }
assert_eq 'AB' "$(_san $'A\033cB')"             "RIS (clears the whole terminal) stripped"
assert_eq 'AB' "$(_san $'A\033MB')"             "RI (scroll) stripped"
assert_eq 'AB' "$(_san $'A\0337B')"             "DECSC (save cursor) stripped"
assert_eq 'AB' "$(_san $'A\0338B')"             "DECRC (restore cursor) stripped"
assert_eq 'AB' "$(_san $'A\033[2JB')"           "CSI erase-display stripped"
assert_eq 'AB' "$(_san $'A\033[HB')"            "CSI cursor-home stripped"
assert_eq 'AB' "$(_san $'A\033[?25lB')"         "CSI hide-cursor stripped"
assert_eq 'AB' "$(_san $'A\033]0;pwn\007B')"    "OSC set-title (BEL) stripped"
assert_eq 'AB' "$(_san $'A\033]0;pwn\033\\B')"  "OSC set-title (ST) stripped"
assert_eq 'AB' "$(_san $'A\033_evil\033\\B')"   "APC string stripped"
assert_eq 'A'  "$(_san $'A\033[38;5')"          "CSI truncated at EOL stripped"
assert_eq '^[[31mRED^[[0m'          "$(_san $'\033[31mRED\033[0m')"          "SGR colour survives"
assert_eq '^[[1;32mBOLD^[[0m'       "$(_san $'\033[1;32mBOLD\033[0m')"       "compound SGR survives"
assert_eq '^[[38;2;255;0;0mX^[[0m'  "$(_san $'\033[38;2;255;0;0mX\033[0m')"  "truecolour SGR survives"
assert_eq 'plain text'              "$(_san 'plain text')"                   "plain text untouched"
# The whole attack in one line: wipe the screen, home the cursor, print a lie.
assert_eq '^[[1mno changes detected^[[0m' \
    "$(_san $'\033[2J\033[H\033[1mno changes detected\033[0m')" "screen-repaint attack neutralised"

echo "== print_warning_box =="
# Every row must be the same width. printf's "%-Ns" pads by BYTES, so before the
# fix any row carrying a multi-byte glyph rendered short of the border.
# Measured between the first and last box character, which sidesteps the colour
# codes without needing a non-portable sed.
_box_widths() {
    local line body
    local -a widths=()
    while IFS= read -r line; do
        case "$line" in
            *║*) body="${line#*║}"; body="${body%║*}"; widths+=("${#body}") ;;
            *╔*) body="${line#*╔}"; body="${body%╗*}"; widths+=("${#body}") ;;
            *╚*) body="${line#*╚}"; body="${body%╝*}"; widths+=("${#body}") ;;
        esac
    done < <(print_warning_box "$@")
    printf '%s\n' "${widths[@]}" | sort -u | tr '\n' ' '
}
assert_eq '77 ' "$(_box_widths 'plain ascii row')" "ASCII rows match the border"
assert_eq '77 ' "$(_box_widths '  • bullet — dash ✓ check')" "multi-byte glyph row matches the border"
assert_eq '77 ' "$(_box_widths "$(printf 'X%.0s' $(seq 1 200))")" "over-long row is truncated to the border"
assert_eq '77 ' "$(_box_widths 'a' '  • b' '' 'ccc')" "mixed rows all match the border"

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
