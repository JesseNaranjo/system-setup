#!/usr/bin/env bash
# test-gh-org.sh - Unit tests for the github/gh_org_*.sh standalones
#
# Zero dependencies beyond jq: no gh, no network, no GitHub account. Each case
# runs a child bash that sources one script (its if-form execution guard keeps
# main() from running) with SELF_UPDATE_RESTARTED=1 set, replaces `gh` or
# `gh_api` with a function that dispatches on "$*" to canned output, and then
# calls the function under test, or main() with its stale-temp sweep stubbed.
# The usage-error cases run the two delete scripts as child processes instead:
# argument parsing comes first in their main(), before anything reaches gh.
#
# Usage: ./github/tests/test-gh-org.sh
set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

command -v jq >/dev/null 2>&1 || { echo "jq is required to run this suite" >&2; exit 69; }

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR
readonly COPY="${TESTS_DIR}/../gh_org_copy.sh"
readonly DELETE_ISSUES="${TESTS_DIR}/../gh_org_delete_issues.sh"
readonly DELETE_REPOS="${TESTS_DIR}/../gh_org_delete_repos.sh"

TESTS_RUN=0
TESTS_FAILED=0

SANDBOX=$(mktemp -d)
readonly SANDBOX
trap 'rm -rf "$SANDBOX"' EXIT

# assert_eq / assert_contains / assert_not_contains: one of five copies of the
# trio — tests/test-self-update.sh, utils/tests/test-rsync-over-tunnel.sh,
# utils/tests/test-rsync-two-way.sh and lxc/tests/test-protect-lxc.sh carry the
# other four. All five are development-only; change them together.
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

# Output with its colour codes removed and every run of spaces squeezed to one,
# so a Summary line reads "Issues failed: 1" whatever its padding and colour.
_plain() {
    sed $'s/\033\\[[0-9;]*m//g' | tr -s ' '
}

# Canned body for one gh_api endpoint, served the way `gh api` serves it: page 1
# always, page 2 only to a --paginate call; and when the call carries --jq, gh
# applies that filter itself, page by page, so the pages go through the call's
# own filter. Exported so every case's child bash can call it from its shim.
_gh_serve() {
    local page1="$1" page2="$2"
    shift 2
    local body="$page1" filter="" prev="" a
    for a in "$@"; do
        [[ "$a" == "--paginate" ]] && body+="$page2"
        [[ "$prev" == "--jq" ]] && filter="$a"
        prev="$a"
    done
    if [[ -n "$filter" ]]; then
        jq -r "$filter" <<<"$body"
    else
        printf '%s\n' "$body"
    fi
}
export -f _gh_serve

# The destination's milestones, in two pages; the title with double quotes is on
# the second.
export DST_MS_P1='[{"title":"Other","number":1}]'
export DST_MS_P2='[{"title":"He said \"hi\"","number":2}]'
readonly QUOTED_TITLE='He said "hi"'

# The gh_api shim every gh_org_copy.sh case shares, sourced by the child after
# the script so it replaces the script's own gh_api. The bodies come from the
# environment, so each case sets only the ones it reads. _capture calls a
# function through $(…), as copy_issues and copy_prs_as_archival_issues call
# create_issue_in_dest, and prints what it captured between brackets.
cat >"${SANDBOX}/copy-shim.sh" <<'EOF'
gh_api() {
    case "$*" in
        *"POST /repos/d/r/milestones "*)        printf "%s\n" "$*" >>"$POST_LOG"; echo "{}" ;;
        *"/repos/s/r/labels?"*)                 _gh_serve "[]" "" "$@" ;;
        *"/repos/s/r/milestones?"*)             _gh_serve "$SRC_MS" "" "$@" ;;
        *"/repos/d/r/milestones?state=all"*)    _gh_serve "$DST_MS_P1" "$DST_MS_P2" "$@" ;;
        *"/repos/d/r/labels/"*)                 return 1 ;;
        *"POST /repos/d/r/labels "*)            echo "{}" ;;
        *"/repos/d/r/issues?state=all"*)        _gh_serve "${DST_ISSUES:-[]}" "" "$@" ;;
        *"POST /repos/d/r/issues --input -"*)   cat >>"$BODY_LOG"; printf "%s\n" "$ISSUE_POST_REPLY"; return "${ISSUE_POST_RC:-0}" ;;
        *"PATCH /repos/d/r/issues/"*)           printf "%s\n" "$*" >>"$POST_LOG"; echo "{}" ;;
        *"/repos/s/r/pulls?state=all"*)         _gh_serve "$SRC_PULLS" "" "$@" ;;
        *"/repos/s/r/issues/1/comments"*)       _gh_serve "$SRC_PR_ISSUE_COMMENTS" "" "$@" ;;
        *"/repos/s/r/pulls/1/comments"*)        _gh_serve "$SRC_PR_REVIEW_COMMENTS" "" "$@" ;;
        *"/repos/s/r/pulls/1/reviews"*)         _gh_serve "$SRC_PR_REVIEWS" "" "$@" ;;
        *"POST /repos/d/r/issues/7/comments"*)  printf "%s\n" "$*" >>"$POST_LOG"; echo "{}" ;;
        *)                                      return 1 ;;
    esac
}
_capture() {
    local v
    v=$("$@")
    printf '[%s]' "$v"
}
EOF

