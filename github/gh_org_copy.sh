#!/usr/bin/env bash

# gh_org_copy.sh - Copy GitHub organization repositories without forking
#
# This script provides comprehensive organization migration capabilities including:
# - Mirrors git refs (branches/tags) and Git LFS objects
# - Copies wiki repositories
# - Recreates labels and milestones
# - Copies issues with comments
# - Archives PRs as issues with review comments, reviews, and issue comments
# - Copies discussions with comments via GraphQL (best-effort category mapping)
#
# Requirements:
#   - gh CLI ≥ 2.30 (GitHub command-line tool)
#   - jq (JSON processor)
#   - git (version control)
#   - git-lfs (optional, for LFS object support)
#
# Authentication:
#   Run 'gh auth login' first. PAT must have the following scopes:
#     Source Org: repo, read:discussion
#     Dest Org:   repo, write:discussion, admin:org (for creating repos)
#
# Usage:
#   SRC_ORG="OldOrg" DST_ORG="NewOrg" ./gh_org_copy.sh
#   SRC_ORG="OldOrg" DST_ORG="NewOrg" THROTTLE=2 ./gh_org_copy.sh
#
# Environment Variables:
#   SRC_ORG            - Source organization name (required)
#   DST_ORG            - Destination organization name (required)
#   WORKDIR            - Working directory for temporary clones (default: /tmp/org-copy-...)
#   THROTTLE           - Seconds to sleep between API calls (default: 0.3)
#   LABEL_ARCHIVED_PR  - Label name for archived PRs (default: archived-pr)
#
# Note: This is a comprehensive migration tool. Always test with a small
#       subset of repositories first to verify the process.

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Configuration variables
readonly SRC_ORG="${SRC_ORG:-}"
readonly DST_ORG="${DST_ORG:-}"
readonly WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}/org-copy-${SRC_ORG}-to-${DST_ORG}}"
readonly THROTTLE="${THROTTLE:-0.3}"
readonly LABEL_ARCHIVED_PR="${LABEL_ARCHIVED_PR:-archived-pr}"

# Global counters
TOTAL_REPOS_PROCESSED=0
TOTAL_REPOS_CREATED=0
TOTAL_WIKIS_COPIED=0
TOTAL_LABELS_COPIED=0
TOTAL_MILESTONES_COPIED=0
TOTAL_ISSUES_COPIED=0
TOTAL_ISSUES_SKIPPED=0
TOTAL_ISSUE_COMMENTS_COPIED=0
TOTAL_PRS_ARCHIVED=0
TOTAL_PR_COMMENTS_COPIED=0
TOTAL_DISCUSSIONS_COPIED=0
TOTAL_DISCUSSION_COMMENTS_COPIED=0

# ============================================================================
# Output Functions
# ============================================================================

print_info() {
    echo -e "${BLUE}[   INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[  ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}[$(date +'%H:%M:%S')] $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_step() {
    echo -e "${BLUE}  →${NC} $1"
}

# ============================================================================
# Validation Functions
# ============================================================================

# Validate configuration
validate_config() {
    if [[ -z "$SRC_ORG" ]]; then
        print_error "SRC_ORG environment variable is required"
        echo ""
        echo "Usage: SRC_ORG=\"OldOrg\" DST_ORG=\"NewOrg\" $0"
        exit 1
    fi

    if [[ -z "$DST_ORG" ]]; then
        print_error "DST_ORG environment variable is required"
        echo ""
        echo "Usage: SRC_ORG=\"OldOrg\" DST_ORG=\"NewOrg\" $0"
        exit 1
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}Configuration:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Source organization:   ${SRC_ORG}"
    echo "Destination org:       ${DST_ORG}"
    echo "Working directory:     ${WORKDIR}"
    echo "API throttle:          ${THROTTLE}s"
    echo "Archived PR label:     ${LABEL_ARCHIVED_PR}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Check for required dependencies
