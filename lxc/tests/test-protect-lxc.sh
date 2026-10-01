#!/usr/bin/env bash
# test-protect-lxc.sh - Unit tests for the lxc/ suite: the container-protection
# helpers in lxc/utils-lxc.sh, and launcher behaviour no helper owns
#
# Zero dependencies: no LXC, no root, no network. Every case runs in a
# mktemp -d sandbox — launchers through _lxc_main, with every side effect
# stubbed — or reads a launcher's source text.
# Development-only — never listed in get_script_list().
#
# Usage: ./test-protect-lxc.sh
set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../utils-lxc.sh
source "${TESTS_DIR}/../utils-lxc.sh"
# The helpers under test signal with their exit status and are called as bare
# statements below, then checked with "$?". Under errexit (which utils-lxc.sh
# turns on) the first failing helper would abort the suite instead of failing
# one assertion.
set +e

TESTS_RUN=0
TESTS_FAILED=0

# utils-lxc.sh installs `trap cleanup EXIT`, and that handler only `rm -f`s
# TEMP_FILES entries — it cannot reap the `mktemp -d` SANDBOX this suite
# creates. Replace the trap with a superset that reaps it and then delegates.
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

SANDBOX="$(mktemp -d)"
TEST_TEMP_DIRS+=("$SANDBOX")

# Build a container directory with a stock-looking config; print its path.
make_container() {
    local name="$1"
    mkdir -p "${SANDBOX}/${name}"
    cat > "${SANDBOX}/${name}/config" <<'EOF'
lxc.uts.name = sample
lxc.net.0.type = veth
lxc.net.0.link = br0
lxc.net.0.flags = up
EOF
    echo "${SANDBOX}/${name}/config"
}

# ------------------------------------------------------------------ cases --

echo "== lxc_valid_name =="
lxc_valid_name "dev-box";     assert_eq 0 "$?" "accepts dev-box"
lxc_valid_name "dev_box.1";   assert_eq 0 "$?" "accepts dev_box.1"
lxc_valid_name "../etc";      assert_eq 1 "$?" "rejects ../etc"
lxc_valid_name "a/b";         assert_eq 1 "$?" "rejects a/b"
lxc_valid_name ".hidden";     assert_eq 1 "$?" "rejects a leading dot"
lxc_valid_name "";            assert_eq 1 "$?" "rejects an empty name"

echo "== lxc_resolve_path =="
# Only the non-root branch: this suite never runs as root, so the EUID-0 branch
# (/var/lib/lxc) cannot be exercised here.
assert_eq "${HOME}/.local/share/lxc" "$(lxc_resolve_path)" "non-root resolves to the user-scope path"

echo "== protect / detect / unprotect round trip =="
CFG="$(make_container ct1)"
# Compared byte-wise against a copy, not against "$(cat …)": command
# substitution strips trailing newlines, which is exactly where an
# accumulating blank-line residue would land.
BEFORE="${CFG}.before"
cp "$CFG" "$BEFORE"
lxc_is_protected "$CFG";              assert_eq 1 "$?" "a fresh config is unprotected"
lxc_protect_config "$CFG" 2026-09-15; assert_eq 0 "$?" "protect succeeds"
lxc_is_protected "$CFG";              assert_eq 0 "$?" "now protected"
lxc_protect_config "$CFG" 2026-09-15
assert_eq 1 "$(grep -c '^# --- BEGIN protect-lxc ---$' "$CFG")" "protecting twice leaves one block"
assert_eq "2026-09-15" "$(lxc_protected_since "$CFG")" "reports the protection date"
assert_contains "$(cat "$CFG")" "lxc.hook.destroy = /bin/false" "hook written"
assert_contains "$(cat "$CFG")" "lxc.net.0.link = br0" "original config preserved"
lxc_unprotect_config "$CFG";          assert_eq 0 "$?" "unprotect succeeds"
lxc_is_protected "$CFG";              assert_eq 1 "$?" "unprotected again"
assert_not_contains "$(cat "$CFG")" "lxc.hook.destroy" "hook gone"
assert_not_contains "$(cat "$CFG")" "protect-lxc" "fence gone"
cmp -s "$BEFORE" "$CFG";              assert_eq 0 "$?" "config restored to its original content"

echo "== repeated cycles leave no residue =="
CFG="$(make_container ct2)"
BEFORE="${CFG}.before"
cp "$CFG" "$BEFORE"
for _ in 1 2 3; do
    lxc_protect_config "$CFG" 2026-09-15
    lxc_unprotect_config "$CFG"
