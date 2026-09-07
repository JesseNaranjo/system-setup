# Backlog

<!-- DRIFT GUARD — Do not remove the audience line below. -->
> **Audience: AI coding agents only.** AI-maintained backlog of deferred work. Follow the entry schema in `~/.claude/CLAUDE.md` §Backlog exactly. Append new entries at the end of `## Open`. Concrete feature gaps live in `future-todos.md`; this file holds work deferred from plans and reviews.

## Open

### Execution-guard form contradicts AGENTS.md §Important Implementation Notes #1

- **Source:** Plan Review of the self-update restart fix (`~/.claude/plans/we-re-going-to-fix-melodic-nebula.md`), 2026-09-06.
- **Problem:** §Important Implementation Notes #1 mandates `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"`. The three `_download-*-scripts.sh` use that form, and so does §Complete Download Script Template, but `system-setup/system-setup.sh`, `kubernetes/kubernetes-setup.sh`, and AGENTS.md's other three snippets (the standalone-script example, §Orchestrator Pattern, and the module template) use `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`. The mandate therefore contradicts most of the repository, and AGENTS.md contradicts itself.
- **Why deferred:** No self-update behaviour is involved; this is a convention decision, not a defect, and the plan that surfaced it was scoped to the restart ordering.
- **Action on pickup:** Pick one canonical form and make AGENTS.md and every script agree. Weigh this first: the `&&` form is a false list when the file is sourced, so it returns 1 and the file's own `set -e` exits the sourcing shell — every test that sources such a script must write `source "$f" || true` (see `tests/README.md`). The `if` form returns 0 when sourced, so amending the note is the cheaper direction; standardising on `&&` instead means auditing every `source`-based test.

### `check_for_updates` exec-restarts callers that are not executable in git

- **Source:** Code review of the self-update restart fix (branch `worktree-self-update-restart`), 2026-09-06.
- **Problem:** `check_for_updates` ends with `exec "$caller_abs" "$@"`, but 13 of its callers are mode `100644` in the index: `lxc/_download-lxc-scripts.sh`, `llm/_download-ollama-scripts.sh`, `utils/_download-utils-scripts.sh`, `lxc/{start,stop,restart,setup}-lxc.sh`, `kubernetes/{start,stop}-k8s.sh`, `llm/{ollama-remote,ollama-screen}.sh`, `system-setup/{install-desktop,pkgs-helper}.sh`. Hosts that install through `download_script` are unaffected because it `chmod +x`es what it writes — but on a repo clone, an accepted `utils-*.sh` update sets `any_updated=true` and the `exec` then dies with `Permission denied` (exit 126) *after* the library has been replaced, so `update_modules` and `cleanup_obsolete_scripts` never run. Reproduced during review with `bash lxc/_download-lxc-scripts.sh`.
- **Why deferred:** Pre-existing (the `exec` predates the restart-ordering fix) and repo-wide; correcting it means auditing and flipping file modes across four directories, which the branch that found it does not otherwise touch.
- **Action on pickup:** Audit every `.sh` that is *executed* rather than sourced and `git update-index --chmod=+x` it — the five `utils-*.sh` libraries are sourced and stay `644`; check `github/gh_org_copy-backup.sh`, `utils/disable-kvm-module.sh` and `utils/monitor-battery.sh` separately (they are non-executable too but never call `check_for_updates`). Then decide whether `check_for_updates` should `chmod +x "$caller_abs"` defensively before `exec` as belt-and-braces; if so it is a parity edit to all five copies plus `private/tmux/utils-tmux.sh`, and `tests/test-self-update.sh` should drop the fixture's `chmod +x` for the caller to pin it.