check_dependencies() {
    local missing_deps=()

    if ! command -v gh >/dev/null 2>&1; then
        missing_deps+=("gh")
    fi

    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi

    if ! command -v git >/dev/null 2>&1; then
        missing_deps+=("git")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        echo "Installation commands:"
        echo "  macOS:    brew install gh jq git"
        echo "  Debian:   apt install gh jq git"
        echo "  RHEL:     yum install gh jq git"
        echo ""
        exit 1
    fi

    if ! command -v git-lfs >/dev/null 2>&1; then
        print_warning "git-lfs not installed; LFS objects will NOT be pushed"
        print_info "To install: brew install git-lfs (macOS) or apt install git-lfs (Debian)"
        echo ""
    fi

    print_success "All required dependencies are available"
}

# Verify GitHub authentication
verify_auth() {
    print_info "Verifying GitHub CLI authentication..."
    if ! gh auth status >/dev/null 2>&1; then
        print_error "GitHub CLI not authenticated"
        echo ""
        echo "Please run: gh auth login"
        echo ""
        echo "Required token scopes:"
        echo "  Source Org: repo, read:discussion"
        echo "  Dest Org:   repo, write:discussion, admin:org"
        echo ""
        exit 1
    fi

    local GH_TOKEN
    GH_TOKEN="$(gh auth token)"
    export GH_TOKEN

    print_success "GitHub CLI authenticated"
}

# ============================================================================
# GitHub API Helper Functions
# ============================================================================

# GitHub API wrapper with throttling for mutating calls
gh_post() {
    sleep "$THROTTLE"
    gh api "$@"
}

# GitHub GraphQL API wrapper
gh_gql() {
    gh api graphql "$@"
}

# ============================================================================
# Repository Management Functions
# ============================================================================

# Create destination repository if it doesn't exist and return visibility
create_dest_repo() {
    local name="$1"
    local visibility="$2"

    # Map "internal" (source) → "private" (destination) for portability
    [[ "$visibility" == "internal" ]] && visibility="private"

    if gh api -H "Accept: application/vnd.github+json" "/repos/${DST_ORG}/${name}" >/dev/null 2>&1; then
        echo "$visibility"
        return 0
    fi

    print_step "Creating repository ${DST_ORG}/${name} (${visibility})"
    gh repo create "${DST_ORG}/${name}" "--${visibility}" >/dev/null
    ((TOTAL_REPOS_CREATED++)) || true

    # Enable Discussions and set default branch
    gh repo edit "${DST_ORG}/${name}" --enable-discussions --default-branch development >/dev/null 2>&1 || true
    echo "$visibility"
}

# Push a mirror of git refs (branches + tags) and all LFS objects
mirror_git_and_lfs() {
    local name="$1"
    local https_src="https://github.com/${SRC_ORG}/${name}.git"
    local https_dst="https://${GH_TOKEN}@github.com/${DST_ORG}/${name}.git"
    local gd="${WORKDIR}/${name}.git"

    rm -rf "$gd"
    print_step "Cloning (mirror) ${SRC_ORG}/${name}"
    git clone --mirror "$https_src" "$gd" 2>/dev/null

    # Strip PR/remote/replace/original namespaces to avoid push rejection
    print_step "Stripping read-only ref namespaces"
    git --git-dir="$gd" for-each-ref --format='delete %(refname)' \
        'refs/pull/*' 'refs/pull/*/*' 'refs/remotes/*' 'refs/replace/*' 'refs/original/*' \
        | git --git-dir="$gd" update-ref --stdin

    print_step "Pushing (mirror) to ${DST_ORG}/${name}"
    if ! git --git-dir="$gd" push --mirror "$https_dst" 2>/dev/null; then
        print_error "Git push --mirror failed for ${name}"
        rm -rf "$gd"
        return 1
    fi

    if command -v git-lfs >/dev/null 2>&1; then
        print_step "Pushing LFS objects for ${name}"
        (cd "$gd" && git lfs fetch --all 2>/dev/null || true)
        (cd "$gd" && git lfs push --all "$https_dst" 2>/dev/null || true)
    fi
    rm -rf "$gd"
}

