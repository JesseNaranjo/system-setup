# Lessons

<!-- DRIFT GUARD — Do not remove the audience line below. -->
> **Audience: AI coding agents only.** AI-maintained log of standing lessons and decision records. Follow the entry schema in `~/.claude/CLAUDE.md` §Lessons Log exactly. Append new entries at the end of `## Lessons`.

## Lessons

### `grep --exclude` silently no-ops on `.md` files in this repository

- **Source:** Discovered 2026-09-04 while writing a worktree-migration prompt whose history-preservation guard relied on `--exclude` to keep `docs/changelog.md` from being rewritten.
- **Problem:** A repo-wide sweep written as `grep -rln PATTERN --exclude=changelog.md .` still reports `docs/changelog.md`. Every `--exclude` naming a `.md` file is ignored — no warning, no error, no non-zero exit. A guard built on it fails open, and a verification step built on it can never come back clean.
- **Lesson:** Claude Code replaces `grep` with a shell function that runs ugrep with `--ignore-files`, which honors `.gitignore`. This repository's `.gitignore` ends with the negation `!**/*.md`, and ugrep turns a gitignore negation into a forced include that overrides `--exclude`. Verified 2026-09-04 against ugrep 7.8.4; the identical command under `command grep` (GNU grep 3.11) excludes correctly. It still works when the search root is a subdirectory such as `docs/`, because the negation is only loaded from a `.gitignore` at the search root.
- **Standing instruction:** Never rely on `grep --exclude` to omit a `.md` file in this repository. Filter the output instead — `grep -rn PATTERN . | grep -vE '(^|/)(changelog|future-todos|lessons)\.md:'` — which no ignore-file glob can override. Reach for `command grep` when you specifically need GNU grep semantics.
