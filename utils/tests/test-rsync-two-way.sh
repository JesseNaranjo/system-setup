#!/usr/bin/env bash
# test-rsync-two-way.sh - Unit tests for rsync-two-way.sh's argument guards
#
# Zero dependencies: no rsync, no ssh, no network, no second host. Sources the
# script under test (its `BASH_SOURCE == $0` guard keeps main() from running,
# so check_for_updates never fires) and asserts on validate_sync_args, which
# checks LOCAL_DIR and REMOTE_SPEC before main reaches ssh or rsync.
#
# Usage: ./test-rsync-two-way.sh
set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR

# HOME points into a sandbox BEFORE the script is sourced: the script binds
# LOG_FILE to ~/.rsync-two-way.log at source time, and neither a case below
# nor the child run at the end may write to the developer's real log. The
# provisional trap reaps the sandbox if sourcing exits 69 (missing library,
# bash older than 5); _test_cleanup replaces it below.
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
HOME="$sandbox"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../rsync-two-way.sh
source "${TESTS_DIR}/../rsync-two-way.sh"

TESTS_RUN=0
TESTS_FAILED=0

# The sourced script installs `trap cleanup EXIT` (from utils-misc.sh), and that
# handler only `rm -f`s TEMP_FILES entries — it cannot reap the `mktemp -d`
# sandbox above. Replace the trap with a superset that reaps the sandbox and
# then delegates.
TEST_TEMP_DIRS=("$sandbox")
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

# Exit status of a call, run in a subshell so a rejected case cannot leave
# REMOTE_USER_HOST / REMOTE_HOST set for the next one. The 2>&1 redirect is
# load-bearing beyond quieting output: print_error only rings the bell and
# sleeps 2 when `[[ -t 2 ]]`, so sending fd 2 to /dev/null keeps each
# expected-failure assertion instant.
rc() {
    local status=0
    ( "$@" ) >/dev/null 2>&1 || status=$?
    printf '%s' "$status"
}

# stderr of a call, stdout discarded. print_error writes to stderr; the
# print_info hint that follows it goes to stdout and is not asserted on.
_stderr() {
    local out
    out=$("$@" 2>&1 >/dev/null) || true
    printf '%s' "$out"
}

# "<status>|<REMOTE_USER_HOST>|<REMOTE_HOST>" for one accepted spec. Called
# through $(…), so each case starts from empty globals in its own subshell.
_split() {
    local status=0
    REMOTE_USER_HOST='' REMOTE_HOST=''
    validate_sync_args "$1" "$2" >/dev/null 2>&1 || status=$?
    printf '%s|%s|%s' "$status" "$REMOTE_USER_HOST" "$REMOTE_HOST"
}

# A real directory whose name begins with '-'. The -d check alone accepts it,
# so only the option-injection guard can reject it.
mkdir -- "${sandbox}/--rsh=touch pwned"

echo "== validate_sync_args: accepted specs =="
assert_eq '0|alice@backup.example.com|backup.example.com' \
    "$(_split "$sandbox" 'alice@backup.example.com:/srv/share/')" "user@host:/path split"
assert_eq '0|backup.example.com|backup.example.com' \
    "$(_split "$sandbox" 'backup.example.com:/srv/share/')"       "host:/path split"
# The guard tests the first character only; a dash inside a name is ordinary.
assert_eq '0|my-user@my-host|my-host' \
    "$(_split "$sandbox" 'my-user@my-host:/srv/share/')"          "inner dashes accepted"
# ssh and rsync take the host after the LAST '@'.
assert_eq '0|a@b@c|c' \
    "$(_split "$sandbox" 'a@b@c:/p')"                              "host split at the last @, as ssh does"

echo "== validate_sync_args: remote option-injection guard =="
# No user part: ssh's destination argument is the dash-leading host itself.
assert_eq 1 "$(rc validate_sync_args "$sandbox" '-oProxyCommand=touch /tmp/pwned:/p')" \
    "dash-leading host rejected"
# Dash-leading user part: the host is a clean 'host', so a host-only guard
# misses it, yet ssh still receives '-oProxyCommand=x@host' as an option.
assert_eq 1 "$(rc validate_sync_args "$sandbox" '-oProxyCommand=x@host:/p')" \
    "dash-leading user rejected"
# Dash-leading host after a clean user: a bare host that begins with '-' is an
# ssh option wherever rsync's remote-shell command line places it.
assert_eq 1 "$(rc validate_sync_args "$sandbox" 'user@-oProxyCommand=x:/p')" \
    "dash-leading host after user@ rejected"
# A second '@': a first-'@' split leaves a clean-looking host, but ssh and
# rsync take the host after the last '@', and that token is an option.
assert_eq 1 "$(rc validate_sync_args "$sandbox" 'user@x@-oProxyCommand=y:/p')" \
    "dash-leading host after a second @ rejected"
assert_contains "$(_stderr validate_sync_args "$sandbox" '-oProxyCommand=x@host:/p')" \
    'option-injection guard' "remote rejection names the guard"

echo "== validate_sync_args: a host in [ ] is refused =="
# rsync takes everything inside [ ] as the host, '@' and ':' included, and then
# splits it at its last '@', so brackets can hide a dash-leading host from the
# script's own split at the first ':'. The script never supported a bracketed
# host, so every such spec is refused, harmless ones included.
assert_eq 1 "$(rc validate_sync_args "$sandbox" '[-oProxyCommand=x]:/p')" \
    "dash-leading host inside [ ] rejected"
assert_eq 1 "$(rc validate_sync_args "$sandbox" 'user@[-oProxyCommand=x]:/p')" \
    "dash-leading host inside [ ] after user@ rejected"