# Run one gh_org_copy.sh case: a child bash sources the script and the shim,
# then runs "$@". Its stdout goes to $SANDBOX/out, its stderr to $SANDBOX/err
# and its exit status to $SANDBOX/rc; the shim's POST log and issue-body log
# start empty.
_copy_case() {
    local rc=0
    : >"${SANDBOX}/post.log"
    : >"${SANDBOX}/body.log"
    POST_LOG="${SANDBOX}/post.log" BODY_LOG="${SANDBOX}/body.log" \
    SELF_UPDATE_RESTARTED=1 SRC_ORG=s DST_ORG=d \
        bash -c 'source "$1"; source "$2"; shift 2; "$@"' _ "$COPY" "${SANDBOX}/copy-shim.sh" "$@" \
        </dev/null >"${SANDBOX}/out" 2>"${SANDBOX}/err" || rc=$?
    printf '%s' "$rc" >"${SANDBOX}/rc"
}

echo "== gh_org_copy.sh: destination milestones are looked up on every page, title passed to jq as data =="
SRC_MS=$(jq -cn --arg t "$QUOTED_TITLE" '[{title:$t,description:null,state:"open",due_on:null}]') \
    _copy_case copy_labels_and_milestones r
assert_eq 0 "$(<"${SANDBOX}/rc")" "copy_labels_and_milestones completes"
assert_eq 0 "$(grep -c '^-X POST /repos/d/r/milestones ' "${SANDBOX}/post.log" || true)" \
    "a milestone already on the destination's second page is not created again"
SRC_MS=$(jq -cn '[{title:"Absent",description:null,state:"open",due_on:null}]') \
    _copy_case copy_labels_and_milestones r
assert_eq 1 "$(grep -c '^-X POST /repos/d/r/milestones ' "${SANDBOX}/post.log" || true)" \
    "a milestone missing from the destination is created once"
_copy_case _capture dest_milestone_number_by_title r "$QUOTED_TITLE"
assert_eq '[2]' "$(<"${SANDBOX}/out")" "dest_milestone_number_by_title finds the quoted title on page 2"
ISSUE_POST_REPLY='{"number":7}' \
    _copy_case _capture create_issue_in_dest r T B '[]' "$QUOTED_TITLE" open 2026-01-01
assert_eq '[7]' "$(<"${SANDBOX}/out")" "create_issue_in_dest prints the new issue's number"
assert_eq 2 "$(jq -r '.milestone' "${SANDBOX}/body.log")" "the copied issue carries the destination milestone's number"

echo "== gh_org_copy.sh: create_issue_in_dest prints the issue number or nothing =="
ISSUE_POST_REPLY='{"message":"Validation Failed"}' ISSUE_POST_RC=1 \
    _copy_case _capture create_issue_in_dest r T B '[]' '' closed 2026-01-01
assert_eq '[]' "$(<"${SANDBOX}/out")" "a failed issue POST prints nothing, the skip signal"
assert_contains "$(<"${SANDBOX}/err")" 'Issue POST failed for d/r: {"message":"Validation Failed"}' \
    "a failed issue POST is reported on stderr with the response"
assert_eq 0 "$(grep -c 'PATCH' "${SANDBOX}/post.log" || true)" "a failed issue POST is not followed by a PATCH"
DST_ISSUES='[{"number":5,"title":"T","created_at":"2026-01-01T10:00:00Z"}]' \
    _copy_case _capture create_issue_in_dest r T B '[]' '' open 2026-01-01
assert_eq '[]' "$(<"${SANDBOX}/out")" "an existing issue prints nothing, the skip signal"
assert_contains "$(<"${SANDBOX}/err")" 'Issue already exists in d/r with same title, skipping (#5)' \
    "the skip message goes to stderr"

