#!/usr/bin/env bash
# org_copy.sh — Copy repos from one GitHub org to another WITHOUT forking.
# - Mirrors git refs (branches/tags)
# - Pushes Git LFS objects
# - Copies wiki repos
# - Recreates labels & milestones
# - Copies issues (+ comments)
# - Archives PRs as issues (+ review comments/reviews/issue-comments)
# - Copies discussions (+ comments) via GraphQL (best-effort category mapping)
# ------------------------------------------------------------------------------------
# Requirements: gh ≥ 2.30, jq, git, git-lfs
# Auth: `gh auth login` (PAT must allow repo/admin on both orgs)
# ------------------------------------------------------------------------------------
# Example:
# SRC_ORG="OldOrg-Name" DST_ORG="NewOrg-Name" THROTTLE=2 ./gh_org_copy.sh
# ------------------------------------------------------------------------------------

set -euo pipefail

# --- Configuration --------------------------------------------------------------
SRC_ORG="${SRC_ORG:-OldCo}"
DST_ORG="${DST_ORG:-NewCo}"
WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}/org-copy-$SRC_ORG-to-$DST_ORG}"
THROTTLE="${THROTTLE:-0.3}"          # seconds to sleep between mutating API calls
LABEL_ARCHIVED_PR="${LABEL_ARCHIVED_PR:-archived-pr}"

mkdir -p "$WORKDIR"

# --- Dependency checks ----------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need gh
need jq
need git
if ! command -v git-lfs >/dev/null 2>&1; then
  echo "WARNING: git-lfs not installed; LFS objects will NOT be pushed." >&2
fi

# Verify auth (non-fatal if using env tokens, but good sanity check)
if ! gh auth status >/dev/null 2>&1; then
  echo "Run 'gh auth login' first." >&2
  exit 1
fi

GH_TOKEN="$(gh auth token)"

