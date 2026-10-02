#!/usr/bin/env bash
# test-self-update.sh - Unit tests for the repo-wide self-update mechanism
#
# Zero dependencies: no network, no root, no test framework. Each library is
# copied into a throwaway directory beside a fake caller script and sourced in a
# child bash with a recording `curl` shim first on PATH (download_script's wget
# cases add a `wget` shim beside it), so nothing here touches the repository or
# the network. The curl shim serves the sandbox's own files, so "remote" equals
# "local" unless a case points it at the sandbox's remote/ copy.
#
# Usage: ./tests/test-self-update.sh
set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR
readonly REPO_DIR="${TESTS_DIR}/.."

TESTS_RUN=0
TESTS_FAILED=0

# Sandboxes are `mktemp -d` DIRECTORIES, which an `rm -f` loop cannot reap.
TEST_TEMP_DIRS=()
_test_cleanup() {
    local d
    for d in "${TEST_TEMP_DIRS[@]+"${TEST_TEMP_DIRS[@]}"}"; do
        rm -rf "$d"
    done
}
trap _test_cleanup EXIT

# assert_eq / assert_contains / assert_not_contains: one of four copies of the
# trio — utils/tests/test-rsync-over-tunnel.sh, utils/tests/test-rsync-two-way.sh
# and lxc/tests/test-protect-lxc.sh carry the other three. All four are
# development-only; change them together.
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

# The five parity copies, in the order AGENTS.md §Helper Library Duplication
# lists them. All share the SELF_UPDATE_RESTARTED guard.
readonly LIBRARIES=(
    system-setup/utils-sys.sh
    kubernetes/utils-k8s.sh
    lxc/utils-lxc.sh
    llm/utils-llm.sh
    utils/utils-misc.sh
)

# The three github/ standalones, which inline the roster helpers instead of
# sourcing a library.
readonly GH_STANDALONES=(github/gh_org_copy.sh github/gh_org_delete_issues.sh github/gh_org_delete_repos.sh)

