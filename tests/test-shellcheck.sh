#!/usr/bin/env bash
# test-shellcheck.sh - Lint gate: every tracked *.sh is shellcheck-clean
#
# Runs shellcheck on every *.sh in the git index at the default severity
# (style), so an info or style finding fails the gate exactly as a warning
# does. Passes neither -x nor -P: the repo-root .shellcheckrc supplies
# external-sources and source-path=SCRIPTDIR. Without that rc, every tracked
# script that sources a library reports SC1091, so a green run is itself the
# proof that the rc was found and read. The rc may hold only comments and
# those two keys, and a directive before a script's first command, which
# applies to the whole file, only the keys that locate sourced files and enable.
#
# Usage: ./tests/test-shellcheck.sh
set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'shellcheck is not installed: install it (apt install shellcheck / brew install shellcheck) and re-run\n' >&2
    exit 69
fi

# SHELLCHECK_OPTS is prepended to every shellcheck command line, so a personal
# "--exclude=SC2155" there would hide findings unseen.
unset SHELLCHECK_OPTS

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR
REPO_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
readonly REPO_DIR

# Relative paths from the root, so every finding reads "dir/file.sh:line:col".
cd "$REPO_DIR"

if [[ ! -f .shellcheckrc ]]; then
    printf '  FAIL .shellcheckrc is missing from the repository root\n'
    exit 1
fi
# An allowlist (AGENTS.md §Linting): every line is blank, a comment,
# `external-sources=true`, or `source-path=` with one unquoted path. shellcheck
# honours any other key here for every script (disable=, shell=,
# extended-analysis=false), reads several key=value pairs from one line, and
# lets quoting and an unspaced `#` carry a second key past a deny-list regex.
# grep -v exits 0 when it prints an offending line, 1 when every line is
# allowed, and above 1 when it could not run, which must never read as clean.
rc_grep=0
rc_overrides=$(grep -nvE '^[[:space:]]*(#|$)|^external-sources=true$|^source-path=[A-Za-z0-9_./:-]+$' .shellcheckrc) || rc_grep=$?
case "$rc_grep" in
    0)
        printf '  FAIL .shellcheckrc carries a line that is not a comment, external-sources=true or source-path=<path>:\n%s\n' "$rc_overrides"
        exit 1
        ;;
    1)
        ;;
    *)
        printf '  FAIL rc check could not run (grep exit %d)\n' "$rc_grep"
        exit 1
        ;;
esac
# The rc search stops at the first file found walking up from a script, so a
# nested rc would silently replace the root one for its subtree. Only the
# worktrees under .claude/ are other checkouts, so only they are skipped.
nested_rcs=$(find . -mindepth 2 \( -name .shellcheckrc -o -name shellcheckrc \) -not -path './.git/*' -not -path './.claude/worktrees/*')
if [[ -n "$nested_rcs" ]]; then
    printf '  FAIL a nested rc replaces .shellcheckrc for its subtree:\n%s\n' "$nested_rcs"
    exit 1
fi

# An empty list means git failed (not a checkout?); never report that green.
mapfile -d '' -t SCRIPTS < <(git -C "$REPO_DIR" ls-files -z -- '*.sh')
if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
    printf '  FAIL no tracked *.sh under %s (not a git checkout?)\n' "$REPO_DIR"
    exit 1
fi

printf 'shellcheck %s, %d tracked *.sh\n' \
    "$(shellcheck --version | sed -n 's/^version: //p')" "${#SCRIPTS[@]}"

FILES_FAILED=0
for f in "${SCRIPTS[@]}"; do
    # A directive before a script's first command applies to the whole file
    # (shellcheck's scoping). AGENTS.md §Linting allows only the keys that
    # locate sourced files (source, source-path, external-sources) and enable
    # there; silence a finding on its own line instead. Every whitespace-split
    # word must be one of those keys, so a quoted value or a trailing comment
    # in such a directive fails closed.
    awk_rc=0
    file_wide=$(awk '
        NR == 1 && /^#!/ { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]/ {
            directive = $0
            sub(/^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+/, "", directive)
            n = split(directive, word, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                if (word[i] == "") continue
                key = word[i]
                sub(/=.*/, "", key)
                if (key !~ /^(source|source-path|external-sources|enable)$/) {
                    print NR ": " $0
                    break
                }
            }
            next
        }
        /^[[:space:]]*#/ { next }
        { exit }
    ' "$f") || awk_rc=$?
    if [[ "$awk_rc" -ne 0 ]]; then
        printf '  FAIL %s: file-wide directive check could not run (awk exit %d)\n' "$f" "$awk_rc"
        ((FILES_FAILED++)) || true
        continue
    fi
    if [[ -n "$file_wide" ]]; then
        printf '  FAIL %s: file-wide shellcheck directive before the first command with a key other than source, source-path, external-sources or enable\n' "$f"
        printf '         %s\n' "${file_wide//$'\n'/$'\n'         }"
        ((FILES_FAILED++)) || true
        continue
    fi
    sc_rc=0
    # --severity=style is the default, spelled out because it IS the policy.
    findings=$(shellcheck --severity=style --format=gcc "$f" 2>&1) || sc_rc=$?
    case "$sc_rc" in
        0)
            printf '  ok   %s\n' "$f"
            ;;
        1)
            printf '  FAIL %s: %d finding(s)\n' "$f" "$(grep -c . <<<"$findings")"
            printf '         %s\n' "${findings//$'\n'/$'\n'         }"
            ((FILES_FAILED++)) || true
            ;;
        *)
            printf '  FAIL %s: shellcheck exited %d\n' "$f" "$sc_rc"
            printf '         %s\n' "${findings//$'\n'/$'\n'         }"
            ((FILES_FAILED++)) || true
            ;;
    esac
done

echo ""
if [[ "$FILES_FAILED" -gt 0 ]]; then
    printf '%d file(s) with findings, %d of %d clean\n' \
        "$FILES_FAILED" "$((${#SCRIPTS[@]} - FILES_FAILED))" "${#SCRIPTS[@]}"
    exit 1
fi
printf 'all %d files clean\n' "${#SCRIPTS[@]}"