done
cmp -s "$BEFORE" "$CFG";              assert_eq 0 "$?" "three protect/unprotect cycles are a no-op"

echo "== config with no trailing newline =="
CFG="$(make_container ct3)"
printf 'lxc.apparmor.profile = unconfined' >> "$CFG"   # deliberately unterminated
lxc_protect_config "$CFG" 2026-09-15
assert_contains "$(cat "$CFG")" "lxc.apparmor.profile = unconfined" "last line intact"
assert_not_contains "$(cat "$CFG")" "unconfined# --- BEGIN" "fence not glued onto it"

echo "== a block with no END fence is refused, not range-deleted to EOF =="
CFG="$(make_container ct4)"
lxc_protect_config "$CFG" 2026-09-15
sed -i '/^# --- END protect-lxc ---$/d' "$CFG"         # simulate a hand-mangled config
echo 'lxc.apparmor.profile = unconfined' >> "$CFG"
lxc_unprotect_config "$CFG" 2>/dev/null
assert_eq 1 "$?" "refuses a block with no END fence"
assert_contains "$(cat "$CFG")" "lxc.apparmor.profile = unconfined" "trailing config survived"

echo "== a stray second BEGIN fence is refused too =="
CFG="$(make_container ct5)"
lxc_protect_config "$CFG" 2026-09-15
echo '# --- BEGIN protect-lxc ---' >> "$CFG"           # complete block, then a stray BEGIN
echo 'lxc.apparmor.profile = unconfined' >> "$CFG"
lxc_unprotect_config "$CFG" 2>/dev/null
assert_eq 1 "$?" "refuses a config with two BEGIN fences"
assert_contains "$(cat "$CFG")" "lxc.apparmor.profile = unconfined" "trailing config survived the second range"

echo "== fences in the wrong order are refused too =="
CFG="$(make_container ct6)"
lxc_protect_config "$CFG" 2026-09-15
sed -i '/^# --- END protect-lxc ---$/d' "$CFG"         # move END above BEGIN
sed -i '1i # --- END protect-lxc ---' "$CFG"
echo 'lxc.apparmor.profile = unconfined' >> "$CFG"
lxc_unprotect_config "$CFG" 2>/dev/null
assert_eq 1 "$?" "refuses fences in the wrong order"
assert_contains "$(cat "$CFG")" "lxc.apparmor.profile = unconfined" "trailing config survived a reversed range"

echo "== a fenced block that lost its date line is still protected =="
CFG="$(make_container ct7)"
lxc_protect_config "$CFG" 2026-09-15
sed -i '/^# protect-lxc: protected /d' "$CFG"           # hand-deleted date line
assert_eq "unknown" "$(lxc_protected_since "$CFG")" "reports unknown instead of unprotected"

echo "== content after the block survives a successful unprotect =="
# The three EOF cases above all end in a refusal, so nothing pins the
# well-formed path: a range that deleted to EOF on a valid block would pass
# every one of them.
CFG="$(make_container ct8)"
BEFORE="${CFG}.before"
cp "$CFG" "$BEFORE"
lxc_protect_config "$CFG" 2026-09-15
echo 'lxc.apparmor.profile = unconfined' >> "$CFG"      # a real config line after the block
echo 'lxc.apparmor.profile = unconfined' >> "$BEFORE"   # what the file must be once the block goes
lxc_unprotect_config "$CFG"
assert_eq 0 "$?" "unprotect succeeds with content after the block"
assert_contains "$(cat "$CFG")" "lxc.apparmor.profile = unconfined" "the line after the block survived"
cmp -s "$BEFORE" "$CFG"
assert_eq 0 "$?" "only the block was removed"

echo "== missing config =="
lxc_is_protected "${SANDBOX}/nope/config";    assert_eq 1 "$?" "a missing config is unprotected"
lxc_protected_since "${SANDBOX}/nope/config"; assert_eq 1 "$?" "a missing config has no date"

echo "== lxc_list_containers =="
assert_eq "ct1
ct2
ct3
ct4
ct5
ct6
ct7
ct8" "$(lxc_list_containers "$SANDBOX" | sort)" "lists every dir that has a config"
mkdir -p "${SANDBOX}/not-a-container"
assert_not_contains "$(lxc_list_containers "$SANDBOX")" "not-a-container" "skips dirs without a config"
mkdir -p "${SANDBOX}/empty-root"
assert_eq "" "$(lxc_list_containers "${SANDBOX}/empty-root")" "an empty root lists nothing"

