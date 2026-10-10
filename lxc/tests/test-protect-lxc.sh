#!/usr/bin/env bash
# test-protect-lxc.sh - Unit tests for the lxc/ suite: the container-protection
# helpers in lxc/utils-lxc.sh, and launcher behaviour no helper owns
#
# Zero dependencies: no LXC, no root, no network. Every case runs in a
# mktemp -d sandbox — launchers through _lxc_main and config-lxc-ssh.sh
# through _ssh_configure, with every side effect stubbed.
# Development-only — never listed in get_script_list().
#
# Usage: ./test-protect-lxc.sh
set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

if [[ $EUID -eq 0 ]]; then
    printf 'FAIL this suite runs as your own user, never as root: lxc_resolve_path would name the real /var/lib/lxc\n'
    exit 64
fi

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
# Only the non-root branch: the suite refuses to run as root (top of file), so
# the EUID-0 branch (/var/lib/lxc) cannot be exercised here.
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

# ------------------------------------------------------- launcher main() --

# Drive a launcher's main() with every side effect stubbed; prints "<rc>|<output>".
# The script is sourced in a child bash, so its exits stay there; its if-form
# execution guard keeps main() from running on source. The stubs follow
# the source so they replace the library's own sweep_stale_temps (a stale temp
# in the real lxc/ directory would be deleted, after a /dev/tty pause),
# check_for_updates (network) and prompt_yes_no (/dev/tty). Every external
# command a path can reach is a stub that never touches a real container or
# escalates: lxc-info, lxc-create, sudo and prompt_yes_no print REACHED
# (lxc-info and prompt_yes_no return 1, so no existing-container, stop or start
# path is reachable); 7z joins its arguments with | so a word-split regression
# shows; tar -tf emits a 20000-line listing whose top-level name is TAR_TOP
# (default restored-box), far past the pipe buffer, so restore-lxc.sh's
# `head -1` closes the pipe on it exactly as on a real archive, and a reader
# that drains to EOF still terminates; any other tar call prints REACHED and
# returns. EXTRA_STUBS, when set, is evaluated after these, so a case can add a
# stub or replace one. HOME points into the sandbox, so lxc_resolve_path never
# names the real user-scope LXC root; stdin is /dev/null, so a stub that drains
# its input cannot block.
_lxc_main() {   # $1 = launcher basename, "${@:2}" = its arguments
    local rc=0 out
    out=$(HOME="${SANDBOX}/home" TAR_TOP="${TAR_TOP-restored-box}" bash -c 'source "$1"
            sweep_stale_temps()    { :; }
            check_for_updates()    { :; }
            check_required_tools() { :; }
            prompt_yes_no()        { echo "REACHED prompt_yes_no $1"; return 1; }
            lxc-info()   { echo "REACHED lxc-info $*"; return 1; }
            lxc-create() { echo "REACHED lxc-create $*"; return 1; }
            sudo()       { echo "REACHED sudo $*"; }
            7z()  { cat > /dev/null; [[ "$1" == a ]] || return 0; : > "${!#}"; local IFS="|"; echo "7Z_ARGS=$*"; }
            tar() { cat > /dev/null; [[ "$1" == -tf ]] || { echo "REACHED tar $*"; return 0; }; printf "${TAR_TOP}/rootfs/etc\n%.0s" {1..20000}; }
            eval "$2"
            main "${@:3}"' _ "${TESTS_DIR}/../$1" "${EXTRA_STUBS-}" "${@:2}" </dev/null 2>&1) || rc=$?
    printf '%s|%s' "$rc" "$out"
}

echo "== stop-lxc.sh stops each name lxc-ls lists, and aborts when lxc-ls fails =="
# stop-lxc.sh calls /usr/bin/lxc-ls by absolute path. Outside POSIX mode bash
# accepts that path as a function name and runs the function in its place, in
# a command substitution too. The stub answers only the exact -1 --running call.
STOP_STUBS='lxc-stop()  { echo "REACHED lxc-stop $*"; }
            systemctl() { :; }
            lxc-ls()    { :; }
            sleep()     { :; }'
res="$(EXTRA_STUBS="${STOP_STUBS}"'
            /usr/bin/lxc-ls() { [[ "$*" == "-1 --running" ]] || return 2; printf "a1\ndev-box\n"; }' _lxc_main stop-lxc.sh)"
assert_eq 0 "${res%%|*}" "two running: stop-lxc.sh completes"
assert_contains "${res#*|}" "Stopping 2 container(s)" "two running: one element per listed name"
assert_contains "${res#*|}" "REACHED lxc-stop --name a1" "two running: a1 reaches lxc-stop"
assert_contains "${res#*|}" "REACHED lxc-stop --name dev-box" "two running: dev-box reaches lxc-stop on its own"
res="$(EXTRA_STUBS="${STOP_STUBS}"'
            /usr/bin/lxc-ls() { :; }' _lxc_main stop-lxc.sh)"
assert_eq 0 "${res%%|*}" "none running: stop-lxc.sh exits 0"
assert_contains "${res#*|}" "No running containers found" "none running: reported as such"
assert_not_contains "${res#*|}" "REACHED lxc-stop" "none running: no empty name reaches lxc-stop"
res="$(EXTRA_STUBS="${STOP_STUBS}"'
            /usr/bin/lxc-ls() { return 1; }' _lxc_main stop-lxc.sh)"
assert_eq 1 "${res%%|*}" "a failing lxc-ls: stop-lxc.sh exits 1"
assert_not_contains "${res#*|}" "No running containers found" "a failing lxc-ls: not read as none running"
assert_not_contains "${res#*|}" "REACHED lxc-stop" "a failing lxc-ls: no lxc-stop is reached"

echo "== restart-lxc.sh restarts each name lxc-ls lists, and aborts when lxc-ls fails =="
# restart-lxc.sh runs "${SCRIPT_DIR}/stop-lxc.sh" and "${SCRIPT_DIR}/start-lxc.sh".
# SCRIPT_DIR set on the _lxc_main call reaches the child bash, so the script
# loads the real library through RESTART_DIR's symlink and runs the echo stubs
# beside it instead of its real siblings.
RESTART_DIR="${SANDBOX}/restart-dir"
mkdir -p "$RESTART_DIR"
ln -s "${TESTS_DIR}/../utils-lxc.sh" "${RESTART_DIR}/utils-lxc.sh"
for sibling in stop-lxc.sh start-lxc.sh; do
    printf '#!/usr/bin/env bash\necho "REACHED %s $*"\n' "$sibling" > "${RESTART_DIR}/${sibling}"
    chmod +x "${RESTART_DIR}/${sibling}"
done
res="$(SCRIPT_DIR="$RESTART_DIR" EXTRA_STUBS='sleep() { :; }
            /usr/bin/lxc-ls() { [[ "$*" == "-1 --running" ]] || return 2; printf "a1\ndev-box\n"; }' _lxc_main restart-lxc.sh)"
assert_eq 0 "${res%%|*}" "two running: restart-lxc.sh completes"
assert_contains "${res#*|}" "Restarting 2 container(s)" "two running: one element per listed name"
assert_contains "${res#*|}" "REACHED stop-lxc.sh a1 dev-box" "two running: stop-lxc.sh gets both names"
assert_contains "${res#*|}" "REACHED start-lxc.sh a1 dev-box" "two running: start-lxc.sh gets both names"
res="$(SCRIPT_DIR="$RESTART_DIR" EXTRA_STUBS='sleep() { :; }
            /usr/bin/lxc-ls() { :; }' _lxc_main restart-lxc.sh)"
assert_eq 0 "${res%%|*}" "none running: restart-lxc.sh exits 0"
assert_contains "${res#*|}" "No running containers found" "none running: reported as such"
assert_not_contains "${res#*|}" "REACHED stop-lxc.sh" "none running: stop-lxc.sh is not run"
res="$(SCRIPT_DIR="$RESTART_DIR" EXTRA_STUBS='sleep() { :; }
            /usr/bin/lxc-ls() { return 1; }' _lxc_main restart-lxc.sh)"
assert_eq 1 "${res%%|*}" "a failing lxc-ls: restart-lxc.sh exits 1"
assert_not_contains "${res#*|}" "No running containers found" "a failing lxc-ls: not read as none running"
assert_not_contains "${res#*|}" "REACHED" "a failing lxc-ls: neither sibling is run"

echo "== create-lxc.sh and backup-lxc.sh refuse an unsafe container name =="
for script in create-lxc.sh backup-lxc.sh; do
    for name in "../etc" "a/b" ".hidden"; do
        res="$(_lxc_main "$script" "$name")"
        assert_eq 64 "${res%%|*}" "${script} ${name}: exits 64 (EX_USAGE)"
        assert_contains "${res#*|}" "✖ Invalid container name: ${name}" "${script} ${name}: names the rejected value"
        # backup-lxc.sh would stop at its existence check (exit 66) before any stub
        # even without the guard, and its lxc-info/sudo output feeds grep -q and the
        # 7z stub, so a REACHED check cannot fail there: its exit 64 is the proof.
        if [[ "$script" == create-lxc.sh ]]; then
            assert_not_contains "${res#*|}" "REACHED" "${script} ${name}: refused before any lxc-* or sudo call"
        fi
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

echo "== create-lxc.sh warns and goes on when os-release names no distribution or release =="
# Every os-release key is optional; the grep stub finds none of them.
# shellcheck disable=SC2016  # a stub definition: _lxc_main's child bash expands it
res="$(EXTRA_STUBS='grep() {
                local arg
                for arg in "$@"; do [[ "$arg" == /etc/os-release ]] && return 1; done
                command grep "$@"
            }' _lxc_main create-lxc.sh probe-box)"