echo "== gh_org_copy.sh: a deleted account's PR and its conversation are attributed to @unknown =="
mkdir -p "${SANDBOX}/work"
WORKDIR="${SANDBOX}/work" ISSUE_POST_REPLY='{"number":7}' \
SRC_PULLS='[{"number":1,"title":"T","body":"B","html_url":"u","state":"open","created_at":"2026-01-01T00:00:00Z","merged_at":null,"user":null,"base":{"ref":"main"},"head":{"ref":"f"}}]' \
SRC_PR_ISSUE_COMMENTS='[{"user":null,"created_at":"2026-01-02T00:00:00Z","body":"one"}]' \
SRC_PR_REVIEW_COMMENTS='[{"user":null,"created_at":"2026-01-03T00:00:00Z","body":"two","path":"f.txt","line":3}]' \
SRC_PR_REVIEWS='[{"user":null,"submitted_at":"2026-01-04T00:00:00Z","state":"APPROVED","body":"three"}]' \
    _copy_case copy_prs_as_archival_issues r
assert_eq 3 "$(grep -c '^-X POST /repos/d/r/issues/7/comments .* by @unknown on ' "${SANDBOX}/post.log" || true)" \
    "the issue comment, the review comment and the review all name @unknown"
assert_not_contains "$(<"${SANDBOX}/post.log")" '@null' "no comment names @null"
assert_contains "$(<"${SANDBOX}/body.log")" 'Original author: @unknown' "the archived PR's own author is @unknown"

echo "== gh_org_copy.sh: prepare_workdir =="
mkdir -p "${SANDBOX}/tmp"
fresh=$(TMPDIR="${SANDBOX}/tmp" WORKDIR="" SELF_UPDATE_RESTARTED=1 SRC_ORG=s DST_ORG=d \
    bash -c 'source "$1"; prepare_workdir >/dev/null; printf "%s" "$WORKDIR"' _ "$COPY" </dev/null 2>/dev/null || true)
assert_contains "$fresh" "${SANDBOX}/tmp/org-copy-" "an unset WORKDIR becomes a new directory under TMPDIR"
assert_eq 'yes' "$([[ -d "$fresh" && -O "$fresh" ]] && echo yes || echo no)" "the new directory exists and is yours"
own_rc=0
own=$(WORKDIR="${SANDBOX}/mine/work" SELF_UPDATE_RESTARTED=1 SRC_ORG=s DST_ORG=d \
    bash -c 'source "$1"; prepare_workdir >/dev/null; printf "%s" "$WORKDIR"' _ "$COPY" </dev/null 2>/dev/null) || own_rc=$?
assert_eq "0|${SANDBOX}/mine/work" "${own_rc}|${own}" "a WORKDIR you own is accepted as given"
assert_eq 'yes' "$([[ -d "${SANDBOX}/mine/work" ]] && echo yes || echo no)" "a missing WORKDIR of yours is created"
# A symlink is refused even when its target is yours: -O follows the link, so
# another user's link to a directory of yours would otherwise pass.
ln -s "${SANDBOX}/mine/work" "${SANDBOX}/link"
link_rc=0
link_err=$(WORKDIR="${SANDBOX}/link" SELF_UPDATE_RESTARTED=1 SRC_ORG=s DST_ORG=d \
    bash -c 'source "$1"; prepare_workdir' _ "$COPY" </dev/null 2>&1 >/dev/null) || link_rc=$?
assert_eq 77 "$link_rc" "a symlinked WORKDIR exits 77, even to a directory you own"
assert_contains "$link_err" "WORKDIR is a symlink or not owned by you: ${SANDBOX}/link" "the symlink refusal names the link"
if [[ "$EUID" -ne 0 ]]; then
    # / is root-owned on every platform, and mkdir -p on it is a no-op.
    foreign_rc=0
    foreign_err=$(WORKDIR=/ SELF_UPDATE_RESTARTED=1 SRC_ORG=s DST_ORG=d \
        bash -c 'source "$1"; prepare_workdir' _ "$COPY" </dev/null 2>&1 >/dev/null) || foreign_rc=$?
    assert_eq 77 "$foreign_rc" "a WORKDIR owned by someone else exits 77 (EX_NOPERM)"
    assert_contains "$foreign_err" 'not owned by you: /' "the refusal names the directory"
else
    echo "  skip a WORKDIR owned by someone else: running as root, every directory is yours"
fi