# Build a sandbox for one library and leave its path in SANDBOX. Not a `$()`
# capture: the TEST_TEMP_DIRS+= must reach this shell, not a subshell.
#   <sandbox>/<lib>            copy of the library under test (its _UTILS_DIR)
#   <sandbox>/caller.sh        fake caller; prints the guard and args it got
#   <sandbox>/remote/          what the shim serves when SHIM_DIR points here:
#                              identical library, DIFFERENT caller
#   <sandbox>/bin/curl         recording shim
#   <sandbox>/shim.log         one line per shim call (the URL)
SANDBOX=""
SHIM_STATUS=200
make_sandbox() {
    local lib_rel="$1"
    SANDBOX=$(mktemp -d)
    TEST_TEMP_DIRS+=("$SANDBOX")
    SHIM_STATUS=200
    cp "${REPO_DIR}/${lib_rel}" "${SANDBOX}/"
    mkdir -p "${SANDBOX}/remote" "${SANDBOX}/bin"
    cp "${REPO_DIR}/${lib_rel}" "${SANDBOX}/remote/"
    # SELF_UPDATE_RESTARTED and $* are written verbatim INTO the fake callers,
    # which expand them when the library execs them; expanding them here would
    # bake this shell's values into the file. ARGS pins the `exec … "$@"`
    # forwarding: without it, dropping "$@" from the exec passes every test.
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\necho "RESTARTED_WITH=${SELF_UPDATE_RESTARTED:-unset} ARGS=$*"\n' > "${SANDBOX}/caller.sh"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\necho "RESTARTED_WITH=${SELF_UPDATE_RESTARTED:-unset} ARGS=$*"\necho REMOTE_COPY\n' > "${SANDBOX}/remote/caller.sh"
    chmod +x "${SANDBOX}/caller.sh" "${SANDBOX}/remote/caller.sh"
    cat > "${SANDBOX}/bin/curl" <<'SHIM'
#!/usr/bin/env bash
# Recording curl shim. Mimics `curl -H … --max-time 15 -o OUT -w '%{http_code}' -sSL URL`:
# copies ${SHIM_DIR}/<basename of URL> to OUT and prints ${SHIM_STATUS:-200}.
# Logs the URL. ${SHIM_CURL_EXIT} cuts a 200 transfer short (see below). A
# non-200 status writes nothing, which is what a real error page response looks
# like to download_script's rejection branches.
# detect_download_cmd prefers curl, so this shim wins on every host; the
# download_script section below forces DOWNLOAD_CMD=wget with a wget shim.
out="" url=""
while (($#)); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -H|-w|--max-time) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >> "${SHIM_LOG}"
status="${SHIM_STATUS:-200}"
# ${SHIM_CURL_EXIT}: a transfer cut short after the header. Real curl has
# already written -o's partial body and -w's status by then, and exits 18
# (partial file) or 28 (--max-time hit mid-body) — so print the status, leave
# a body whose first line is a shebang, and fail the way curl does.
curl_exit="${SHIM_CURL_EXIT:-0}"
if [[ "$curl_exit" != "0" ]]; then
    printf '#!/usr/bin/env bash\n# partial\n' > "$out"
    printf '%s' "$status"
    exit "$curl_exit"
fi
if [[ "$status" == "200" ]]; then
    cp "${SHIM_DIR}/$(basename "$url")" "$out"
fi
printf '%s' "$status"
SHIM
    chmod +x "${SANDBOX}/bin/curl"
    : > "${SANDBOX}/shim.log"
}

# Source the sandboxed library in a child bash and call check_for_updates on the
# fake caller. $1 library basename, $2 guard value ("" = unset), $3 directory the
# shim serves from, $4 "yes"/"no" stubs prompt_yes_no accordingly ("" = leave the
# real one, which declines without a TTY), $5 caller path (default
# <sandbox>/caller.sh). Prints the library's output, then a final
# "DOWNLOAD_CMD=<v> GUARD=<v>" line — replaced by the exec'd caller's output on
# the restart path, since exec never returns — and always a "CHILD_RC=<n>" line.
# CHILD_RC pins the preamble's "never returns non-zero" contract end to end.
invoke_check() {
    local lib_base="$1" guard_value="$2" shim_dir="$3" accept="${4:-}"
    local caller_path="${5:-${SANDBOX}/caller.sh}"
    local -a guard_env=()
    [[ -n "$guard_value" ]] && guard_env=("SELF_UPDATE_RESTARTED=${guard_value}")
    local out rc=0
    # The single-quoted script below is the CHILD's source text: $1..$4 are its
    # positional args and DOWNLOAD_CMD/SELF_UPDATE_RESTARTED are read after the
    # library sets them, so nothing in it may expand in this shell.
    # `trap - EXIT` disarms the library's file-scope cleanup trap (Layer 2 of
    # AGENTS.md §Defense-in-depth Cleanup). It would otherwise reap every temp
    # when this short-lived child exits, so the "no leftovers" assertions below
    # would pass even with Layer 1's per-branch `rm -f` deleted. Disarming it
    # leaves the sandbox's own `rm -rf` (this file's EXIT trap) as the net.
    # shellcheck disable=SC2016
    out=$(env "${guard_env[@]+"${guard_env[@]}"}" \
        PATH="${SANDBOX}/bin:${PATH}" SHIM_LOG="${SANDBOX}/shim.log" \
        SHIM_DIR="$shim_dir" SHIM_STATUS="$SHIM_STATUS" \
        bash -c 'source "$1/$2"
            trap - EXIT
            case "$3" in
                yes) prompt_yes_no() { return 0; } ;;
                no)  prompt_yes_no() { return 1; } ;;
            esac
            check_for_updates "$4" --sentinel
            printf "DOWNLOAD_CMD=%s GUARD=%s\n" "$DOWNLOAD_CMD" "${SELF_UPDATE_RESTARTED:-unset}"' \
        _ "$SANDBOX" "$lib_base" "$accept" "$caller_path" 2>&1) || rc=$?
    printf '%s\nCHILD_RC=%s\n' "$out" "$rc"
}

echo "== check_for_updates: consume the guard, detect before it returns =="
# Two measurements recur below and are written out each time rather than
# wrapped (AGENTS.md §No Simple Wrapper Functions):
#   shim calls  →  $(wc -l < "${SANDBOX}/shim.log" | tr -d ' ')
#   leftovers   →  $(find "$SANDBOX" -name '~*.tmp.??????' -type f | wc -l | tr -d ' ')
for lib_rel in "${LIBRARIES[@]}"; do
    lib_base="${lib_rel##*/}"

    # Restarted process: guard set → detection still runs, guard is consumed, no fetch.
    make_sandbox "$lib_rel"
    out=$(invoke_check "$lib_base" 1 "$SANDBOX")
    assert_contains "$out" 'DOWNLOAD_CMD=curl'      "${lib_rel}: restarted → DOWNLOAD_CMD populated"
    assert_contains "$out" 'GUARD=unset'            "${lib_rel}: restarted → guard consumed"
    assert_contains "$out" 'CHILD_RC=0'             "${lib_rel}: restarted → returns 0"
    assert_eq '0' "$(wc -l < "${SANDBOX}/shim.log" | tr -d ' ')" "${lib_rel}: restarted → no download attempted"

    # First run, everything already current: two fetches, no restart, no leftovers.
    make_sandbox "$lib_rel"
    out=$(invoke_check "$lib_base" "" "$SANDBOX")
    assert_contains "$out" 'DOWNLOAD_CMD=curl'      "${lib_rel}: up-to-date → DOWNLOAD_CMD populated"
    assert_contains "$out" 'CHILD_RC=0'             "${lib_rel}: up-to-date → returns 0"
    assert_eq '2' "$(wc -l < "${SANDBOX}/shim.log" | tr -d ' ')" "${lib_rel}: up-to-date → utils + caller fetched once each"
    assert_eq '2' "$(grep -c 'is up-to-date' <<<"$out")" "${lib_rel}: up-to-date → both reported current"
    assert_not_contains "$out" 'Restarting'         "${lib_rel}: up-to-date → no restart"
    assert_eq '0' "$(find "$SANDBOX" -name '~*.tmp.??????' -type f | wc -l | tr -d ' ')" "${lib_rel}: up-to-date → no ~*.tmp leftovers"
    # The caller is fetched by its path RELATIVE to _UTILS_DIR; an absolute one
    # would build ${REMOTE_BASE}//abs/path and 404 on every real run.
    assert_not_contains "$(cat "${SANDBOX}/shim.log")" "$SANDBOX" "${lib_rel}: up-to-date → caller fetched by repo-relative path"

    # First run, caller changed, user accepts: the exec'd caller sees the guard
    # and the forwarded arguments, and is installed executable.
    make_sandbox "$lib_rel"
    out=$(invoke_check "$lib_base" "" "${SANDBOX}/remote" yes)
    assert_contains "$out" 'RESTARTED_WITH=1'       "${lib_rel}: accept caller → exec'd caller sees SELF_UPDATE_RESTARTED=1"
    assert_contains "$out" 'ARGS=--sentinel'        "${lib_rel}: accept caller → exec forwards the original arguments"
    assert_contains "$out" 'REMOTE_COPY'            "${lib_rel}: accept caller → exec ran the NEW caller"
    assert_eq '2' "$(wc -l < "${SANDBOX}/shim.log" | tr -d ' ')" "${lib_rel}: accept caller → utils + caller fetched once each"
    assert_eq '0' "$(find "$SANDBOX" -name '~*.tmp.??????' -type f | wc -l | tr -d ' ')" "${lib_rel}: accept caller → no ~*.tmp leftovers"
    assert_eq '755' "$(stat -c %a "${SANDBOX}/caller.sh" 2>/dev/null || stat -f %OLp "${SANDBOX}/caller.sh")" "${lib_rel}: accept caller → installed 755, not a umask-relative +x"

    # First run, the LIBRARY changed and the caller did not: the branch that
    # produced the bug report this suite exists for. The library is replaced
    # (mode 644, never executable) and the caller is exec-restarted so the new
    # library is actually loaded.
    make_sandbox "$lib_rel"
    printf '\n# sandbox remote copy\n' >> "${SANDBOX}/remote/${lib_base}"
    cp "${SANDBOX}/caller.sh" "${SANDBOX}/remote/caller.sh"
    out=$(invoke_check "$lib_base" "" "${SANDBOX}/remote" yes)
    assert_contains "$out" "✓ Updated ${lib_base}"  "${lib_rel}: accept utils → library replaced"
    assert_contains "$out" 'RESTARTED_WITH=1'       "${lib_rel}: accept utils → restarts so the new library is loaded"
    assert_not_contains "$out" 'REMOTE_COPY'        "${lib_rel}: accept utils → the caller itself was not replaced"
    assert_eq 'same' "$(cmp -s "${SANDBOX}/${lib_base}" "${SANDBOX}/remote/${lib_base}" && echo same || echo differs)" "${lib_rel}: accept utils → installed copy is the remote one"
    assert_eq '644' "$(stat -c %a "${SANDBOX}/${lib_base}" 2>/dev/null || stat -f %OLp "${SANDBOX}/${lib_base}")" "${lib_rel}: accept utils → library installed 644, not +x"
    assert_eq '0' "$(find "$SANDBOX" -name '~*.tmp.??????' -type f | wc -l | tr -d ' ')" "${lib_rel}: accept utils → no ~*.tmp leftovers"
done

# Parity: the five bodies must hash identically (AGENTS.md §Helper Library
# Duplication). Same extraction as the roster audit — `check_for_updates() {`
# through the closing brace — so the first drift fails here instead of waiting
# for a manual audit. The extractor starts AT the `check_for_updates() {` line,
# exactly as the roster defines the method, so the preamble comment above it is
# deliberately outside the digest. `cksum` (POSIX) rather than `sha256sum`,
# which stock macOS does not ship: this asserts equality, not a fixed digest.
assert_eq '1' "$(for lib_rel in "${LIBRARIES[@]}"; do
        awk '/^check_for_updates\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "${REPO_DIR}/${lib_rel}" | cksum
    done | sort -u | wc -l | tr -d ' ')" 'check_for_updates: one digest across the five libraries'