# Copy wiki repository if it exists
copy_wiki() {
    local name="$1"
    local src_wiki="https://github.com/${SRC_ORG}/${name}.wiki.git"
    local dst_wiki="https://${GH_TOKEN}@github.com/${DST_ORG}/${name}.wiki.git"
    local wd="${WORKDIR}/${name}.wiki.git"

    if git ls-remote "$src_wiki" &>/dev/null; then
        print_step "Copying wiki for ${name}"
        gh repo edit "${DST_ORG}/${name}" --enable-wiki >/dev/null 2>&1 || true
        rm -rf "$wd"
        if git clone --bare "$src_wiki" "$wd" >/dev/null 2>&1; then
            if git --git-dir="$wd" push --mirror "$dst_wiki" 2>/dev/null; then
                ((TOTAL_WIKIS_COPIED++)) || true
            else
                print_warning "Wiki push failed for ${name}"
            fi
        else
            print_warning "Wiki clone failed for ${name}"
        fi
        rm -rf "$wd"
    else
        print_step "No wiki detected for ${name}"
    fi
}

# ============================================================================
# Labels, Milestones, and Metadata Functions
# ============================================================================

# Ensure label exists in destination repository
ensure_label() {
    local repo="$1"
    local label="$2"
    local color="$3"
    local desc="$4"

    gh api -H "Accept: application/vnd.github+json" "/repos/${DST_ORG}/${repo}/labels/${label}" >/dev/null 2>&1 && return 0
    if gh_post -X POST "/repos/${DST_ORG}/${repo}/labels" -f name="$label" -f color="$color" -f description="${desc}" >/dev/null 2>&1; then
        ((TOTAL_LABELS_COPIED++)) || true
    fi
}

# Copy labels and milestones from source to destination
copy_labels_and_milestones() {
    local name="$1"

    print_step "Copying labels for ${name}"
    gh api --paginate "/repos/${SRC_ORG}/${name}/labels?per_page=100" \
        --jq '.[] | [.name,.color,(.description//"")] | @tsv' \
    | while IFS=$'\t' read -r LNAME LCOLOR LDESC; do
        ensure_label "$name" "$LNAME" "$LCOLOR" "$LDESC"
    done

    print_step "Copying milestones for ${name}"
    # Build map of destination title → destination number
    declare -A DST_MS=()
    # Create any missing milestones by title
    gh api --paginate "/repos/${SRC_ORG}/${name}/milestones?state=all&per_page=100" \
        --jq '.[] | @base64' | while read -r row; do
        _j() { echo "$row" | base64 --decode | jq -r "$1"; }
        local TITLE=$(_j '.title')
        local DESC=$(_j '.description // empty')
        local STATE=$(_j '.state')
        local DUE=$(_j '.due_on // empty')

        # Check if milestone already exists
        if ! gh api "/repos/${DST_ORG}/${name}/milestones?state=all&per_page=100" \
            --jq ".[] | select(.title==\"$TITLE\") | .number" | grep -q .; then
            # Create milestone
            args=(-X POST "/repos/${DST_ORG}/${name}/milestones" -f title="$TITLE")
            [[ -n "$DESC" ]] && args+=(-f description="$DESC")
            [[ -n "$DUE"  ]] && args+=(-f due_on="$DUE")
            if gh_post "${args[@]}" >/dev/null 2>&1; then
                ((TOTAL_MILESTONES_COPIED++)) || true
            fi
        fi
    done
}

# ============================================================================
# Issue Management Functions
# ============================================================================

# Helper: find destination milestone number by title
dest_milestone_number_by_title() {
    local name="$1"
    local title="$2"
    gh api "/repos/${DST_ORG}/${name}/milestones?state=all&per_page=100" \
        --jq -- "map(select(.title == \$t) | .number) | first" --raw-field t="$title"
}

# Return the number of an existing issue (not PR) with the exact title in destination,
# or "" if none. Handles pagination and empty pages without jq errors.
exists_issue_number_by_title() {
    local repo="$1"
    local title="$2"
    local created="$3"

    # List all issues (state=all), paginate, and filter:
    # - .[]? : safe iterate (no error on null)
    # - exclude PRs: select(has("pull_request")|not)
    # - exact title match (case-sensitive) and creation date
    gh api --paginate "/repos/${DST_ORG}/${repo}/issues?state=all&per_page=100" 2>/dev/null \
    | jq -r --arg t "$title" --arg d "$created" '
        .[]?
        | select(has("pull_request")|not)
        | select(.title == $t and (.created_at|split("T")[0]) == $d)
        | .number
      ' | head -n1
}

