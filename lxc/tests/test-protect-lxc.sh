#!/usr/bin/env bash
# test-protect-lxc.sh - Unit tests for the container-protection helpers in
# lxc/utils-lxc.sh
#
# Zero dependencies: no LXC, no root, no network. Every case runs against a
# config file in a mktemp -d sandbox. Development-only — never listed in
# get_script_list().
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

echo "== protect / detect / unprotect round trip =="
CFG="$(make_container ct1)"
BEFORE="$(cat "$CFG")"
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
assert_eq "$BEFORE" "$(cat "$CFG")" "config restored to its original content"

echo "== repeated cycles leave no residue =="
CFG="$(make_container ct2)"
BEFORE="$(cat "$CFG")"
for _ in 1 2 3; do
    lxc_protect_config "$CFG" 2026-09-15
    lxc_unprotect_config "$CFG"
done
assert_eq "$BEFORE" "$(cat "$CFG")" "three protect/unprotect cycles are a no-op"

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
ct7" "$(lxc_list_containers "$SANDBOX" | sort)" "lists every dir that has a config"
mkdir -p "${SANDBOX}/not-a-container"
assert_not_contains "$(lxc_list_containers "$SANDBOX")" "not-a-container" "skips dirs without a config"
mkdir -p "${SANDBOX}/empty-root"
assert_eq "" "$(lxc_list_containers "${SANDBOX}/empty-root")" "an empty root lists nothing"

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