# Same guard for the digest above: an empty extraction must not pass as parity.
assert_eq '' "$(for lib_rel in "${LIBRARIES[@]}"; do
        grep -qx 'check_for_updates() {' "${REPO_DIR}/${lib_rel}" || printf '%s ' "$lib_rel"
    done)" 'check_for_updates: defined in all five libraries'

echo "== check_for_updates: edge paths (one library — the digest above pins the other four identical) =="
readonly EDGE_LIB=system-setup/utils-sys.sh
readonly EDGE_BASE=utils-sys.sh

# User declines the caller update: no restart, nothing installed, no leftovers.
make_sandbox "$EDGE_LIB"
out=$(invoke_check "$EDGE_BASE" "" "${SANDBOX}/remote" no)
assert_contains "$out" "Skipped caller.sh"          "decline → reports the skip"
assert_not_contains "$out" 'Restarting'             "decline → no restart"
assert_contains "$out" 'CHILD_RC=0'                 "decline → returns 0"
assert_eq '0' "$(grep -c 'REMOTE_COPY' "${SANDBOX}/caller.sh" || true)" "decline → local caller untouched"
assert_eq '0' "$(find "$SANDBOX" -name '~*.tmp.??????' -type f | wc -l | tr -d ' ')" "decline → no ~*.tmp leftovers"

# Nested caller (system-modules/… and kubernetes-modules/… are 25 of the ~45
# real callers): the fetch must use the nested path and the temp must land
# beside the caller, not beside the library.
make_sandbox "$EDGE_LIB"
mkdir -p "${SANDBOX}/system-modules"
cp "${SANDBOX}/caller.sh" "${SANDBOX}/system-modules/caller.sh"
out=$(invoke_check "$EDGE_BASE" "" "$SANDBOX" "" "${SANDBOX}/system-modules/caller.sh")
assert_contains "$(cat "${SANDBOX}/shim.log")" '/system-modules/caller.sh' "nested caller → fetched by its nested relative path"
assert_contains "$out" 'CHILD_RC=0'                 "nested caller → returns 0"
assert_eq '0' "$(find "$SANDBOX" -name '~*.tmp.??????' -type f | wc -l | tr -d ' ')" "nested caller → no ~*.tmp leftovers"

# Caller outside _UTILS_DIR: its relative path cannot be derived, so the check
# is skipped instead of fetching ${REMOTE_BASE}//abs/path on every run.
make_sandbox "$EDGE_LIB"
OUTSIDE_DIR=$(mktemp -d)
TEST_TEMP_DIRS+=("$OUTSIDE_DIR")
cp "${SANDBOX}/caller.sh" "${OUTSIDE_DIR}/caller.sh"
out=$(invoke_check "$EDGE_BASE" "" "$SANDBOX" "" "${OUTSIDE_DIR}/caller.sh")
assert_contains "$out" 'is outside'                 "caller outside _UTILS_DIR → reported and skipped"
assert_contains "$out" 'CHILD_RC=0'                 "caller outside _UTILS_DIR → returns 0"
assert_eq '1' "$(wc -l < "${SANDBOX}/shim.log" | tr -d ' ')" "caller outside _UTILS_DIR → only the library is fetched"

# Rate limited (HTTP 429): both checks fail, the run continues, and no temp is
# left behind for the next run's sweep to prompt about.
make_sandbox "$EDGE_LIB"
SHIM_STATUS=429
out=$(invoke_check "$EDGE_BASE" "" "$SANDBOX")
SHIM_STATUS=200
assert_contains "$out" 'Rate limited'               "HTTP 429 → reported"
assert_contains "$out" 'DOWNLOAD_CMD=curl'          "HTTP 429 → DOWNLOAD_CMD still populated"
assert_contains "$out" 'CHILD_RC=0'                 "HTTP 429 → returns 0"
assert_not_contains "$out" 'Restarting'             "HTTP 429 → no restart"
assert_eq '0' "$(find "$SANDBOX" -name '~*.tmp.??????' -type f | wc -l | tr -d ' ')" "HTTP 429 → no ~*.tmp leftovers"

# Unwritable directories. `mktemp` fails there, and a bare assignment would
# abort the caller under `set -e` — the one thing this function must never do.
# Root ignores the mode bits, so the cases would pass vacuously under sudo.
if [[ $EUID -eq 0 ]]; then
    echo "  skip running as root: unwritable-directory cases"
