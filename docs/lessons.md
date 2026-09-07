# Lessons

<!-- DRIFT GUARD — Do not remove the audience line below. -->
> **Audience: AI coding agents only.** AI-maintained log of standing lessons and decision records. Follow the entry schema in `~/.claude/CLAUDE.md` §Lessons Log exactly. Append new entries at the end of `## Lessons`.

## Lessons

### `grep --exclude` silently no-ops on `.md` files in this repository

- **Source:** Discovered 2026-09-04 while writing a worktree-migration prompt whose history-preservation guard relied on `--exclude` to keep `docs/changelog.md` from being rewritten.
- **Problem:** A repo-wide sweep written as `grep -rln PATTERN --exclude=changelog.md .` still reports `docs/changelog.md`. Every `--exclude` naming a `.md` file is ignored — no warning, no error, no non-zero exit. A guard built on it fails open, and a verification step built on it can never come back clean.
- **Lesson:** Claude Code replaces `grep` with a shell function that runs ugrep with `--ignore-files`, which honors `.gitignore`. This repository's `.gitignore` ends with the negation `!**/*.md`, and ugrep turns a gitignore negation into a forced include that overrides `--exclude`. Verified 2026-09-04 against ugrep 7.8.4; the identical command under `command grep` (GNU grep 3.11) excludes correctly. It still works when the search root is a subdirectory such as `docs/`, because the negation is only loaded from a `.gitignore` at the search root.
- **Standing instruction:** Never rely on `grep --exclude` to omit a `.md` file in this repository. Filter the output instead — `grep -rn PATTERN . | grep -vE '(^|/)(changelog|future-todos|lessons)\.md:'` — which no ignore-file glob can override. Reach for `command grep` when you specifically need GNU grep semantics.

### A restart guard must not short-circuit the initialization its consumers depend on, and it must be consumed

- **Source:** 2026-09-06 self-update fix (plan `~/.claude/plans/we-re-going-to-fix-melodic-nebula.md`). Owner report: after `system-setup.sh` self-updated and restarted, no module update check ran until a second run.
- **Problem:** `check_for_updates` tested its restart guard before `detect_download_cmd`. The exec'd process sources the library fresh, so `DOWNLOAD_CMD` was `""`; every orchestrator and downloader gates `update_modules` on `[[ -n "$DOWNLOAD_CMD" ]]`, so the restarted run silently skipped module updates. Identical in all five libraries; `github/gh_org_*.sh` were already detect-first. The guard was also never consumed, so it stayed exported for every child of the restarted run.
- **Lesson:** An early-return guard placed before a side-effecting initializer starves every downstream consumer of that side effect on the guarded path: initialization first, guard second, and the contract ("populated on every return path where a tool exists") in the function's comment so the next parity copy inherits it. A process-restart marker is one-shot state — `unset` it the moment it has been read, or every child (including a long-lived server) inherits a stale instruction.
- **Standing instruction:** Any new guarded entry point that also initializes a global its callers read MUST order the initialization first, and any exported restart marker MUST be consumed with `unset` once tested. The `check_for_updates`-specific rules live in AGENTS.md §check_for_updates Pattern; `tests/test-self-update.sh` pins them.