# Create issue in destination; echoes NEW_ISSUE_NUMBER
# Implements idempotency by checking for duplicate titles with same creation date
# Returns empty string if issue already exists (skips creation)
create_issue_in_dest() {
    local name="$1"
    local title="$2"
    local body="$3"
    local labels_json="$4"
    local milestone_title="$5"
    local state="$6"
    local created="$7"

    # Idempotency: skip if exact title exists already
    local existing
    existing="$(exists_issue_number_by_title "$name" "$title" "$created" || true)"
    if [[ -n "$existing" ]]; then
        print_info "Issue already exists in ${DST_ORG}/${name} with same title, skipping (#${existing})"
        ((TOTAL_ISSUES_SKIPPED++)) || true
        echo "" # Signal "skipped" to caller
        return 0
    fi

    # Resolve milestone number in destination (if any)
    local msnum=""
    if [[ -n "$milestone_title" ]]; then
        msnum="$(dest_milestone_number_by_title "$name" "$milestone_title" || true)"
    fi

    # Build JSON body with jq (correct conditional, no ternary)
    local json
    json="$(jq -n \
        --arg t "$title" \
        --arg b "$body" \
        --argjson lbls "$labels_json" \
        --arg msnum "$msnum" '
        {title:$t, body:$b, labels:$lbls}
        + ( if ($msnum|length) > 0
            then { milestone: ($msnum|tonumber) }
            else {}
          end )
      ')"

    # Create issue
    local resp
    resp="$(printf '%s' "$json" \
           | gh api -H "Accept: application/vnd.github+json" \
                   -X POST "/repos/${DST_ORG}/${name}/issues" --input -)"

    local newnum
    newnum="$(printf '%s' "$resp" | jq -r '.number')"
    ((TOTAL_ISSUES_COPIED++)) || true

    # Close it if source was closed
    if [[ "$state" == "closed" ]]; then
        gh api -H "Accept: application/vnd.github+json" \
               -X PATCH "/repos/${DST_ORG}/${name}/issues/${newnum}" \
               -f state=closed >/dev/null
    fi

    echo "$newnum"
}

# Post comment to an issue
post_issue_comment() {
    local name="$1"
    local num="$2"
    local body="$3"
    if gh_post -X POST "/repos/${DST_ORG}/${name}/issues/${num}/comments" \
        -f body="$body" >/dev/null; then
        ((TOTAL_ISSUE_COMMENTS_COPIED++)) || true
    fi
}