echo "== stop-lxc.sh and restart-lxc.sh split lxc-ls output one name per line =="
# Both call /usr/bin/lxc-ls by absolute path, which no PATH shim or function
# stub can stand in for, so these pin the source text instead — the same shape
# tests/test-self-update.sh uses for the github/ restart guard.
# shellcheck disable=SC2016  # the single quotes are deliberate: these are the
# literal source lines being searched for, not expansions.
for script in stop-lxc.sh restart-lxc.sh; do
    assert_eq 1 "$(grep -cF 'running_list=$(/usr/bin/lxc-ls -1 --running)' "${TESTS_DIR}/../${script}")" \
        "${script}: captures lxc-ls -1 --running, so a failing lxc-ls still aborts"
    assert_eq 1 "$(grep -cF 'mapfile -t RUNNING <<< "$running_list"' "${TESTS_DIR}/../${script}")" \
        "${script}: splits the capture one line per element"
done

# ------------------------------------------------------- launcher main() --

# Drive a launcher's main() with every side effect stubbed; prints "<rc>|<output>".
# The script is sourced in a child bash, so its exits stay there; `|| true`
# because an &&-form execution guard returns 1 when sourced. The stubs follow
# the source so they replace the library's own check_for_updates (network)
# and prompt_yes_no (/dev/tty). Every external command a path can reach is a
# stub that never touches a real container or escalates: lxc-info, lxc-create,
# sudo and prompt_yes_no print REACHED (lxc-info and prompt_yes_no return 1, so
# no existing-container, stop or start path is reachable); 7z joins its
# arguments with | so a word-split regression shows; tar -tf emits a 20000-line
# listing, far past the pipe buffer, so restore-lxc.sh's `head -1` closes the
# pipe on it exactly as on a real archive, and a reader that drains to EOF still
# terminates; any other tar call prints REACHED and returns. HOME points
# into the sandbox, so lxc_resolve_path never names the real user-scope LXC
# root; stdin is /dev/null, so a stub that drains its input cannot block.
_lxc_main() {   # $1 = launcher basename, "${@:2}" = its arguments
    local rc=0 out
    out=$(HOME="${SANDBOX}/home" bash -c 'source "$1" || true
            check_for_updates()    { :; }
            check_required_tools() { :; }
            prompt_yes_no()        { echo "REACHED prompt_yes_no $1"; return 1; }
            lxc-info()   { echo "REACHED lxc-info $*"; return 1; }
            lxc-create() { echo "REACHED lxc-create $*"; return 1; }
            sudo()       { echo "REACHED sudo $*"; }
            7z()  { cat > /dev/null; [[ "$1" == a ]] || return 0; : > "${!#}"; local IFS="|"; echo "7Z_ARGS=$*"; }
            tar() { cat > /dev/null; [[ "$1" == -tf ]] || { echo "REACHED tar $*"; return 0; }; printf "restored-box/rootfs/etc\n%.0s" {1..20000}; }
            main "${@:2}"' _ "${TESTS_DIR}/../$1" "${@:2}" </dev/null 2>&1) || rc=$?
    printf '%s|%s' "$rc" "$out"
}

echo "== create-lxc.sh and backup-lxc.sh refuse an unsafe container name =="
for script in create-lxc.sh backup-lxc.sh; do
    for name in "../etc" "a/b" ".hidden"; do
        res="$(_lxc_main "$script" "$name")"
        assert_eq 64 "${res%%|*}" "${script} ${name}: exits 64 (EX_USAGE)"
        assert_contains "${res#*|}" "✖ Invalid container name: ${name}" "${script} ${name}: names the rejected value"
        assert_not_contains "${res#*|}" "REACHED" "${script} ${name}: refused before any lxc-* or sudo call"
    done
done
# Explicit distribution/release/architecture skip create-lxc.sh's
# /etc/os-release probe, so the valid-name case does not depend on the host.
res="$(_lxc_main create-lxc.sh dev-box debian trixie amd64)"
assert_not_contains "${res#*|}" "Invalid container name" "create-lxc.sh dev-box: a valid name passes the guard"
assert_contains "${res#*|}" "REACHED lxc-create --name dev-box" "create-lxc.sh dev-box: reaches lxc-create"
res="$(_lxc_main backup-lxc.sh no-such-box)"
assert_eq 66 "${res%%|*}" "backup-lxc.sh no-such-box: a valid name reaches the existence check (EX_NOINPUT)"
assert_not_contains "${res#*|}" "Invalid container name" "backup-lxc.sh no-such-box: a valid name passes the guard"

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