assert_eq 1 "$(rc validate_sync_args "$sandbox" '[a@b:c@-oProxyCommand=x]:/p')" \
    "dash-leading host hidden behind @ and : inside [ ] rejected"
assert_eq 1 "$(rc validate_sync_args "$sandbox" 'user@[a@b:c@-oProxyCommand=x]:/p')" \
    "the same shape after user@ rejected"
assert_eq 1 "$(rc validate_sync_args "$sandbox" 'a@b@[-oProxyCommand=x]:/p')" \
    "[ after a second @ rejected"
assert_eq 1 "$(rc validate_sync_args "$sandbox" '@[-oProxyCommand=x]:/p')" \
    "[ after an empty user rejected"
assert_eq 1 "$(rc validate_sync_args "$sandbox" '[::1]:/p')" \
    "a harmless bracketed host is refused too"
assert_contains "$(_stderr validate_sync_args "$sandbox" '[::1]:/p')" \
    'Refusing a remote host in [ ]' "bracket rejection names the guard"
# Brackets in the path are not a bracketed host.
assert_eq 0 "$(rc validate_sync_args "$sandbox" 'host:/srv/[x]')" \
    "brackets in the path accepted"
assert_eq 0 "$(rc validate_sync_args "$sandbox" 'user@host:/srv/a@[b]')" \
    "an @[ in the path accepted"

echo "== validate_sync_args: an rsync:// spec is refused =="
# The format check would read the scheme as the host ('rsync'), so the real host
# after '//' would never be checked. The script supports [user@]host:/path only.
assert_eq 1 "$(rc validate_sync_args "$sandbox" 'rsync://-oProxyCommand=x/mod')" \
    "rsync:// daemon spec rejected"
assert_contains "$(_stderr validate_sync_args "$sandbox" 'rsync://-oProxyCommand=x/mod')" \
    'Refusing an rsync:// daemon spec' "rsync:// rejection names the reason"

echo "== validate_sync_args: local option-injection guard =="
assert_eq 1 "$(cd "$sandbox" && rc validate_sync_args '--rsh=touch pwned' 'host:/p')" \
    "existing dash-leading local dir rejected"
assert_contains "$(cd "$sandbox" && _stderr validate_sync_args '--rsh=touch pwned' 'host:/p')" \
    'option-injection guard' "local rejection names the guard"
# The escape the error message offers must pass.
assert_eq 0 "$(cd "$sandbox" && rc validate_sync_args './--rsh=touch pwned' 'host:/p')" \
    "./-prefixed local dir accepted"

echo "== validate_sync_args: format error =="
assert_eq 1 "$(rc validate_sync_args "$sandbox" 'no-colon-here')" "missing colon rejected"
assert_contains "$(_stderr validate_sync_args "$sandbox" 'no-colon-here')" \
    'Invalid remote specification format: no-colon-here' "missing colon keeps its message"

echo "== validate_sync_args: missing local directory =="
assert_eq 1 "$(rc validate_sync_args "${sandbox}/absent" 'host:/p')" "missing local dir rejected"
assert_contains "$(_stderr validate_sync_args "${sandbox}/absent" 'host:/p')" \
    'Local directory does not exist' "missing local dir names the reason"
# This branch also logs. HOME points into the sandbox before the script is
# sourced, so the line lands there and never in the developer's real log.
assert_eq 'present' "$([[ -s "${sandbox}/.rsync-two-way.log" ]] && echo present || echo absent)" \
    "the missing-directory error is logged inside the sandbox"

echo "== deletions are not propagated =="
# A source-text pin: OPTS is local to main, and only a run against a second host
# could observe it. With --delete, Pass 1 (LOCAL -> REMOTE) deletes every file
# that exists only on the remote before Pass 2 can pull it.
assert_not_contains "$(<"${TESTS_DIR}/../rsync-two-way.sh")" '--delete' \
    "rsync-two-way.sh passes no --delete to rsync"

echo "== main calls validate_sync_args before ssh or rsync runs =="
# The one check that runs the script as a child process — a copy in the sandbox
# with its library beside it, because main() runs sweep_stale_temps and
# check_for_updates, which act on the script's own directory. SELF_UPDATE_RESTARTED=1
# takes check_for_updates' post-restart return, which fetches nothing; ssh and
# rsync are shims that record a marker file — so a marker means the refused spec
# reached a network command, and exit 1 with the guard's own message and no
# marker means validate_sync_args refused it first.
shim_dir="${sandbox}/shim"
mkdir "$shim_dir"
printf '#!/usr/bin/env bash\ntouch "%s/reached"\nexit 99\n' "$sandbox" > "${shim_dir}/ssh"
cp "${shim_dir}/ssh" "${shim_dir}/rsync"
chmod +x "${shim_dir}/ssh" "${shim_dir}/rsync"
run_dir="${sandbox}/run"
mkdir "$run_dir"
cp "${TESTS_DIR}/../rsync-two-way.sh" "${TESTS_DIR}/../utils-misc.sh" "${run_dir}/"
wire_rc=0
wire_out=$(PATH="${shim_dir}:${PATH}" SELF_UPDATE_RESTARTED=1 \
    "${run_dir}/rsync-two-way.sh" "$sandbox" '-oProxyCommand=x@host:/p' </dev/null 2>&1) || wire_rc=$?
assert_eq 1 "$wire_rc" "main exits 1 on a refused spec"
assert_contains "$wire_out" 'option-injection guard' \
    "main's refusal comes from validate_sync_args, not another usage error"
assert_eq 'absent' "$([[ -e "${sandbox}/reached" ]] && echo present || echo absent)" "neither ssh nor rsync ran"

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
