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
rm -rf "$_shim_dir"

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
TRANSFER_PATH="$tmpdir"
resolve_transfer_path
assert_eq "$tmpdir" "$TRANSFER_PATH" "existing dir accepted"

TRANSFER_PATH="${tmpdir}/"
resolve_transfer_path
assert_eq "$tmpdir" "$TRANSFER_PATH" "trailing slash stripped"
rmdir "$tmpdir"

echo "== build_daemon_config =="
# NOTE: do NOT assign SCRIPT_NAME or SCRIPT_DIR here — both are `readonly` in
# the sourced script, so assigning aborts the suite under `set -e`. When sourced
# from this file, SCRIPT_NAME resolves to this test's own basename, so the
# generated header line is asserted on the injected stamp only, never the name.
PORT=8730
MODULE=xfer
TRANSFER_PATH=/tmp/example
CONF=/run/rsyncd-migrate.conf
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
assert_contains     "$conf_yes" 'uid = root'            "runs as root (intended)"
assert_contains     "$conf_yes" 'address = 127.0.0.1'   "binds loopback only"
assert_contains     "$conf_yes" 'hosts allow = 127.0.0.1' "loopback allow-list"
assert_contains     "$conf_yes" 'hosts deny = *'        "deny-by-default"
assert_contains     "$conf_yes" 'max connections = 1'   "single connection slot"
assert_contains     "$conf_yes" 'read only = false'     "writable (intended)"
assert_contains     "$conf_yes" 'list = false'          "module not listable"
assert_contains     "$conf_yes" 'numeric ids = yes'     "ownership verbatim"
assert_contains     "$conf_yes" 'munge symlinks = no'   "symlinks preserved"
# Regression guard for macOS bug #4: openrsync rejects unknown keys fatally.
assert_not_contains "$conf_yes" 'reverse lookup'        "no reverse lookup directive"

conf_no=$(build_daemon_config no 2026-08-04T00:00:00Z)
assert_contains     "$conf_no"  'use chroot = no'       "chroot no honored"

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
