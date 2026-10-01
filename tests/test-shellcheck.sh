#!/usr/bin/env bash
# test-shellcheck.sh - Lint gate: every tracked *.sh is shellcheck-clean
#
# Runs shellcheck on every *.sh in the git index at the default severity
# (style), so an info or style finding fails the gate exactly as a warning
# does. Passes neither -x nor -P: the repo-root .shellcheckrc supplies
# external-sources and source-path=SCRIPTDIR. Without that rc, every tracked
# script that sources a library reports SC1091, so a green run is itself the
# proof that the rc was found and read.
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
# AGENTS.md §Linting allows only a per-line disable with its reason beside it.
# Not anchored at the line start: shellcheck reads several key=value pairs from
# one rc line, so `external-sources=true disable=SC2155` would slip past an
# anchored match. Text after a `#` is a comment and is ignored.
if rc_disables=$(grep -nE '^[^#]*(^|[[:space:]])disable[[:space:]]*=' .shellcheckrc); then
    printf '  FAIL .shellcheckrc carries a repo-wide disable:\n%s\n' "$rc_disables"
    exit 1
fi
# The rc search stops at the first file found walking up from a script, so a
# nested rc would silently replace the root one for its subtree.
nested_rcs=$(find . -mindepth 2 \( -name .shellcheckrc -o -name shellcheckrc \) -not -path './.git/*' -not -path './.claude/*')
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