assert_contains "${res#*|}" "⚠ Could not detect distribution" "no ID: the distribution warning prints"
assert_contains "${res#*|}" "⚠ Could not detect release" "no VERSION_CODENAME or VERSION_ID: the release warning prints"
assert_contains "${res#*|}" "REACHED lxc-create --name probe-box -t download -- -a" "no os-release keys: lxc-create is still reached"

echo "== backup-lxc.sh and restore-lxc.sh answer an argument error before checking their tools =="
# check_required_tools fails here the way it does on a host without 7z.
NO_7Z='check_required_tools() { echo "REACHED check_required_tools"; exit 69; }'
res="$(EXTRA_STUBS="$NO_7Z" _lxc_main backup-lxc.sh ../etc)"
assert_eq 64 "${res%%|*}" "backup-lxc.sh ../etc without 7z: exits 64, not 69"
res="$(EXTRA_STUBS="$NO_7Z" _lxc_main backup-lxc.sh --help)"
assert_eq 0 "${res%%|*}" "backup-lxc.sh --help without 7z: exits 0"
res="$(EXTRA_STUBS="$NO_7Z" _lxc_main restore-lxc.sh "${SANDBOX}/no-such-box_20260101_000000.tar.7z")"
assert_eq 66 "${res%%|*}" "restore-lxc.sh with a missing archive and no 7z: exits 66, not 69"

