#!/usr/bin/env bash

# test-all.sh - Run every test suite in this repository
#
# Usage: ./test-all.sh
#
# This script:
# - Runs each tracked test-*.sh below the repository root, listed from the git
#   index, so a new suite is picked up the moment it is committed
# - Streams each suite's output, then reports one line per suite
# - Exits 1 if any suite fails, naming the suites that did

set -euo pipefail

readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

print_error()   { printf '%b[ ERROR   ]%b %s\n' "$RED" "$NC" "$1" >&2; if [[ -t 2 ]]; then printf '\a' >&2; sleep 2; fi; }
print_info()    { printf '%b[ INFO    ]%b %s\n' "$BLUE" "$NC" "$1"; }
print_success() { printf '%b[ SUCCESS ]%b %s\n' "$GREEN" "$NC" "$1"; }

main() {
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # `*/**/` requires at least one directory, so this root-level runner never
    # lists (and re-runs) itself. Captured into a variable, not fed to mapfile
    # through a process substitution: a git failure there would go unnoticed
    # and leave an empty list that reports green.
    local suite_list
    suite_list=$(git -C "$repo_root" ls-files -- ':(glob)*/**/test-*.sh')
    if [[ -z "$suite_list" ]]; then
        print_error "✖ No test suites found under ${repo_root}"
        exit 1
    fi
    local suites=()
    mapfile -t suites <<<"$suite_list"

    local failed=()
    local suite
    for suite in "${suites[@]}"; do
        print_info "Running ${suite}..."
        if "${repo_root}/${suite}"; then
            print_success "✓ ${suite}"
        else
            print_error "✖ ${suite} failed"
            failed+=("$suite")
        fi
        echo ""
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        print_error "✖ ${#failed[@]} of ${#suites[@]} suites failed: ${failed[*]}"
        exit 1
    fi
    print_success "✓ All ${#suites[@]} suites passed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