else
    # Library directory unwritable → warn, skip the whole check, return 0.
    make_sandbox "$EDGE_LIB"
    chmod 555 "$SANDBOX"
    out=$(invoke_check "$EDGE_BASE" "" "$SANDBOX")
    chmod 755 "$SANDBOX"
    assert_contains "$out" 'Cannot create a temp file in' "unwritable library dir → reported"
    assert_contains "$out" 'CHILD_RC=0'                   "unwritable library dir → returns 0, does not abort the caller"
    assert_eq '0' "$(wc -l < "${SANDBOX}/shim.log" | tr -d ' ')" "unwritable library dir → nothing fetched"

    # Only the CALLER's directory unwritable → its half is skipped, but a
    # library update accepted first still earns the restart.
    make_sandbox "$EDGE_LIB"
    printf '\n# sandbox remote copy\n' >> "${SANDBOX}/remote/${EDGE_BASE}"
    mkdir -p "${SANDBOX}/system-modules"
    cp "${SANDBOX}/caller.sh" "${SANDBOX}/system-modules/caller.sh"
    chmod 555 "${SANDBOX}/system-modules"
    out=$(invoke_check "$EDGE_BASE" "" "${SANDBOX}/remote" yes "${SANDBOX}/system-modules/caller.sh")
    chmod 755 "${SANDBOX}/system-modules"
    assert_contains "$out" 'Cannot create a temp file next to' "unwritable caller dir → reported"
    assert_contains "$out" 'RESTARTED_WITH=1'                  "unwritable caller dir → the accepted library update still restarts"
    assert_eq '1' "$(wc -l < "${SANDBOX}/shim.log" | tr -d ' ')" "unwritable caller dir → only the library is fetched"
fi