echo "== backup-lxc.sh hands 7z each preset option as its own argument =="
mkdir -p "${SANDBOX}/home/.local/share/lxc/dev-box"
res="$(_lxc_main backup-lxc.sh dev-box "${SANDBOX}/backups" --compression=fast)"
assert_eq 0 "${res%%|*}" "fast: the backup completes"
assert_contains "${res#*|}" "7Z_ARGS=a|-si|-t7z|-m0=lzma2|-mx=3|-md=128m|-mfb=64|-mmf=bt2|-ms=on|-mmt|${SANDBOX}/backups/dev-box_" \
    "fast: every preset option is a separate 7z argument"
res="$(_lxc_main backup-lxc.sh dev-box "${SANDBOX}/backups" --compression=balanced)"
assert_eq 0 "${res%%|*}" "balanced: the backup completes"
assert_contains "${res#*|}" "7Z_ARGS=a|-si|-t7z|-m0=lzma2|-mx=5|-md=512m|-mfb=128|-mmf=bt4|-ms=on|-mmt|${SANDBOX}/backups/dev-box_" \
    "balanced: every preset option is a separate 7z argument"
res="$(_lxc_main backup-lxc.sh dev-box "${SANDBOX}/backups")"
assert_eq 0 "${res%%|*}" "default (small): the backup completes"
assert_contains "${res#*|}" "7Z_ARGS=a|-si|-t7z|-m0=lzma2|-mx=9|-md=1536m|-mfb=273|-mmf=bt4|-ms=on|-mmt|${SANDBOX}/backups/dev-box_" \
    "default (small): every preset option is a separate 7z argument"

echo "== restore-lxc.sh reads the container name past head -1's SIGPIPE =="
: > "${SANDBOX}/restored-box_20260101_000000.tar.7z"
res="$(_lxc_main restore-lxc.sh "${SANDBOX}/restored-box_20260101_000000.tar.7z")"
assert_eq 0 "${res%%|*}" "the restore runs to completion against the stubbed archive"
assert_contains "${res#*|}" "Original container name: restored-box" "the archive's top-level name is read"

echo "== restore-lxc.sh refuses an unsafe name from the archive or the command line =="
res="$(TAR_TOP=.. _lxc_main restore-lxc.sh "${SANDBOX}/restored-box_20260101_000000.tar.7z")"
assert_eq 65 "${res%%|*}" "archive top-level ..: exits 65 (EX_DATAERR)"
assert_contains "${res#*|}" "✖ Invalid container name in ${SANDBOX}/restored-box_20260101_000000.tar.7z: .." \
    "archive top-level ..: names the archive and the rejected value"