# Copy issues (excluding PRs) from source to destination
copy_issues() {
    local name="$1"
    print_step "Copying issues for ${name}"

    # Page through all issues from source (includes PRs; we filter those out)
    gh api --paginate "/repos/${SRC_ORG}/${name}/issues?state=all&per_page=100" 2>/dev/null \
    | jq -c '
        .[]?
        | select(has("pull_request")|not)
        | {
            number, title,
            body: (.body // ""),
            html_url, state,
            author: (.user.login // "unknown"),
            created_at,
            milestone_title: (.milestone.title // ""),
            labels: ((.labels // []) | map(.name))
          }
      ' \
    | while IFS= read -r row; do
        # Extract fields
        local NUM TITLE BODY URL STATE AUTHOR CREATED MIL_TITLE
        local LABELS_JSON

        TITLE=$(jq -r '.title'        <<<"$row")
        BODY=$(jq  -r '.body'         <<<"$row")
        URL=$(jq   -r '.html_url'     <<<"$row")
        STATE=$(jq -r '.state'        <<<"$row")
        AUTHOR=$(jq -r '.author'      <<<"$row")
        CREATED=$(jq -r '.created_at' <<<"$row")
        MIL_TITLE=$(jq -r '.milestone_title' <<<"$row")
        LABELS_JSON=$(jq -c '.labels' <<<"$row")

        # Normalize labels
        [[ -z "$LABELS_JSON" || "$LABELS_JSON" == "null" ]] && LABELS_JSON='[]'

        local NEWBODY NEWNUM
        NEWBODY="(Copied from ${URL}\nOriginal author: @${AUTHOR} • Opened: ${CREATED})\n\n${BODY}"

        # Create issue (function returns "" if duplicate title exists)
        NEWNUM="$(create_issue_in_dest "$name" "$TITLE" "$NEWBODY" "$LABELS_JSON" "$MIL_TITLE" "$STATE" "$CREATED")"

        # If we skipped (duplicate), don't try to post comments
        if [[ -z "$NEWNUM" ]]; then
            continue
        fi

        # Copy comments for this issue
        local num
        num=$(jq -r '.number' <<<"$row")
        gh api --paginate "/repos/${SRC_ORG}/${name}/issues/${num}/comments?per_page=100" 2>/dev/null \
        | jq -c '.[]? | {author:(.user.login // "unknown"), created_at, body:(.body // "")}' \
        | while IFS= read -r crow; do
            local CAUTH CDATE CBODY CMT
            CAUTH=$(jq -r '.author'      <<<"$crow")
            CDATE=$(jq -r '.created_at'  <<<"$crow")
            CBODY=$(jq -r '.body'        <<<"$crow")
            CMT="**(Original comment by @${CAUTH} on ${CDATE})**\n\n${CBODY}"
            post_issue_comment "$name" "$NEWNUM" "$CMT"
        done
    done
}

# ============================================================================
# Pull Request Archive Functions
# ============================================================================

# Copy PRs as archival issues (with merged review content)
copy_prs_as_archival_issues() {
    local name="$1"
    print_step "Archiving PRs as issues for ${name}"

    # Ensure archival label exists
    ensure_label "$name" "$LABEL_ARCHIVED_PR" "6e5494" "Archival of original Pull Request"

    gh api --paginate "/repos/${SRC_ORG}/${name}/pulls?state=all&per_page=100" \
        --jq '.[] | @base64' \
    | while read -r row; do
        _j() { echo "$row" | base64 --decode | jq -r "$1"; }
        local PRNUM=$(_j '.number')
        local TITLE=$(_j '.title')
        local BODY=$(_j '.body // ""')
        local URL=$(_j '.html_url')
        local STATE=$(_j '.state')
        local CREATED=$(_j '.created_at')
        local MRGD=$(_j '.merged_at // ""')
        local USER=$(_j '.user.login')
        local BASE=$(_j '.base.ref')
        local HEAD=$(_j '.head.ref')

        local ITITLE="[PR #${PRNUM}] ${TITLE}"
        local HEADER="**Archived Pull Request** — copied from ${URL}\n\n- Original author: @${USER}\n- State: ${STATE}\n- Merged at: ${MRGD}\n- Base: \`${BASE}\`\n- Head: \`${HEAD}\`\n"
        local IBODY="${HEADER}\n---\n${BODY}"
        local LABELS_JSON="$(jq -cn --arg a "$LABEL_ARCHIVED_PR" '[$a]')"

        local NEWNUM
        NEWNUM="$(create_issue_in_dest "$name" "$ITITLE" "$IBODY" "$LABELS_JSON" "" "$STATE" "$CREATED")"

        # If skipped (duplicate archival issue already exists), don't add comments again
        if [[ -z "$NEWNUM" ]]; then
            continue
        fi
        
        ((TOTAL_PRS_ARCHIVED++)) || true

        # Collect PR conversation pieces:
        # 1) PR issue-comments
        gh api --paginate "/repos/${SRC_ORG}/${name}/issues/${PRNUM}/comments?per_page=100" \
            --jq '.[] | {kind:"issue_comment",author:.user.login,created_at,body}' >"${WORKDIR}/ic.json"

        # 2) Review comments (diff comments)
        gh api --paginate "/repos/${SRC_ORG}/${name}/pulls/${PRNUM}/comments?per_page=100" \
            --jq '.[] | {kind:"review_comment",author:.user.login,created_at,body:(.body//"") + "\n\n(File: \(.path), Line: \(.original_line // .line // 0))"}' >"${WORKDIR}/rc.json"

        # 3) Reviews
        gh api --paginate "/repos/${SRC_ORG}/${name}/pulls/${PRNUM}/reviews?per_page=100" \
            --jq '.[] | {kind:"review",author:.user.login,created_at,body:("[Review state: " + .state + "]\n\n" + (.body//""))}' >"${WORKDIR}/rv.json"

        # Merge and sort chronologically
        jq -s 'add | sort_by(.created_at)' "${WORKDIR}/ic.json" "${WORKDIR}/rc.json" "${WORKDIR}/rv.json" 2>/dev/null \
        | jq -c '.[]' | while read -r c; do
            local KIND=$(echo "$c" | jq -r '.kind')
            local AUTH=$(echo "$c" | jq -r '.author')
            local DATE=$(echo "$c" | jq -r '.created_at')
            local BODY=$(echo "$c" | jq -r '.body')
            local CMT="**(${KIND//_/ } by @${AUTH} on ${DATE})**\n\n${BODY}"
            if post_issue_comment "$name" "$NEWNUM" "$CMT"; then
                ((TOTAL_PR_COMMENTS_COPIED++)) || true
            fi
        done || true
    done
}

# ============================================================================
# Discussion Functions
# ============================================================================

# Copy discussions (best-effort; requires categories enabled on dest repo)
# Note: This uses GitHub's GraphQL API to copy discussions with their comments.
# If destination repo has no discussion categories enabled, this will skip.
copy_discussions() {
    local name="$1"
    print_step "Copying discussions for ${name}"

    # GraphQL query to fetch discussions and categories from both source and destination
    local q='
    query($so:String!,$sr:String!,$do:String!,$dr:String!,$after:String){
      src: repository(owner:$so,name:$sr){
        id
        discussions(first:50, after:$after, orderBy:{field:CREATED_AT,direction:ASC}){
          pageInfo{ hasNextPage endCursor }
          nodes{
            number title url body createdAt
            category{ name }
            comments(first:100){
              pageInfo{ hasNextPage endCursor }
              nodes{ author{login} createdAt body }
            }
          }
        }
      }
      dst: repository(owner:$do,name:$dr){
        id
        discussionCategories(first:25){ nodes{ id name } }
      }
    }'

    # Build dest category map (name -> id)
    local dstCatsJSON
    dstCatsJSON="$(gh_gql -f query="$q" -F so="$SRC_ORG" -F sr="$name" -F do="$DST_ORG" -F dr="$name" -F after="")" || {
        print_warning "GraphQL fetch failed for ${name} (likely no Discussions)"
        return
    }
    local dstCats
    dstCats="$(echo "$dstCatsJSON" | jq -c '.data.dst.discussionCategories.nodes')" || dstCats="[]"
    local hasCats
    hasCats="$(echo "$dstCats" | jq 'length>0')" || hasCats="false"
    if [[ "$hasCats" != "true" ]]; then
        print_warning "Destination repo ${DST_ORG}/${name} has no discussion categories; skipping discussions"
        return
    fi

    # Page through discussions
    local cursor=""
    local hasNext="true"
    while [[ "$hasNext" == "true" ]]; do
        local page
        page="$(gh_gql -f query="$q" -F so="$SRC_ORG" -F sr="$name" -F do="$DST_ORG" -F dr="$name" -F after="$cursor")" || break
        hasNext="$(echo "$page" | jq -r '.data.src.discussions.pageInfo.hasNextPage')"
        cursor="$(echo "$page"  | jq -r '.data.src.discussions.pageInfo.endCursor')"

        echo "$page" | jq -c '.data.src.discussions.nodes[]' | while read -r d; do
            local DTITLE DBODY DURL DCAT
            DTITLE="$(echo "$d" | jq -r '.title')"
            DBODY="$(echo "$d" | jq -r '.body // ""')"
            DURL="$(echo "$d" | jq -r '.url')"
            DCAT="$(echo "$d" | jq -r '.category.name')"
            local HEADER="(Copied from ${DURL})"
            local BODY="${HEADER}\n\n${DBODY}"

            # Resolve category id (name match or first)
            local CATID
            CATID="$(echo "$dstCats" | jq -r --arg n "$DCAT" 'first(.[] | select(.name==$n) | .id) // first(.[] | .id)')"

            # Create discussion
            local dstRepoId; dstRepoId="$(echo "$page" | jq -r '.data.dst.id')"
            local m='mutation($rid:ID!,$cid:ID!,$title:String!,$body:String!){
              createDiscussion(input:{repositoryId:$rid,categoryId:$cid,title:$title,body:$body}){
                discussion{ id number }
              }
            }'
            local created
            created="$(gh_gql -f query="$m" -F rid="$dstRepoId" -F cid="$CATID" -F title="$DTITLE" -F body="$BODY")" || { print_warning "Failed to create discussion"; continue; }
            local newDid; newDid="$(echo "$created" | jq -r '.data.createDiscussion.discussion.id')"
            ((TOTAL_DISCUSSIONS_COPIED++)) || true

            # Comments (single page or more)
            # First page from current node
            echo "$d" | jq -c '.comments.nodes[]?' | while read -r c; do
                local CAUTH=$(echo "$c" | jq -r '.author.login // "unknown"')
                local CDAT=$(echo "$c"  | jq -r '.createdAt')
                local CBOD=$(echo "$c"  | jq -r '.body // ""')
                local CBODY="**(Original comment by @${CAUTH} on ${CDAT})**\n\n${CBOD}"
                local cm='mutation($id:ID!,$body:String!){ addDiscussionComment(input:{discussionId:$id, body:$body}){ comment{ id } } }'
                if gh_gql -f query="$cm" -F id="$newDid" -F body="$CBODY" >/dev/null 2>&1; then
                    ((TOTAL_DISCUSSION_COMMENTS_COPIED++)) || true
                fi
                sleep "$THROTTLE"
            done
            # Additional comment pages not handled here for simplicity (rare for most repos).
        done
    done
}

# ============================================================================
# Main Processing Functions
# ============================================================================

# Process all repositories in the source organization
process_repositories() {
    print_info "Listing repositories in ${SRC_ORG}..."
    echo ""

    gh api --paginate "/orgs/${SRC_ORG}/repos?per_page=100" \
        --jq '.[] | {name,visibility,archived,has_wiki} | @base64' \
    | while read -r row; do
        _j() { echo "$row" | base64 --decode | jq -r "$1"; }
        NAME=$(_j '.name')
        VIS=$(_j '.visibility')
        ARCH=$(_j '.archived')
        HAS_WIKI=$(_j '.has_wiki')

        print_header "Processing repository: ${NAME}"
        ((TOTAL_REPOS_PROCESSED++)) || true
        create_dest_repo "$NAME" "$VIS" >/dev/null

        mirror_git_and_lfs "$NAME"

        if [[ "$HAS_WIKI" == "true" ]]; then
            copy_wiki "$NAME"
        fi

        copy_labels_and_milestones "$NAME"
        copy_issues "$NAME"
        copy_prs_as_archival_issues "$NAME"
        copy_discussions "$NAME"

        if [[ "$ARCH" == "true" ]]; then
            print_warning "Source repository is archived; destination remains unarchived by default"
        fi
    done
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}GitHub Organization Copy Tool${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    validate_config
    check_dependencies
    verify_auth

    # Create working directory
    mkdir -p "$WORKDIR"
    print_success "Working directory created: ${WORKDIR}"
    echo ""

    process_repositories

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}Migration Summary${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Repositories processed:        ${TOTAL_REPOS_PROCESSED}"
    echo "Repositories created:          ${TOTAL_REPOS_CREATED}"
    echo "Wikis copied:                  ${TOTAL_WIKIS_COPIED}"
    echo "Labels copied:                 ${TOTAL_LABELS_COPIED}"
    echo "Milestones copied:             ${TOTAL_MILESTONES_COPIED}"
    echo ""
    echo "Issues copied:                 ${TOTAL_ISSUES_COPIED}"
    echo "Issues skipped (existing):     ${TOTAL_ISSUES_SKIPPED}"
    echo "Issue comments copied:         ${TOTAL_ISSUE_COMMENTS_COPIED}"
    echo ""
    echo "PRs archived as issues:        ${TOTAL_PRS_ARCHIVED}"
    echo "PR comments copied:            ${TOTAL_PR_COMMENTS_COPIED}"
    echo ""
    echo "Discussions copied:            ${TOTAL_DISCUSSIONS_COPIED}"
    echo "Discussion comments copied:    ${TOTAL_DISCUSSION_COMMENTS_COPIED}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Migration complete!"
    print_info "Please validate the migrated repositories and compare counts"
    echo ""
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
