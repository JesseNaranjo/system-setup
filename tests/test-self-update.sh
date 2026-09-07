#!/usr/bin/env bash
# test-self-update.sh - Unit tests for the repo-wide self-update mechanism
#
# Zero dependencies: no network, no root, no test framework. Each library is
# copied into a throwaway directory beside a fake caller script and sourced in a
# child bash with a recording `curl` shim first on PATH, so nothing here touches
# the repository or the network. The shim serves the sandbox's own files, so
# "remote" equals "local" unless a case points it at the sandbox's remote/ copy.
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

# assert_eq / assert_contains / assert_not_contains: deliberate second copy of
# the trio in utils/tests/test-rsync-over-tunnel.sh. Both files are
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
# lists them. All share the SCRIPTS_UPDATED guard.
readonly LIBRARIES=(
    system-setup/utils-sys.sh
    kubernetes/utils-k8s.sh
    lxc/utils-lxc.sh
    llm/utils-llm.sh
    utils/utils-misc.sh
)

# Build a sandbox for one library and leave its path in SANDBOX. Not a `$()`
# capture: the TEST_TEMP_DIRS+= must reach this shell, not a subshell.
#   <sandbox>/<lib>            copy of the library under test (its _UTILS_DIR)
#   <sandbox>/caller.sh        fake caller; prints the guard it was restarted with
#   <sandbox>/remote/          what the shim serves when SHIM_DIR points here:
#                              identical library, DIFFERENT caller
#   <sandbox>/bin/curl         recording shim
#   <sandbox>/shim.log         one line per shim call (the URL)
SANDBOX=""
make_sandbox() {
    local lib_rel="$1"
    SANDBOX=$(mktemp -d)
    TEST_TEMP_DIRS+=("$SANDBOX")
    cp "${REPO_DIR}/${lib_rel}" "${SANDBOX}/"
    mkdir -p "${SANDBOX}/remote" "${SANDBOX}/bin"
    cp "${REPO_DIR}/${lib_rel}" "${SANDBOX}/remote/"
    # SCRIPTS_UPDATED is written verbatim INTO the fake callers, which expand it
    # when the library execs them; expanding it here would bake this shell's
    # value into the file.
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\necho "RESTARTED_WITH=${SCRIPTS_UPDATED:-unset}"\n' > "${SANDBOX}/caller.sh"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\necho "RESTARTED_WITH=${SCRIPTS_UPDATED:-unset}"\necho REMOTE_COPY\n' > "${SANDBOX}/remote/caller.sh"
    chmod +x "${SANDBOX}/caller.sh" "${SANDBOX}/remote/caller.sh"
    cat > "${SANDBOX}/bin/curl" <<'SHIM'
#!/usr/bin/env bash
# Recording curl shim. Mimics `curl -H … --max-time 15 -o OUT -w '%{http_code}' -sSL URL`:
# copies ${SHIM_DIR}/<basename of URL> to OUT and prints 200. Logs the URL.
# curl only: detect_download_cmd prefers curl, so this shim wins on every host
# and download_script's wget branch is never exercised here.
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
cp "${SHIM_DIR}/$(basename "$url")" "$out"
printf '200'
SHIM
    chmod +x "${SANDBOX}/bin/curl"
    : > "${SANDBOX}/shim.log"
}

# Source the sandboxed library in a child bash and call check_for_updates on the
# fake caller. $1 library basename, $2 guard value ("" = unset), $3 directory the
# shim serves from, $4 non-empty = stub prompt_yes_no to "yes". Prints the
# library's output followed by a final "DOWNLOAD_CMD=<v> GUARD=<v>" line; on the
# accept path the exec'd caller's output replaces that line (exec never returns).
invoke_check() {
    local lib_base="$1" guard_value="$2" shim_dir="$3" accept="${4:-}"
    local -a guard_env=()
    [[ -n "$guard_value" ]] && guard_env=("SCRIPTS_UPDATED=${guard_value}")
    # The single-quoted script below is the CHILD's source text: $1/$2/$3 are its
    # positional args and DOWNLOAD_CMD/SCRIPTS_UPDATED are read after the library
    # sets them, so nothing in it may expand in this shell.
    # shellcheck disable=SC2016
    env "${guard_env[@]+"${guard_env[@]}"}" \
        PATH="${SANDBOX}/bin:${PATH}" SHIM_LOG="${SANDBOX}/shim.log" SHIM_DIR="$shim_dir" \
        bash -c 'source "$1/$2"
            if [[ -n "$3" ]]; then prompt_yes_no() { return 0; }; fi
            check_for_updates "$1/caller.sh"
            printf "DOWNLOAD_CMD=%s GUARD=%s\n" "$DOWNLOAD_CMD" "${SCRIPTS_UPDATED:-unset}"' \
        _ "$SANDBOX" "$lib_base" "$accept" 2>&1 || true
}

echo "== check_for_updates: detect before the guard, guard is one-shot =="
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
    assert_eq '0' "$(wc -l < "${SANDBOX}/shim.log" | tr -d ' ')" "${lib_rel}: restarted → no download attempted"

    # First run, everything already current: two fetches, no restart, no leftovers.
    make_sandbox "$lib_rel"
    out=$(invoke_check "$lib_base" "" "$SANDBOX")
    assert_contains "$out" 'DOWNLOAD_CMD=curl'      "${lib_rel}: up-to-date → DOWNLOAD_CMD populated"
    assert_eq '2' "$(wc -l < "${SANDBOX}/shim.log" | tr -d ' ')" "${lib_rel}: up-to-date → utils + caller fetched once each"
    assert_eq '2' "$(grep -c 'is up-to-date' <<<"$out")" "${lib_rel}: up-to-date → both reported current"
    assert_not_contains "$out" 'Restarting'         "${lib_rel}: up-to-date → no restart"
    assert_eq '0' "$(find "$SANDBOX" -name '~*.tmp.??????' -type f | wc -l | tr -d ' ')" "${lib_rel}: up-to-date → no ~*.tmp leftovers"

    # First run, caller changed, user accepts: the exec'd caller sees the guard.
    make_sandbox "$lib_rel"
    out=$(invoke_check "$lib_base" "" "${SANDBOX}/remote" yes)
    assert_contains "$out" 'RESTARTED_WITH=1'       "${lib_rel}: accept → exec'd caller sees SCRIPTS_UPDATED=1"
    assert_contains "$out" 'REMOTE_COPY'            "${lib_rel}: accept → exec ran the NEW caller"
    assert_eq '2' "$(wc -l < "${SANDBOX}/shim.log" | tr -d ' ')" "${lib_rel}: accept → utils + caller fetched once each"
    assert_eq '0' "$(find "$SANDBOX" -name '~*.tmp.??????' -type f | wc -l | tr -d ' ')" "${lib_rel}: accept → no ~*.tmp leftovers"
done

# Parity: the five bodies must hash identically (AGENTS.md §Helper Library
# Duplication). Same extraction as the roster audit — `check_for_updates() {`
# through the closing brace, comments included — so the first drift fails here
# instead of waiting for a manual audit.
assert_eq '1' "$(for lib_rel in "${LIBRARIES[@]}"; do
        awk '/^check_for_updates\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "${REPO_DIR}/${lib_rel}" | sha256sum
    done | sort -u | wc -l | tr -d ' ')" 'check_for_updates: one digest across the five libraries'

echo ""
echo "${TESTS_RUN} assertions, ${TESTS_FAILED} failed"
[[ "$TESTS_FAILED" -eq 0 ]]