assert_not_contains "${res#*|}" "REACHED sudo" "archive top-level ..: refused before any sudo call"
res="$(_lxc_main restore-lxc.sh "${SANDBOX}/restored-box_20260101_000000.tar.7z" 'a/b')"
assert_eq 64 "${res%%|*}" "override a/b: exits 64 (EX_USAGE)"
assert_contains "${res#*|}" "✖ Invalid container name: a/b" "override a/b: names the rejected value"
assert_not_contains "${res#*|}" "REACHED sudo" "override a/b: refused before any sudo call"
res="$(EXTRA_STUBS="$NO_7Z" _lxc_main restore-lxc.sh "${SANDBOX}/restored-box_20260101_000000.tar.7z" 'a/b')"
assert_eq 64 "${res%%|*}" "override a/b without 7z: exits 64, not 69"

# ------------------------------------------------ config-lxc-ssh.sh --

# Run config-lxc-ssh.sh's configure_container_ssh for one container under
# SSH_ROOT in a child bash; prints "<rc>|<output>". Sourcing runs no main (the
# if-form guard). The stubs skip the sshd probe, the chown to the container's
# uid and the backup copy, so the run needs no root and writes only where the
# function itself writes.
SSH_ROOT="${SANDBOX}/ssh-root"
_ssh_configure() {   # $1 = container name under SSH_ROOT
    local rc=0 out
    out=$(bash -c 'source "$1"
            check_ssh_in_container() { return 0; }
            chown()       { :; }
            backup_file() { :; }
            TARGET_USER=tester
            LXC_ROOT_PATH="$2"
            configure_container_ssh "$3" "ssh-ed25519 KEY"' _ "${TESTS_DIR}/../config-lxc-ssh.sh" "$SSH_ROOT" "$1" </dev/null 2>&1) || rc=$?
    printf '%s|%s' "$rc" "$out"
}

# Build a container under SSH_ROOT whose rootfs holds home/tester; print the rootfs.
make_ssh_container() {
    local rootfs="${SSH_ROOT}/$1/rootfs"
    mkdir -p "${rootfs}/home/tester"
    printf 'lxc.rootfs.path = dir:%s\n' "$rootfs" > "${SSH_ROOT}/$1/config"
    echo "$rootfs"
}

OUTSIDE="${SANDBOX}/outside"
mkdir -p "${OUTSIDE}/home-target" "${OUTSIDE}/ssh-target"
printf 'host-only-key\n' > "${OUTSIDE}/authorized_keys"
cp "${OUTSIDE}/authorized_keys" "${OUTSIDE}/authorized_keys.before"

echo "== config-lxc-ssh.sh writes a key only inside the container's own home =="
ROOTFS="$(make_ssh_container plain)"
res="$(_ssh_configure plain)"
assert_eq 0 "${res%%|*}" "a plain home: configured"
assert_eq "ssh-ed25519 KEY" "$(cat "${ROOTFS}/home/tester/.ssh/authorized_keys")" "a plain home: the key is appended"

ROOTFS="$(make_ssh_container keylink)"
mkdir -p "${ROOTFS}/home/tester/.ssh"
ln -s "${OUTSIDE}/authorized_keys" "${ROOTFS}/home/tester/.ssh/authorized_keys"
res="$(_ssh_configure keylink)"
assert_eq 1 "${res%%|*}" "a symlinked authorized_keys: refused"
assert_contains "${res#*|}" "Refusing a symlinked .ssh or authorized_keys" "a symlinked authorized_keys: says why"
assert_contains "${res#*|}" ": ${ROOTFS}/home/tester/.ssh/authorized_keys - skipping" "a symlinked authorized_keys: names that link"
cmp -s "${OUTSIDE}/authorized_keys.before" "${OUTSIDE}/authorized_keys"
assert_eq 0 "$?" "a symlinked authorized_keys: the link target is untouched"

ROOTFS="$(make_ssh_container homelink)"
rmdir "${ROOTFS}/home/tester"
ln -s "${OUTSIDE}/home-target" "${ROOTFS}/home/tester"
res="$(_ssh_configure homelink)"
assert_eq 1 "${res%%|*}" "a home linked out of the rootfs: refused"
assert_contains "${res#*|}" "home is missing or leaves the rootfs" "a home linked out of the rootfs: says why"
assert_eq "" "$(find "${OUTSIDE}/home-target" -mindepth 1)" "a home linked out of the rootfs: nothing is created at the link target"

ROOTFS="$(make_ssh_container sshlink)"
ln -s "${OUTSIDE}/ssh-target" "${ROOTFS}/home/tester/.ssh"
res="$(_ssh_configure sshlink)"
assert_eq 1 "${res%%|*}" "a symlinked .ssh: refused"
assert_contains "${res#*|}" "Refusing a symlinked .ssh or authorized_keys" "a symlinked .ssh: says why"
assert_contains "${res#*|}" ": ${ROOTFS}/home/tester/.ssh - skipping" "a symlinked .ssh: names that link"
assert_eq "" "$(find "${OUTSIDE}/ssh-target" -mindepth 1)" "a symlinked .ssh: nothing is written at the link target"

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
