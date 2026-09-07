# Backlog

<!-- DRIFT GUARD — Do not remove the audience line below. -->
> **Audience: AI coding agents only.** AI-maintained backlog of deferred work. Follow the entry schema in `~/.claude/CLAUDE.md` §Backlog exactly. Append new entries at the end of `## Open`. Concrete feature gaps live in `future-todos.md`; this file holds work deferred from plans and reviews.

## Open

### Execution-guard form contradicts AGENTS.md §Important Implementation Notes #1

- **Source:** Plan Review of the self-update restart fix (`~/.claude/plans/we-re-going-to-fix-melodic-nebula.md`), 2026-09-06.
- **Problem:** §Important Implementation Notes #1 mandates `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"`. The three `_download-*-scripts.sh` use that form, but `system-setup/system-setup.sh`, `kubernetes/kubernetes-setup.sh`, and both AGENTS.md templates use `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`. The mandate therefore contradicts most of the repository.
- **Why deferred:** No self-update behaviour is involved; this is a convention decision, not a defect, and the plan that surfaced it was scoped to the restart ordering.
- **Action on pickup:** Pick one canonical form and make AGENTS.md and every script agree. Weigh this first: the `&&` form is a false list when the file is sourced, so it returns 1 and the file's own `set -e` exits the sourcing shell — every test that sources such a script must write `source "$f" || true` (see `tests/README.md`). The `if` form returns 0 when sourced, so amending the note is the cheaper direction; standardising on `&&` instead means auditing every `source`-based test.