# --- Helpers --------------------------------------------------------------------
sayHeader() { printf "\n\033[1;34m[%s] %s\033[0m\n" "$(date +'%H:%M:%S')" "$*"; }
say() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\n\033[1;31m[err]\033[0m  %s\n" "$*"; }

# gh api wrapper with light throttling for mutating calls
gh_post() { sleep "$THROTTLE"; gh api "$@"; }
gh_gql()  { gh api graphql "$@"; }

# Create repo if missing and return visibility
create_dest_repo() {
  local name="$1" visibility="$2"
  # Map "internal" (src) → "private" (dst) for portability
  [[ "$visibility" == "internal" ]] && visibility="private"

  if gh api -H "Accept: application/vnd.github+json" "/repos/${DST_ORG}/${name}" >/dev/null 2>&1; then
    echo "$visibility"
    return 0
  fi

  say "Creating ${DST_ORG}/${name} (${visibility})"
  gh repo create "${DST_ORG}/${name}" "--${visibility}" >/dev/null
  # enable Discussions up front
  gh repo edit  "${DST_ORG}/${name}" --enable-discussions --default-branch development >/dev/null || true
  echo "$visibility"
}

# Push a mirror of git refs (branches+tags) and all LFS objects
mirror_git_and_lfs() {
  local name="$1"
  local https_src="https://github.com/${SRC_ORG}/${name}.git"
  local https_dst="https://${GH_TOKEN}@github.com/${DST_ORG}/${name}.git"
  local gd="${WORKDIR}/${name}.git"

  rm -rf "$gd"
  say "Cloning (mirror) ${SRC_ORG}/${name}"
  git clone --mirror "$https_src" "$gd"

  # Strip PR/remote/replace/original namespaces so push won’t be rejected
  say "Stripping read-only ref namespaces"
  git --git-dir="$gd" for-each-ref --format='delete %(refname)' \
    'refs/pull/*' 'refs/pull/*/*' 'refs/remotes/*' 'refs/replace/*' 'refs/original/*' \
    | git --git-dir="$gd" update-ref --stdin

  say "Pushing (mirror) to ${DST_ORG}/${name}"
  git --git-dir="$gd" push --mirror "$https_dst" || {
    err "git push --mirror failed for ${name}"; return 1;
  }

  if command -v git-lfs >/dev/null 2>&1; then
    say "Pushing LFS objects for ${name}"
    (cd "$gd" && git lfs fetch --all || true)
    (cd "$gd" && git lfs push --all "$https_dst" || true)
  fi
  rm -rf "$gd"
}

# Copy wiki repo if it exists
copy_wiki() {
  local name="$1"
  local src_wiki="https://github.com/${SRC_ORG}/${name}.wiki.git"
  local dst_wiki="https://${GH_TOKEN}@github.com/${DST_ORG}/${name}.wiki.git"
  local wd="${WORKDIR}/${name}.wiki.git"

  if git ls-remote "$src_wiki" &>/dev/null; then
    say "Copying wiki for ${name}"
    gh repo edit "${DST_ORG}/${name}" --enable-wiki >/dev/null || true
    rm -rf "$wd"
    git clone --bare "$src_wiki" "$wd" >/dev/null 2>&1 || { warn "wiki clone failed for ${name}"; return; }
    git --git-dir="$wd" push --mirror "$dst_wiki" || warn "wiki push failed for ${name}"
    rm -rf "$wd"
  else
    warn "No wiki detected for ${name}"
  fi
}

# Ensure label exists in dest
ensure_label() {
  local repo="$1" label="$2" color="$3" desc="$4"
  gh api -H "Accept: application/vnd.github+json" "/repos/${DST_ORG}/${repo}/labels/${label}" >/dev/null 2>&1 && return 0
  gh_post -X POST "/repos/${DST_ORG}/${repo}/labels" -f name="$label" -f color="$color" -f description="${desc}" >/dev/null 2>&1 || true
}

# Copy labels & milestones
copy_labels_and_milestones() {
  local name="$1"
  say "Copying labels for ${name}"
  gh api --paginate "/repos/${SRC_ORG}/${name}/labels?per_page=100" \
    --jq '.[] | [.name,.color,(.description//"")] | @tsv' \
  | while IFS=$'\t' read -r LNAME LCOLOR LDESC; do
      ensure_label "$name" "$LNAME" "$LCOLOR" "$LDESC"
    done

  say "Copying milestones for ${name}"
  # Build map dest_title -> dest_number
  declare -A DST_MS=()
  # Create any missing milestones by title
  gh api --paginate "/repos/${SRC_ORG}/${name}/milestones?state=all&per_page=100" \
    --jq '.[] | @base64' | while read -r row; do
      _j() { echo "$row" | base64 --decode | jq -r "$1"; }
      local TITLE=$(_j '.title')
      local DESC=$(_j '.description // empty')
      local STATE=$(_j '.state')
      local DUE=$(_j '.due_on // empty')

      # Does it exist?
      if ! gh api "/repos/${DST_ORG}/${name}/milestones?state=all&per_page=100" \
           --jq ".[] | select(.title==\"$TITLE\") | .number" | grep -q .; then
        # Create
        args=(-X POST "/repos/${DST_ORG}/${name}/milestones" -f title="$TITLE")
        [[ -n "$DESC" ]] && args+=(-f description="$DESC")
        [[ -n "$DUE"  ]] && args+=(-f due_on="$DUE")
        gh_post "${args[@]}" >/dev/null 2>&1 || true
      fi
    done
}

# Helper: find dest milestone number by title
dest_milestone_number_by_title() {
  local name="$1" title="$2"
  gh api "/repos/${DST_ORG}/${name}/milestones?state=all&per_page=100" \
    --jq -- "map(select(.title == \$t) | .number) | first" --raw-field t="$title"
    #--jq ".[] | select(.title==\"$title\") | .number" | head -n1
}

# Return the number of an existing *issue* (not PR) with the exact title in DEST,
# or "" if none. Handles pagination and empty pages without jq errors.
exists_issue_number_by_title() {
  local repo="$1" title="$2" created="$3"

  # List all issues (state=all), paginate, and filter:
  # - .[]? : safe iterate (no error on null)
  # - exclude PRs: select(has("pull_request")|not)
  # - exact title match (case-sensitive)
  gh api --paginate "/repos/${DST_ORG}/${repo}/issues?state=all&per_page=100" 2>/dev/null \
  | jq -r --arg t "$title" --arg d "$created" '
      .[]?                                                              # tolerate empty/null arrays
      | select(has("pull_request")|not)                                 # only real issues
      | select(.title == $t and (.created_at|split("T")[0]) == $d)      # exact title match
      | .number
    ' | head -n1
}

# Create issue in destination; echoes NEW_ISSUE_NUMBER
create_issue_in_dest() {
  local name="$1" title="$2" body="$3" labels_json="$4" milestone_title="$5" state="$6" created="$7"

  # Idempotency: skip if exact title exists already
  local existing="$(exists_issue_number_by_title "$name" "$title" "$created" || true)"
  if [[ -n "$existing" ]]; then
    say "Issue already exists in ${DST_ORG}/${name} with same title, skipping (##${existing})"
    echo "" # signal "skipped" to caller
    return 0
  fi

  # Resolve milestone number in DEST (if any)
  local msnum=""
  if [[ -n "$milestone_title" ]]; then
    msnum="$(dest_milestone_number_by_title "$name" "$milestone_title" || true)"
  fi

  # Build JSON body with jq (correct conditional, no ternary)
  local json="$(jq -n \
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
  local resp="$(printf '%s' "$json" \
         | gh api -H "Accept: application/vnd.github+json" \
                 -X POST "/repos/${DST_ORG}/${name}/issues" --input -)"

  local newnum="$(printf '%s' "$resp" | jq -r '.number')"

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
  local name="$1" num="$2" body="$3"
  gh_post -X POST "/repos/${DST_ORG}/${name}/issues/${num}/comments" -f body="$body" >/dev/null
}

# Copy issues (excluding PRs)
copy_issues() {
  local name="$1"
  say "Copying issues for ${name}"

  # Page through all issues from SOURCE (includes PRs; we filter those out)
  gh api --paginate "/repos/${SRC_ORG}/${name}/issues?state=all&per_page=100" 2>/dev/null \
  | jq -c '
      .[]?                                         # tolerate empty/null pages
      | select(has("pull_request")|not)            # exclude PRs
      | {
          number, title,
          body: (.body // ""),
          html_url, state,
          author: (.user.login // "unknown"),
          created_at,
          milestone_title: (.milestone.title // ""),
          labels: ((.labels // []) | map(.name))   # always an array
        }
    ' \
  | while IFS= read -r row; do
      # extract fields
      local NUM TITLE BODY URL STATE AUTHOR CREATED MIL_TITLE
      local LABELS_JSON

      TITLE=$(jq -r '.title'        <<<"$row")
      BODY=$(jq  -r '.body'         <<<"$row")
      URL=$(jq   -r '.html_url'     <<<"$row")
      STATE=$(jq -r '.state'        <<<"$row")
      AUTHOR=$(jq -r '.author'      <<<"$row")
      CREATED=$(jq -r '.created_at' <<<"$row")
      MIL_TITLE=$(jq -r '.milestone_title' <<<"$row")
      LABELS_JSON=$(jq -c '.labels' <<<"$row")     # already a JSON array

      # normalize labels again just in case
      [[ -z "$LABELS_JSON" || "$LABELS_JSON" == "null" ]] && LABELS_JSON='[]'

      local NEWBODY NEWNUM
      NEWBODY="(Copied from ${URL}\nOriginal author: @${AUTHOR} • Opened: ${CREATED})\n\n${BODY}"

      # create issue (function returns "" if duplicate title exists)
      NEWNUM="$(create_issue_in_dest "$name" "$TITLE" "$NEWBODY" "$LABELS_JSON" "$MIL_TITLE" "$STATE" "$CREATED")"

      # If we skipped (duplicate), don't try to post comments
      if [[ -z "$NEWNUM" ]]; then
        continue
      fi

      # Copy comments for this issue
      local num=$(jq -r '.number' <<<"$row")
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

# Copy PRs as archival issues (with merged review content)
copy_prs_as_archival_issues() {
  local name="$1"
  say "Archiving PRs as issues for ${name}"

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

      local NEWNUM="$(create_issue_in_dest "$name" "$ITITLE" "$IBODY" "$LABELS_JSON" "" "$STATE" "$CREATED")"

      # If skipped (duplicate archival issue already exists), do NOT add comments again
      if [[ -z "$NEWNUM" ]]; then
        continue;
      fi

      #say "Processing PR # ${PRNUM}"

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
          post_issue_comment "$name" "$NEWNUM" "$CMT"
        done || true
    done
}

# Copy discussions (best-effort; requires categories enabled on dest repo)
copy_discussions() {
  local name="$1"
  say "Copying discussions for ${name}"

  # GraphQL: repo IDs & categories
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
  local dstCatsJSON="$(gh_gql -f query="$q" -F so="$SRC_ORG" -F sr="$name" -F do="$DST_ORG" -F dr="$name" -F after="")" || {
    warn "GraphQL fetch failed for ${name} (likely no Discussions)"; return;
  }
  local dstCats; dstCats="$(echo "$dstCatsJSON" | jq -c '.data.dst.discussionCategories.nodes')" || dstCats="[]"
  local hasCats; hasCats="$(echo "$dstCats" | jq 'length>0')" || hasCats="false"
  if [[ "$hasCats" != "true" ]]; then
    warn "Destination repo ${DST_ORG}/${name} has no discussion categories; skipping discussions."
    return
  fi

  # Page through discussions
  local cursor=""
  local hasNext="true"
  while [[ "$hasNext" == "true" ]]; do
    local page="$(gh_gql -f query="$q" -F so="$SRC_ORG" -F sr="$name" -F do="$DST_ORG" -F dr="$name" -F after="$cursor")" || break
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
      local CATID="$(echo "$dstCats" | jq -r --arg n "$DCAT" 'first(.[] | select(.name==$n) | .id) // first(.[] | .id)')"

      # Create discussion
      local dstRepoId; dstRepoId="$(echo "$page" | jq -r '.data.dst.id')"
      local m='mutation($rid:ID!,$cid:ID!,$title:String!,$body:String!){
        createDiscussion(input:{repositoryId:$rid,categoryId:$cid,title:$title,body:$body}){
          discussion{ id number }
        }
      }'
      local created="$(gh_gql -f query="$m" -F rid="$dstRepoId" -F cid="$CATID" -F title="$DTITLE" -F body="$BODY")" || { warn "Failed to create discussion"; continue; }
      local newDid; newDid="$(echo "$created" | jq -r '.data.createDiscussion.discussion.id')"

      # Comments (single page or more)
      # First page from current node
      echo "$d" | jq -c '.comments.nodes[]?' | while read -r c; do
        local CAUTH=$(echo "$c" | jq -r '.author.login // "unknown"')
        local CDAT=$(echo "$c"  | jq -r '.createdAt')
        local CBOD=$(echo "$c"  | jq -r '.body // ""')
        local CBODY="**(Original comment by @${CAUTH} on ${CDAT})**\n\n${CBOD}"
        local cm='mutation($id:ID!,$body:String!){ addDiscussionComment(input:{discussionId:$id, body:$body}){ comment{ id } } }'
        gh_gql -f query="$cm" -F id="$newDid" -F body="$CBODY" >/dev/null || true
        sleep "$THROTTLE"
      done
      # Additional comment pages not handled here for simplicity (rare for most repos).
    done
  done
}

# --- Main loop over source org repos ------------------------------------------
say "Listing repositories in ${SRC_ORG}"
gh api --paginate "/orgs/${SRC_ORG}/repos?per_page=100" \
  --jq '.[] | {name,visibility,archived,has_wiki} | @base64' \
| while read -r row; do
    _j() { echo "$row" | base64 --decode | jq -r "$1"; }
    NAME=$(_j '.name')
    VIS=$(_j '.visibility')
    ARCH=$(_j '.archived')
    HAS_WIKI=$(_j '.has_wiki')

    sayHeader "Processing repo: ${NAME}"
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
      warn "Source repo is archived; destination remains unarchived by default."
    fi
done

say "All done. Validate counts (issues/PR-archives/discussions) and sample a few repos."