echo "== gh_org_delete_issues.sh: a failed close is counted and the run goes on =="
export REPOS='[{"nameWithOwner":"MyOrg/a","isArchived":false,"visibility":"PUBLIC"},{"nameWithOwner":"MyOrg/b","isArchived":false,"visibility":"PUBLIC"}]'
export ISSUES='[{"number":1,"title":"t","state":"OPEN"},{"number":2,"title":"u","state":"OPEN"}]'
# Exactly one close fails: issue 1 in MyOrg/a.
close_rc=0
close_out=$(SELF_UPDATE_RESTARTED=1 bash -c '
    source "$1"
    sweep_stale_temps() { :; }
    gh() {
        case "$*" in
            "auth status")                return 0 ;;
            "repo list MyOrg "*)          printf "%s\n" "$REPOS" ;;
            "issue list -R MyOrg/"*)      printf "%s\n" "$ISSUES" ;;
            "issue close 1 -R MyOrg/a "*) echo "HTTP 502: Bad Gateway" >&2; return 1 ;;
            "issue close "*)              return 0 ;;
            *)                            return 1 ;;
        esac
    }
    main MyOrg --yes
' _ "$DELETE_ISSUES" </dev/null 2>&1 | _plain) || close_rc=$?
assert_eq 0 "$close_rc" "the run exits 0"
assert_contains "$close_out" "HTTP 502: Bad Gateway" "gh's own error reaches the user"
assert_contains "$close_out" "[PUBLIC] MyOrg/b" "the second repository is processed"
assert_contains "$close_out" "Issues closed: 3" "the other three issues are closed"
assert_contains "$close_out" "Issues failed: 1" "the Summary counts the failed close"

echo "== gh_org_delete_issues.sh: a repository counts as processed only once its issues are listed =="
list_out=$(SELF_UPDATE_RESTARTED=1 bash -c '
    source "$1"
    sweep_stale_temps() { :; }
    gh() {
        case "$*" in
            "auth status")              return 0 ;;
            "repo list MyOrg "*)        printf "%s\n" "$REPOS" ;;
            "issue list -R MyOrg/a "*)  return 1 ;;
            "issue list -R MyOrg/b "*)  printf "%s\n" "$ISSUES" ;;
            *)                          return 1 ;;
        esac
    }
    main MyOrg
' _ "$DELETE_ISSUES" </dev/null 2>&1 | _plain) || true
assert_contains "$list_out" "Repositories processed: 1" "the listed repository is processed"
assert_contains "$list_out" "Repositories skipped: 1 (issues could not be listed)" "the unlistable repository is skipped"

echo "== usage errors exit 64, --help exits 0 =="
# Run as child processes, because show_help prints the script's own header from
# "$0". Each runs a copy in the sandbox with a failing gh first on PATH: if
# parse_arguments ever let a bad argument through, main's stale-temp sweep would
# act on the sandbox instead of github/, and its first gh call would fail here
# instead of reaching the real gh.
mkdir -p "${SANDBOX}/run" "${SANDBOX}/bin"
cp "$DELETE_REPOS" "$DELETE_ISSUES" "${SANDBOX}/run/"
printf '#!/usr/bin/env bash\nexit 1\n' >"${SANDBOX}/bin/gh"
chmod +x "${SANDBOX}/bin/gh"
_usage_rc() {
    local status=0
    PATH="${SANDBOX}/bin:${PATH}" SELF_UPDATE_RESTARTED=1 "${SANDBOX}/run/$1" "${@:2}" \
        </dev/null >/dev/null 2>&1 || status=$?
    printf '%s' "$status"
}
assert_eq 64 "$(_usage_rc gh_org_delete_repos.sh OldCo --yse)" "gh_org_delete_repos.sh: an unknown option exits 64"
assert_eq 64 "$(_usage_rc gh_org_delete_repos.sh OldCo)" "gh_org_delete_repos.sh: neither --all nor a repository exits 64"
assert_eq 64 "$(_usage_rc gh_org_delete_repos.sh OldCo --all repo1)" "gh_org_delete_repos.sh: --all with a repository exits 64"
assert_eq 0 "$(_usage_rc gh_org_delete_repos.sh --help)" "gh_org_delete_repos.sh: --help exits 0"
assert_eq 64 "$(_usage_rc gh_org_delete_issues.sh OldCo --yse)" "gh_org_delete_issues.sh: an unknown option exits 64"
assert_eq 0 "$(_usage_rc gh_org_delete_issues.sh --help)" "gh_org_delete_issues.sh: --help exits 0"
assert_contains "$(PATH="${SANDBOX}/bin:${PATH}" SELF_UPDATE_RESTARTED=1 "${SANDBOX}/run/gh_org_delete_repos.sh" OldCo --yse </dev/null 2>&1 >/dev/null || true)" \
    'Unknown argument: --yse' "the unknown option is named on stderr"

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