echo "== download_script: wget exit codes (one library — the digest below pins the other seven identical) =="
# detect_download_cmd prefers curl, so every case above runs the curl branch.
# These force DOWNLOAD_CMD=wget after sourcing and put a `wget` shim first on
# PATH that exits with ${WGET_SHIM_EXIT}. On failure the shim leaves a partial
# body in the -O file, as real wget can: `-O file` truncates the file
# immediately (wget(1), --output-document), so it exists whatever happens next.
# Each failing case pins the exact message, the return status, and that the
# body was removed. Exit 1 pins the fallthrough arm, exit 0 the success path.
_wget_download() {   # $1 = exit code the shim returns → output, "DOWNLOAD_RC=<n>" and "CHILD_RC=<n>" lines
    local rc=0 out
    # shellcheck disable=SC2016  # the single-quoted script is the CHILD's source text
    out=$(env PATH="${SANDBOX}/bin:${PATH}" SHIM_DIR="$SANDBOX" WGET_SHIM_EXIT="$1" \
        bash -c 'source "$1/$2"
            trap - EXIT
            DOWNLOAD_CMD=wget
            rc=0
            download_script caller.sh "$1/download.out" || rc=$?
            printf "DOWNLOAD_RC=%s\n" "$rc"' \
        _ "$SANDBOX" "$EDGE_BASE" 2>&1) || rc=$?
    printf '%s\nCHILD_RC=%s\n' "$out" "$rc"
}
make_sandbox "$EDGE_LIB"
cat > "${SANDBOX}/bin/wget" <<'SHIM'
#!/usr/bin/env bash
# wget shim. Mimics `wget --no-cache --no-cookies --timeout=15 -O OUT -q URL`:
# exit 0 copies ${SHIM_DIR}/<basename of URL> to OUT; any other
# ${WGET_SHIM_EXIT} writes a partial body to OUT, then exits with that code.
out="" url=""
while (($#)); do
    case "$1" in
        -O) out="$2"; shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
code="${WGET_SHIM_EXIT:-0}"
if [[ "$code" == "0" ]]; then
    cp "${SHIM_DIR}/$(basename "$url")" "$out"
else
    printf '<html>partial\n' > "$out"
fi
exit "$code"
SHIM
chmod +x "${SANDBOX}/bin/wget"
for case_spec in \
        '4|✖ Network/SSL error (wget exit 4)' \
        '5|✖ Network/SSL error (wget exit 5)' \
        '6|✖ Authentication failed (wget exit 6)' \
        '8|✖ Server error (HTTP 4xx/5xx) — check the URL above' \
        '1|✖ Download failed (wget exit 1)'; do
    code="${case_spec%%|*}"
    message="${case_spec#*|}"
    rm -f "${SANDBOX}/download.out"
    out=$(_wget_download "$code")
    assert_contains "$out" "$message"      "wget exit ${code} → \"${message}\""
    assert_contains "$out" 'DOWNLOAD_RC=1' "wget exit ${code} → download_script returns 1"
    assert_contains "$out" 'CHILD_RC=0'    "wget exit ${code} → the caller keeps running"
    assert_eq 'absent' "$([[ -e "${SANDBOX}/download.out" ]] && echo present || echo absent)" "wget exit ${code} → partial body removed"
done
rm -f "${SANDBOX}/download.out"
out=$(_wget_download 0)
assert_contains "$out" 'DOWNLOAD_RC=0'     "wget exit 0 → download_script returns 0"
assert_not_contains "$out" '✖'             "wget exit 0 → no error printed"
assert_eq 'same' "$(cmp -s "${SANDBOX}/download.out" "${SANDBOX}/caller.sh" && echo same || echo differs)" "wget exit 0 → the fetched file is kept"
# The content gate after a clean wget exit: the shim serves SANDBOX/caller.sh.
printf '<html>\n<code>#!/bin/sh</code>\n</html>\n' > "${SANDBOX}/caller.sh"
rm -f "${SANDBOX}/download.out"
out=$(_wget_download 0)
assert_contains "$out" '✖ Invalid content (no shebang on line 1)' "wget exit 0, no shebang on line 1 → rejected"
assert_contains "$out" 'DOWNLOAD_RC=1' "wget exit 0, no shebang → download_script returns 1"
assert_eq 'absent' "$([[ -e "${SANDBOX}/download.out" ]] && echo present || echo absent)" "wget exit 0, no shebang → body removed"
printf '#!/usr/bin/env bash\r\necho hi\n' > "${SANDBOX}/caller.sh"
rm -f "${SANDBOX}/download.out"
out=$(_wget_download 0)
assert_contains "$out" '✖ Invalid content (CRLF line endings)' "wget exit 0, CRLF shebang → rejected"
assert_contains "$out" 'DOWNLOAD_RC=1' "wget exit 0, CRLF shebang → download_script returns 1"
assert_eq 'absent' "$([[ -e "${SANDBOX}/download.out" ]] && echo present || echo absent)" "wget exit 0, CRLF shebang → body removed"

echo "== download_script: curl exit status (a body cut short after its 200 header) =="
# curl knows %{http_code} once the header arrives, so a transfer that dies
# mid-body still reports 200 (exit 18, or 28 on the --max-time timeout) and the
# partial file, whose first line is a shebang, would pass the content gate.
# download_script must test curl's exit before the status case.
_curl_download() {   # $1 = curl exit code the shim returns → output, "DOWNLOAD_RC=<n>" and "CHILD_RC=<n>" lines
    local rc=0 out
    # shellcheck disable=SC2016  # the single-quoted script is the CHILD's source text
    out=$(env PATH="${SANDBOX}/bin:${PATH}" SHIM_DIR="$SANDBOX" SHIM_LOG="${SANDBOX}/shim.log" SHIM_CURL_EXIT="$1" \
        bash -c 'source "$1/$2"
            trap - EXIT
            DOWNLOAD_CMD=curl
            rc=0
            download_script caller.sh "$1/download.out" || rc=$?
            printf "DOWNLOAD_RC=%s\n" "$rc"' \
        _ "$SANDBOX" "$EDGE_BASE" 2>&1) || rc=$?
    printf '%s\nCHILD_RC=%s\n' "$out" "$rc"
}
make_sandbox "$EDGE_LIB"
for code in 18 28; do
    rm -f "${SANDBOX}/download.out"
    out=$(_curl_download "$code")
    assert_contains "$out" "✖ Download failed (curl exit ${code})" "curl exit ${code} after a 200 header → reported"
    assert_contains "$out" 'DOWNLOAD_RC=1' "curl exit ${code} → download_script returns 1"
    assert_contains "$out" 'CHILD_RC=0'    "curl exit ${code} → the caller keeps running"
    assert_eq 'absent' "$([[ -e "${SANDBOX}/download.out" ]] && echo present || echo absent)" "curl exit ${code} → partial body removed"
done

# Parity: the eight bodies must hash identically (AGENTS.md §Helper Library
# Duplication) — same extraction as the check_for_updates digest above, over the
# five libraries and the three github/ standalones that inline their own copy.
assert_eq '1' "$(for script_rel in "${LIBRARIES[@]}" "${GH_STANDALONES[@]}"; do
        awk '/^download_script\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "${REPO_DIR}/${script_rel}" | cksum
    done | sort -u | wc -l | tr -d ' ')" 'download_script: one digest across the five libraries and the three github standalones'
# A digest of nothing is still one digest: every copy must define the function
# at column 0, or the parity above compares empty extractions.
assert_eq '' "$(for script_rel in "${LIBRARIES[@]}" "${GH_STANDALONES[@]}"; do
        grep -qx 'download_script() {' "${REPO_DIR}/${script_rel}" || printf '%s ' "$script_rel"
    done)" 'download_script: defined in all five libraries and the three github standalones'

echo "== kubernetes-setup.sh: flags parsed before the update check =="
# Source the orchestrator (its BASH_SOURCE guard keeps main() from running) and
# stub every side effect with a marker so each flag's path is observable:
# check_privileges returning 1 stops main at the root check even when the suite
# runs as root; print_error's 2s pause only fires on a TTY, and stderr is
# captured here.
# The check_for_updates stub echoes the arguments it was handed AFTER the caller
# path ("${*:2}"), because forwarding them is the whole point of main()'s
# original_args copy — the parse loop consumes $@ before the call.
_k8s_main() {   # "$@" = flags, possibly none → "<rc>|<output>"
    local rc=0 out
    out=$(bash -c 'source "$1"
            check_for_updates() { echo "CHECK_FOR_UPDATES args=${*:2}"; DOWNLOAD_CMD=curl; }
            update_modules() { echo UPDATE_MODULES; return "${UPDATE_RC:-0}"; }
            cleanup_obsolete_scripts() { :; }
            check_privileges() { return 1; }
            sweep_stale_temps() { echo SWEEP; }
            detect_os() { DETECTED_OS=linux; }
            detect_container() { RUNNING_IN_CONTAINER=false; }
            if [[ -n "${FAKE_MISSING:-}" ]]; then get_script_list() { echo "kubernetes-modules/nope.sh"; }; fi
            main "${@:2}"' _ "${REPO_DIR}/kubernetes/kubernetes-setup.sh" "$@" 2>&1) || rc=$?
    printf '%s|%s' "$rc" "$out"
}
res=$(_k8s_main --help)
assert_eq '0' "${res%%|*}"                              "kubernetes-setup.sh --help exits 0"
assert_contains "${res#*|}" 'Usage:'                     "kubernetes-setup.sh --help prints usage"
assert_contains "${res#*|}" '--skip-update'              "kubernetes-setup.sh --help lists --skip-update"
assert_not_contains "${res#*|}" 'SWEEP'                  "kubernetes-setup.sh --help answers before the stale-temp sweep can prompt"
res=$(_k8s_main --bogus)
assert_eq '1' "${res%%|*}"                              "kubernetes-setup.sh --bogus exits 1"
assert_contains "${res#*|}" 'Unknown option: --bogus'    "kubernetes-setup.sh --bogus is rejected"
assert_not_contains "${res#*|}" 'SWEEP'                  "kubernetes-setup.sh --bogus rejects before the stale-temp sweep"
res=$(_k8s_main --skip-update)
assert_contains "${res#*|}" 'SWEEP'                      "kubernetes-setup.sh --skip-update still sweeps stale temps"
assert_not_contains "${res#*|}" 'CHECK_FOR_UPDATES'      "kubernetes-setup.sh --skip-update skips the self-check"
assert_not_contains "${res#*|}" 'UPDATE_MODULES'         "kubernetes-setup.sh --skip-update skips module updates"
assert_contains "${res#*|}" 'Kubernetes Setup and Configuration Script' "kubernetes-setup.sh --skip-update reaches the banner"
res=$(_k8s_main --debug)
assert_contains "${res#*|}" 'DEBUG MODE ENABLED'         "kubernetes-setup.sh --debug enables debug output"
assert_contains "${res#*|}" 'CHECK_FOR_UPDATES'          "kubernetes-setup.sh --debug still runs the self-check"
assert_contains "${res#*|}" 'UPDATE_MODULES'             "kubernetes-setup.sh --debug still runs module updates"
assert_contains "${res#*|}" 'CHECK_FOR_UPDATES args=--debug' "kubernetes-setup.sh --debug survives to the exec restart (original_args)"
res=$(_k8s_main)
assert_contains "${res#*|}" 'CHECK_FOR_UPDATES args='    "kubernetes-setup.sh with no flags still runs the self-check"
assert_contains "${res#*|}" 'UPDATE_MODULES'             "kubernetes-setup.sh with no flags runs module updates"
assert_contains "${res#*|}" 'Kubernetes Setup and Configuration Script' "kubernetes-setup.sh with no flags reaches the banner"
# Confinement: the stubbed privilege check is the only thing between this suite
# and a real cluster setup, so assert the run actually stopped there.
assert_contains "${res#*|}" 'requires root privileges'   "kubernetes-setup.sh stops at the privilege check (test confinement)"
# A partial module failure is reported, not fatal — update_modules returns 1.
res=$(UPDATE_RC=1 _k8s_main)
assert_contains "${res#*|}" 'UPDATE_MODULES'             "kubernetes-setup.sh tolerates a partial module failure: update ran"
assert_contains "${res#*|}" 'Kubernetes Setup and Configuration Script' "kubernetes-setup.sh tolerates a partial module failure: reaches the banner"
# …but a module that is missing altogether is named, not left to bash's raw
# "No such file or directory" at the unguarded `source` further down.
res=$(FAKE_MISSING=1 _k8s_main)
assert_eq '1' "${res%%|*}"                               "kubernetes-setup.sh missing module → exits 1"
assert_contains "${res#*|}" 'Missing module(s)'          "kubernetes-setup.sh missing module → typed error"
assert_contains "${res#*|}" 'kubernetes-modules/nope.sh' "kubernetes-setup.sh missing module → names the file"
# --skip-update is exactly when the gap survives: no download ran to fill it.
res=$(FAKE_MISSING=1 _k8s_main --skip-update)
assert_contains "${res#*|}" 'Missing module(s)'          "kubernetes-setup.sh missing module → caught under --skip-update too"

echo "== system-setup.sh: same orchestrator contract =="
# Same stub set. detect_os returning "unknown" is this orchestrator's own early
# exit, so the run stops immediately after the banner instead of sourcing a
# dozen modules and configuring the developer's machine.
_sys_main() {   # "$@" = flags, possibly none → "<rc>|<output>"
    local rc=0 out
    out=$(bash -c 'source "$1"
            check_for_updates() { echo "CHECK_FOR_UPDATES args=${*:2}"; DOWNLOAD_CMD=curl; }
            update_modules() { echo UPDATE_MODULES; return "${UPDATE_RC:-0}"; }
            cleanup_obsolete_scripts() { :; }
            sweep_stale_temps() { echo SWEEP; }
            detect_os() { DETECTED_OS=unknown; }
            if [[ -n "${FAKE_MISSING:-}" ]]; then get_script_list() { echo "system-modules/nope.sh"; }; fi
            main "${@:2}"' _ "${REPO_DIR}/system-setup/system-setup.sh" "$@" 2>&1) || rc=$?
    printf '%s|%s' "$rc" "$out"
}
res=$(_sys_main --help)
assert_eq '0' "${res%%|*}"                              "system-setup.sh --help exits 0"
assert_contains "${res#*|}" 'Usage:'                     "system-setup.sh --help prints usage"
assert_not_contains "${res#*|}" 'SWEEP'                  "system-setup.sh --help answers before the stale-temp sweep can prompt"
res=$(_sys_main --bogus)
assert_eq '1' "${res%%|*}"                              "system-setup.sh --bogus exits 1"
assert_contains "${res#*|}" 'Unknown option: --bogus'    "system-setup.sh --bogus is rejected"
assert_not_contains "${res#*|}" 'SWEEP'                  "system-setup.sh --bogus rejects before the stale-temp sweep"
res=$(_sys_main --skip-update)
assert_contains "${res#*|}" 'SWEEP'                      "system-setup.sh --skip-update still sweeps stale temps"
assert_not_contains "${res#*|}" 'CHECK_FOR_UPDATES'      "system-setup.sh --skip-update skips the self-check"
assert_not_contains "${res#*|}" 'UPDATE_MODULES'         "system-setup.sh --skip-update skips module updates"
assert_contains "${res#*|}" 'System Setup and Configuration Script' "system-setup.sh --skip-update reaches the banner"
res=$(_sys_main --debug)
assert_contains "${res#*|}" 'DEBUG MODE ENABLED'         "system-setup.sh --debug enables debug output"
assert_contains "${res#*|}" 'CHECK_FOR_UPDATES args=--debug' "system-setup.sh --debug survives to the exec restart (original_args)"
assert_contains "${res#*|}" 'UPDATE_MODULES'             "system-setup.sh --debug still runs module updates"
res=$(_sys_main)
assert_contains "${res#*|}" 'CHECK_FOR_UPDATES args='    "system-setup.sh with no flags still runs the self-check"
assert_contains "${res#*|}" 'UPDATE_MODULES'             "system-setup.sh with no flags runs module updates"
assert_contains "${res#*|}" 'Unknown operating system'   "system-setup.sh stops at the OS check (test confinement)"
res=$(UPDATE_RC=1 _sys_main)
assert_contains "${res#*|}" 'System Setup and Configuration Script' "system-setup.sh tolerates a partial module failure: reaches the banner"
res=$(FAKE_MISSING=1 _sys_main)
assert_eq '1' "${res%%|*}"                              "system-setup.sh missing module → exits 1"
assert_contains "${res#*|}" 'Missing module(s)'         "system-setup.sh missing module → typed error"
assert_contains "${res#*|}" 'system-modules/nope.sh'    "system-setup.sh missing module → names the file"
res=$(FAKE_MISSING=1 _sys_main --skip-update)
assert_contains "${res#*|}" 'Missing module(s)'         "system-setup.sh missing module → caught under --skip-update too"

echo "== _download-*-scripts.sh: cleanup runs and partial failure is the exit status =="
readonly DOWNLOADERS=(lxc/_download-lxc-scripts.sh llm/_download-ollama-scripts.sh utils/_download-utils-scripts.sh)
# Sourced bare, like the orchestrators above: each downloader ends in the if-form
# execution guard, which returns 0 when sourced. `|| true` here would suspend the
# file's own set -e for its whole body and hide a guard that returns 1. The
# DOWNLOAD_CMD the stubbed check leaves behind is captured into dl_cmd first,
# because inside the stub `$2` would be the stub's own (empty) argument.
_dl_main() {   # $1 = downloader (repo-relative), $2 = DOWNLOAD_CMD after the stubbed check → "<rc>|<output>"
    local rc=0 out
    out=$(bash -c 'source "$1"
            dl_cmd="$2"
            sweep_stale_temps() { :; }
            check_for_updates() { DOWNLOAD_CMD="$dl_cmd"; }
            update_modules() { echo UPDATE_MODULES; return 1; }
            cleanup_obsolete_scripts() { echo CLEANUP; }
            main' _ "${REPO_DIR}/$1" "$2" 2>&1) || rc=$?
    printf '%s|%s' "$rc" "$out"
}
for dl in "${DOWNLOADERS[@]}"; do
    res=$(_dl_main "$dl" curl)
    assert_contains "${res#*|}" 'UPDATE_MODULES' "${dl}: module update runs"
    assert_contains "${res#*|}" 'CLEANUP'        "${dl}: obsolete cleanup runs despite a failed module"
    assert_eq '1' "${res%%|*}"                   "${dl}: partial failure is exit status 1"
    res=$(_dl_main "$dl" "")
    assert_eq '0' "${res%%|*}"                   "${dl}: no download tool → exit 0"
    assert_not_contains "${res#*|}" 'CLEANUP'    "${dl}: no download tool → nothing runs"
done

echo "== lxc/, llm/, utils/: a missing library is named, not a raw source error =="
# A script copied or curled on its own arrives without its directory's library,
# and a bare `source` of a missing file dies with bash's raw "No such file or
# directory". The existence check above each `source` exits 69 (EX_UNAVAILABLE)
# instead, naming the library and the directory's updater. One script per suite
# is copied ALONE into an empty sandbox and run. Then the library is copied in
# and the script is SOURCED, not run: its execution guard keeps main() out, so
# no check_for_updates fetch, `screen` launch or container operation is reached,
# and the library's check_for_updates must be defined afterwards — the check
# lets a complete directory through without a sound. TRACE=0 because a
# `TRACE=1 ./tests/test-self-update.sh` run exports TRACE, and the utils/
# scripts honour it with xtrace lines on stderr.
readonly LIBRARY_GUARD_CASES=(   # "<script> <library> <updater>"
    "lxc/protect-lxc.sh utils-lxc.sh _download-lxc-scripts.sh"
    "llm/ollama-remote.sh utils-llm.sh _download-ollama-scripts.sh"
    "utils/dig-all.sh utils-misc.sh _download-utils-scripts.sh"
)
for guard_case in "${LIBRARY_GUARD_CASES[@]}"; do
    read -r script_rel guard_lib updater <<<"$guard_case"
    script_base="${script_rel##*/}"
    guard_dir=$(mktemp -d)
    TEST_TEMP_DIRS+=("$guard_dir")
    # The message prints the directory as the script's own `cd … && pwd`
    # resolves it, which can differ from mktemp's spelling of the same path.
    guard_dir_resolved=$(cd "$guard_dir" && pwd)
    cp "${REPO_DIR}/${script_rel}" "${guard_dir}/"

    rc=0
    out=$(TRACE=0 bash "${guard_dir}/${script_base}" 2>"${guard_dir}/stderr") || rc=$?
    err=$(<"${guard_dir}/stderr")
    assert_eq '69' "$rc"                "${script_rel}: library missing → exit 69 (EX_UNAVAILABLE)"
    assert_eq '' "$out"                 "${script_rel}: library missing → nothing on stdout"
    assert_eq "${guard_lib} not found in ${guard_dir_resolved}: download it and ${updater} there, then run ./${updater}" "$err" \
        "${script_rel}: library missing → stderr names the library, its directory and the updater, and nothing else"

    cp "${REPO_DIR}/${script_rel%/*}/${guard_lib}" "${guard_dir}/"
    rc=0
    out=$(TRACE=0 bash -c 'source "$1"
            declare -F check_for_updates >/dev/null && echo LIBRARY_LOADED' _ "${guard_dir}/${script_base}" 2>&1) || rc=$?
    assert_eq '0' "$rc"                 "${script_rel}: library present → sources cleanly"
    assert_eq 'LIBRARY_LOADED' "$out"   "${script_rel}: library present → the check is silent and the library loads"
done

# Static pin, every file — the "identical block in every script" rule as an
# assertion, the role the check_for_updates digest above plays for the libraries:
# each lxc/, llm/, utils/ script that sources its directory's library carries
# the four-line check verbatim, directly above its `source` directive and line
# (a check pasted below the `source` would be useless: the missing library dies
# first), naming that library and that directory's updater, so no copy can
# drift and a new script that sources its library in the templates' form
# (`source "${SCRIPT_DIR}/utils-<dir>.sh"`) cannot ship without it; a source
# line spelled any other way is not matched and goes unchecked. The updater
# name is read from the directory, not repeated here.
guard_offenders=""
for f in "${REPO_DIR}"/lxc/*.sh "${REPO_DIR}"/llm/*.sh "${REPO_DIR}"/utils/*.sh; do
    # shellcheck disable=SC2016  # ${SCRIPT_DIR} is literal source text being matched
    guard_lib=$(sed -n 's|^source "${SCRIPT_DIR}/\(utils-[a-z]*\.sh\)"$|\1|p' "$f")
    [[ -n "$guard_lib" ]] || continue
    suite_updaters=("${f%/*}"/_download-*-scripts.sh)
    updater="${suite_updaters[0]##*/}"
    expected=$(printf '%s\n' \
        "if [[ ! -f \"\${SCRIPT_DIR}/${guard_lib}\" ]]; then" \
        "    printf '${guard_lib} not found in %s: download it and ${updater} there, then run ./${updater}\\n' \"\${SCRIPT_DIR}\" >&2" \
        '    exit 69' \
        'fi' \
        "# shellcheck source=${guard_lib}" \
        "source \"\${SCRIPT_DIR}/${guard_lib}\"")
    actual=$(grep -xF -A5 "if [[ ! -f \"\${SCRIPT_DIR}/${guard_lib}\" ]]; then" "$f" || true)
    [[ "$actual" == "$expected" ]] || guard_offenders+="${f#"${REPO_DIR}"/} "
done
assert_eq '' "$guard_offenders" 'every lxc/, llm/, utils/ script that sources its library carries the identical existence check'

echo "== github/gh_org_*.sh: the same restart guard, string-tested and consumed =="
# The github standalones inline their own self_update rather than sourcing a
# library, so nothing above reaches them. They nonetheless use the SAME literal
# as the five libraries: one name for one meaning ("the process that exec'd me
# had already replaced a file"), which is only safe because every holder
# consumes it. Static pins: the guard is spelled the same at all three sites and
# matches the libraries', is compared as a STRING (an arithmetic `-eq` test
# evaluates the environment value as an expression, so a `$(…)` smuggled into it
# would run), is consumed after the update block, and no retired name survives.
for gh in "${GH_STANDALONES[@]}"; do
    assert_eq '1' "$(grep -c 'export SELF_UPDATE_RESTARTED=1' "${REPO_DIR}/${gh}" || true)"        "${gh}: exports the shared guard before the exec"
    # shellcheck disable=SC2016  # the single quotes are deliberate: this is the
    # literal source text being searched for, not an expansion.
    assert_eq '1' "$(grep -c -- '-z "${SELF_UPDATE_RESTARTED:-}"' "${REPO_DIR}/${gh}" || true)"    "${gh}: tests the guard as a string, not with -eq"
    assert_eq '1' "$(grep -c '^    unset SELF_UPDATE_RESTARTED$' "${REPO_DIR}/${gh}" || true)"     "${gh}: consumes the guard after the update block"
    assert_eq '0' "$(grep -cE 'scriptUpdated|GH_SCRIPTS_UPDATED' "${REPO_DIR}/${gh}" || true)"     "${gh}: no retired guard name survives"
done
# One literal across the distributed code: the libraries and the standalones
# must not drift apart. The tests/ directories are excluded because they name
# the retired identifiers on purpose — in this very assertion.
assert_eq '0' "$(grep -rlE 'scriptUpdated|GH_SCRIPTS_UPDATED|(SYS|K8S|LXC|LLM|UTILS)_SCRIPTS_UPDATED' --include='*.sh' --exclude-dir=tests --exclude-dir=.claude "${REPO_DIR}" | wc -l | tr -d ' ')" 'no retired guard name survives in distributed *.sh'

echo "== execution guard: no distributed script ends in the && form =="
# AGENTS.md §Important Implementation Notes #1. `[[ … ]] && main "$@"` is a false
# list when its file is sourced, so the file returns 1 and a sourcing shell under
# `set -e` exits; the if form returns 0, which is what lets the sections above
# source a script bare. The pattern is the guard's test followed by &&, whatever
# comes after it (main, main_<name>, a brace group) and however the operands are
# spelled; the three tests/ directories are excluded because they are
# development-only and never distributed.
guard_rc=0
guard_offenders=$(git -C "$REPO_DIR" grep -lE 'BASH_SOURCE.*\]\][[:space:]]*&&' -- '*.sh' ':!tests/*' ':!*/tests/*') || guard_rc=$?
# git grep exits 1 when nothing matches (the passing case) and above 1 when it cannot run.
if [[ "$guard_rc" -gt 1 ]]; then
    printf '  FAIL execution guard: git grep exited %d (not a git checkout?)\n' "$guard_rc"
    ((TESTS_RUN++)) || true
    ((TESTS_FAILED++)) || true
else
    assert_eq '' "${guard_offenders//$'\n'/ }" 'no distributed *.sh ends in the &&-form execution guard'
fi

echo "== executable bits: launchers are 100755 in the index, sourced files 100644 =="
# Every tracked *.sh is launched as a program — `./x.sh` by a user, or
# `exec "$caller_abs"` by check_for_updates — except the five named below, so
# git must record it as 100755: on a clone, `./script.sh` otherwise fails with
# `Permission denied` (126), and a library-only self-update dies at the exec
# AFTER the library has already been replaced. Reads the INDEX
# (`git ls-files -s`), not the working tree, so a stray local chmod cannot mask
# a wrong commit. The allowlist is the record of what is deliberately not
# executable, and it is asserted BOTH ways — an allowlisted file must be
# 100644, everything else 100755 — so a launcher that drifts to 644 and a
# library that drifts to 755 both fail, with the offending "<mode> <path>"
# printed. A new sourced library goes here; a new launcher needs nothing:
#   the five utils-*.sh libraries   sourced, never launched; check_for_updates
#                                   installs them with `chmod 644` on purpose
if ! mode_offenders=$(git -C "$REPO_DIR" ls-files -s -- '*.sh' \
        | awk 'BEGIN { a["system-setup/utils-sys.sh"] = 1; a["kubernetes/utils-k8s.sh"] = 1
                       a["lxc/utils-lxc.sh"] = 1; a["llm/utils-llm.sh"] = 1; a["utils/utils-misc.sh"] = 1 }
               $1 != (($4 in a) ? "100644" : "100755") { print $1, $4 }' \
        | tr '\n' ' '); then
    printf '  FAIL executable bits: git ls-files failed (not a git checkout?)\n'
    ((TESTS_RUN++)) || true
    ((TESTS_FAILED++)) || true
else
    assert_eq '' "$mode_offenders" 'every tracked *.sh has its intended index mode: 100755, or 100644 for the five libraries'
fi

echo ""
echo "${TESTS_RUN} assertions, ${TESTS_FAILED} failed"
[[ "$TESTS_FAILED" -eq 0 ]]
