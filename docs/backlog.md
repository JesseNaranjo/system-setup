# Backlog

<!-- DRIFT GUARD — Do not remove the audience line below. -->
> **Audience: AI coding agents only.** AI-maintained backlog of open work deferred from plans and reviews. The entry schema and the sweep rules are owned by §Backlog in the global AI-instruction file (`~/.claude/CLAUDE.md`) — follow it exactly and do NOT restate it here, or the two copies drift. Completed work belongs in `changelog.md`, standing lessons and decision records in `lessons.md`.

## Open

### Execution-guard form contradicts AGENTS.md §Important Implementation Notes #1

- **Source:** Plan Review of the self-update restart fix, 2026-09-06 (branch `worktree-self-update-restart`; the plan file is local to the author's machine).
- **Problem:** §Important Implementation Notes #1 mandates `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"`. The three `_download-*-scripts.sh` use that form, and so does §Complete Download Script Template, but `system-setup/system-setup.sh`, `kubernetes/kubernetes-setup.sh`, and AGENTS.md's other three snippets (the standalone-script example, §Orchestrator Pattern, and the module template) use `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`. The mandate therefore contradicts most of the repository, and AGENTS.md contradicts itself. A third form is also undocumented: the two test suites (`tests/test-self-update.sh`, `utils/tests/test-rsync-over-tunnel.sh`) have no execution guard at all, which is correct for development-only files that nothing sources and that are never distributed — but no rule records that exemption.
- **Why deferred:** No self-update behaviour is involved; this is a convention decision, not a defect, and the plan that surfaced it was scoped to the restart ordering.
- **Action on pickup:** Pick one canonical form and make AGENTS.md and every script agree. Weigh this first: the `&&` form is a false list when the file is sourced, so it returns 1 and the file's own `set -e` exits the sourcing shell — every test that sources such a script must write `source "$f" || true` (see `tests/README.md`). The `if` form returns 0 when sourced, so amending the note is the cheaper direction; standardising on `&&` instead means auditing every `source`-based test. Whichever form wins, state the test-file exemption in the same edit: a development-only test script carries no guard because nothing ever sources it.

### Reverse-lookup convenience (`-x IP`) in `utils/dig-all.sh` (added 2026-04-18)

- **Source:** 2026-04-18 `utils/dig-all.sh` standardization.
- **Problem:** `utils/dig-all.sh` has no reverse-lookup mode — it does not accept an IP argument and run `dig -x IP` across its record-type loop.
- **Why deferred:** The reverse-lookup use case is niche enough that users can invoke `dig -x` directly.
- **Action on pickup:** Accept an IP argument and run `dig -x IP` across the same record-type loop the script already drives. The addition is small and self-contained.

### Resolver port-suffix support (`SERVER#PORT`) in `utils/dig-all.sh` (added 2026-04-18)

- **Source:** 2026-04-18 `utils/dig-all.sh` post-implementation review.
- **Problem:** `dig` accepts `@1.1.1.1#5353` syntax to target a resolver on a non-standard port, but `validate_resolver`'s regex `^[A-Za-z0-9][A-Za-z0-9._:-]*$` rejects `#`, a genuine feature gap: `utils/dig-all.sh` cannot target such a resolver.
- **Why deferred:** (a) Non-standard DNS ports are uncommon outside test labs, and (b) adding `#` to the allowlist requires confirming it does not weaken injection defenses — a separate analysis.
- **Action on pickup:** Run the separate analysis first — confirm that admitting `#` into `validate_resolver`'s allowlist does not weaken its injection defenses. Only then extend the regex `^[A-Za-z0-9][A-Za-z0-9._:-]*$` to accept `#` so the `SERVER#PORT` form (`@1.1.1.1#5353`) passes validation.

### `download_script` wget failures collapsed into one generic message (added 2026-05-05)

- **Source:** 2026-05-05 self-update fixes backport (branch `backport-self-update-fixes`).
- **Problem:** Most `download_script` wget branches in this repo use `wget -q ... 2>/dev/null` and treat any non-zero exit as a single generic failure; the 2026-05-05 backport captures `wget_exit` but renders it generically, so the user gets no more diagnosis than the old flat "Download failed (network/timeout)". `wget(1)` documented exit codes do distinguish: 4=network, 5=SSL, 6=auth, 8=server (HTTP 4xx/5xx), so a user with an expired credential on a wget-only host gets misdirected to look at their network. Affected sites: every helper library and standalone with a `download_script` body, now including `utils/utils-misc.sh` (library) and its caller `utils/_download-utils-scripts.sh`, added by the 2026-07-17 `utils/` Modular Standalone conversion.
- **Why deferred:** The 2026-05-05 backport (branch `backport-self-update-fixes`, commits `8746154` through `a557927`) closed 10 of the gaps tracked in earlier revisions of the file and stopped at capturing `wget_exit`; the remaining `case` arms are mechanical and change error-message text only, so they fell outside its scope.
- **Action on pickup:** Capture the exit code via `wget … || wget_exit=$?` then `case` on it: 4|5 → "Network/SSL error", 6 → "Authentication failed — check token", 8 → "Server error — check token and repo access", * → "Download failed (wget exit $wget_exit)". The `*` arm is what the generic render already produces, so the work is adding the 4|5, 6 and 8 arms. Apply to every `download_script` body in one change so the parity copies stay identical, `utils/utils-misc.sh` included; `utils/_download-utils-scripts.sh` is a caller of that body, not a body site itself.

### Atomic-rename for config-rewrite sites under elevation (added 2026-05-05)

- **Source:** 2026-05-05 plan `Reviewed: Backport 10 self-update / temp-file / prompt-UX fixes` — deliberate scope decision.
- **Problem:** `normalize_trailing_newlines()` in both `utils-sys.sh` and `utils-k8s.sh`, plus `update_config_line()` in both libraries, use bare `mktemp` (`/tmp` tmpfs) and then a cross-FS `mv` to `$file`, often `/etc/...` reached via `run_elevated`. A cross-FS `mv` is copy + unlink, not `rename(2)`, so a SIGKILL or power-loss mid-`mv` can leave a truncated config file.
- **Why deferred:** Out of scope for the 2026-05-05 self-update backport. Pattern E3 (bookkeeping-only inline `mktemp` + `TEMP_FILES+=()`) was applied at those sites instead and preserved the current cross-FS behavior.
- **Action on pickup:** Four sites — `normalize_trailing_newlines()` and `update_config_line()` in each of `utils-sys.sh` and `utils-k8s.sh`; apply the same fix at all four. Atomic same-FS rename requires either (a) `mktemp` adjacent to `$file` AND running `mktemp` under the same elevation as the eventual `mv`, which complicates the function's calling convention, or (b) writing through a privileged helper that handles both the temp creation and the rename atomically.

### `lxc/watch-lxc.sh` container-name filter (positional args) (added 2026-04-27)

- **Source:** 2026-04-27 initial implementation of `lxc/watch-lxc.sh`.
- **Problem:** `services-check.sh --watch` accepts service-name filters as positional args; `watch-lxc.sh` enforces a strict no-args check in `main()`, so users cannot narrow the display to a single LXC.
- **Why deferred:** (a) the typical use case is "show everything" at a glance; (b) `lxc-ls --fancy <names...>` already accepts a name filter, so the implementation cost is low when actually requested.
- **Action on pickup:** Replace the strict no-args check in `main()` with a positional-args collection pattern (see the positional-args loop in `lxc/stop-lxc.sh`), then forward the array into `render_container_table`'s `lxc-ls --fancy --fancy-format NAME,STATE,IPV4,IPV6,UNPRIVILEGED` call (as of 2026-09-16 that call lives in `render_container_table`, not `watch_loop`, and already carries `--fancy-format`; append `"${CONTAINERS[@]}"` after it).

### `utils/push-ghostty-terminfo.sh` multi-host targeting (added 2026-07-14)

- **Source:** 2026-07-14 deferral from `utils/push-ghostty-terminfo.sh` work.
- **Problem:** `utils/push-ghostty-terminfo.sh` accepts exactly one host per run, so covering a fleet takes one invocation per host.
- **Why deferred:** Keeping the first version focused won out; re-running per host is cheap.
- **Action on pickup:** Accept `host...` positional args and loop probe → push → verify per host, mirroring the positional-args loop in `lxc/stop-lxc.sh`.

### `utils/push-ghostty-terminfo.sh` `~/.ssh/config` host enumeration (`--all`) (added 2026-07-14)

- **Source:** 2026-07-14 deferral from `utils/push-ghostty-terminfo.sh` work.
- **Problem:** `utils/push-ghostty-terminfo.sh` has no `--all` flag that parses every `Host` block in `~/.ssh/config` and pushes to all of them.
- **Why deferred:** ssh-config parsing has real edge cases (wildcards, `Match`, `Include`, `ProxyJump`-only aliases) needing their own design, and there is no existing parser in the repo to reuse.
- **Action on pickup:** Design the ssh-config parser first — it must handle wildcards, `Match`, `Include`, and `ProxyJump`-only aliases, and nothing in the repo can be reused for it. Then add `--all` to enumerate every `Host` block in `~/.ssh/config` and push to each.

### `utils/push-ghostty-terminfo.sh` macOS pre-Sonoma `infocmp` fallback (added 2026-07-14)

- **Source:** 2026-07-14 deferral from `utils/push-ghostty-terminfo.sh` work.
- **Problem:** macOS before Sonoma ships an `infocmp` that cannot emit `-x`, and `utils/push-ghostty-terminfo.sh` has no fallback for it. Ghostty recommends the Homebrew ncurses binary (`/opt/homebrew/opt/ncurses/bin/infocmp` or `/usr/local/opt/ncurses/bin/infocmp`). [confirmed: https://ghostty.org/docs/help/terminfo fetched 2026-07-14]
- **Why deferred:** The script runs from the Ghostty host, and current macOS (Sonoma+) / Linux `infocmp` handle `-x`.
- **Action on pickup:** After `detect_os`, if macOS and `infocmp -x xterm-ghostty` fails, retry with the Homebrew path (`/opt/homebrew/opt/ncurses/bin/infocmp` or `/usr/local/opt/ncurses/bin/infocmp`) if present.

### `utils/push-ghostty-terminfo.sh` friendlier read-only-`/usr` (immutable OS) error (added 2026-07-14)

- **Source:** 2026-07-14 deferral from `utils/push-ghostty-terminfo.sh` work.
- **Problem:** On Bazzite/Silverblue etc., the system-wide `sudo tic -x -o /usr/share/terminfo` fails and `utils/push-ghostty-terminfo.sh` correctly exits 70 — but with a generic "install failed" message that does not tell the user the OS image is immutable.
- **Why deferred:** Correctness is fine as-is.
- **Action on pickup:** On the system-mode failure path, probe `ssh host 'test -w /usr/share/terminfo'` (or detect the write-error text) and, when the dir is read-only, redirect the user to `--user` or the OS's layered-image mechanism instead of the generic failure.

### `utils/rsync-two-way.sh` remote-spec host lacks an `ssh`/`rsync` option-injection guard (added 2026-07-17)

- **Source:** 2026-07-17 `utils/` Modular Standalone conversion, post-implementation review.
- **Problem:** The `REMOTE` argument is parsed by `^([^@]+@)?([^:]+):(.+)$` and the captured host is passed unguarded to the connectivity check `ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_USER_HOST" "exit"` in `rsync-two-way.sh`, which runs BEFORE the user confirmation prompt. Shell quoting does not stop *option* injection: a spec whose host begins with `-` (e.g. `./rsync-two-way.sh /local '-oProxyCommand=touch /tmp/x:/p'`) is parsed by `ssh` as an option, so `ProxyCommand` executes a local command with no confirmation — a real local-command-execution path when the tool is driven with an untrusted/pasted spec.
- **Why deferred:** Low risk for a personal CLI where the user supplies their own args. Pre-existing: byte-identical to the pre-conversion script; the 2026-07-17 Modular Standalone conversion only wrapped the flow in `main()`.
- **Action on pickup:** After parsing, reject option-like hosts (`[[ "$REMOTE_HOST" == -* ]] && { print_error "Invalid host: $REMOTE_HOST"; exit 1; }`) and pass `--` before the positional remotes to `rsync` (`rsync "${OPTS[@]}" -- "$LOCAL/" "$REMOTE"`); for the `ssh` call the leading-`-` guard is the reliable defense.

### `rsync-over-tunnel.sh`: everything after `--` (`EXTRA`) reaches `ssh` and `rsync` unvalidated (added 2026-07-24)

- **Source:** rsync-over-tunnel standardization plan, 2026-07-24.
- **Problem:** In `utils/rsync-over-tunnel.sh` the leading-`-` ssh-target guard is in place and the arg parser rejects dash-leading tokens, but everything after `--` (`EXTRA`) is passed verbatim to `ssh` (`source-tunnel`) and `rsync` (`source-transfer`). A crafted `-- -oProxyCommand=...` or hostile rsync flag can still execute commands — the same live class as CVE-2023-51385 / CVE-2025-61984.
- **Why deferred:** `EXTRA` is a deliberate power-user escape hatch (operator-trust boundary); hardening needs an allowlist/validation design.
- **Action on pickup:** Design allowlist/validation for `EXTRA` before it reaches `ssh` and `rsync`. Fix this in the same change as the backlog entry covering option injection in `utils/rsync-two-way.sh`, so both rsync scripts are hardened together. Read the entry "`--` is NOT a verified end-of-options marker for `rsync`" first — it constrains the fix.

### `rsync-over-tunnel.sh`: the generated rsync module is unauthenticated, so any local user on the TARGET can write the destination as root while step 1 runs (added 2026-07-24)

- **Source:** rsync-over-tunnel post-implementation review finding F5, 2026-07-24.
- **Problem:** The `rsyncd.conf` generated by `utils/rsync-over-tunnel.sh` has `uid = 0`, `read only = false`, and `hosts allow = 127.0.0.1` — which admits every local account on the target, not just the SSH tunnel, because rsyncd cannot distinguish local users by connection. A co-tenant on the target can therefore read or write the destination rootfs as root for the (foreground, supervised) life of the daemon. Mitigations already in place: `max connections = 1` (a running transfer holds the only slot), loopback-only `address`, `hosts deny = *`, and the daemon is foreground so it exists only while watched. The script header states the single-user constraint.
- **Why deferred:** The only safe design — `auth users` plus a generated secret in a `0600` `/run` file — forces the operator to hand-carry that secret from the target host to the source host, adding a fourth artifact to a deliberately three-step runbook, for a tool whose stated scope is single-user personal machines.
- **Action on pickup:** Generate a random secret in `cmd_target_tunnel`, write it `0600` under `/run`, add `auth users` + `secrets file` to the config, and give `source-transfer` a `--password-file` / `RSYNC_PASSWORD` path — then decide how the secret crosses hosts without weakening the "nothing persists" property. openrsync accepts both `auth users` and `secrets file`; still run the check described in the entry on vetting new `rsyncd.conf` directives against openrsync's parameter table.

### `--` is NOT a verified end-of-options marker for `rsync` (added 2026-07-24)

- **Source:** 2026-07-24 note attached to the two rsync option-injection findings.
- **Problem:** The backlog entry covering option injection in `rsync-two-way.sh` (both rsync scripts live in `utils/`) prescribes `rsync "${OPTS[@]}" -- "$LOCAL/" "$REMOTE"`. Upstream's own man page (`https://download.samba.org/pub/rsync/rsync.1`, fetched 2026-07-24) documents no `--` handling at all; the only supporting evidence found was generic POSIX advice. `rsync-over-tunnel.sh` therefore guards the *shape* of the path instead (`[[ "$TRANSFER_PATH" == -* ]]`, matching its ssh-target guard) rather than depending on `--`.
- **Why deferred:** This is a constraint on the two option-injection entries rather than work of its own; it stands until one of them is implemented.
- **Action on pickup:** Whoever fixes either option-injection item — the `rsync-two-way.sh` one, or the post-`--` `EXTRA` one in `rsync-over-tunnel.sh` — must verify `--` against the installed rsync before adopting the prescription, or use the same leading-`-` guard.

### `rsync-over-tunnel.sh`: the Homebrew-rsyncd `use chroot = no` special case on macOS is an inference, never measured (added 2026-08-05)

- **Source:** rsync-over-tunnel macOS-support plan, task A6 step 5, 2026-08-05.
- **Problem:** `cmd_target_tunnel` ships `use chroot = no` whenever `DETECTED_OS == macos` and `RSYNC_BIN != /usr/bin/rsync`. That is an *inference* from `com.apple.private.vfs.chroot` being the sole key in Apple's [`rsyncd-entitlements.plist`](https://raw.githubusercontent.com/apple-oss-distributions/rsync/main/rsyncd-entitlements.plist), not a measurement: no Homebrew rsync has ever driven a live daemon, so neither `use chroot = no` nor the `munge symlinks = no` line emitted only on that branch has run. The Apple half is measured — a macOS↔macOS run on 2026-08-07 with Apple's `/usr/bin/rsync` on both ends took the `use chroot = yes` path, the no-chroot consent box never appeared, and the daemon started and served a full transfer, so a chrooted Apple rsyncd demonstrably works.
- **Why deferred:** No Mac carrying a Homebrew rsync has been available: the 2026-08-05 macOS-support work had no Mac at all, and neither host in the 2026-08-07 run had a Homebrew rsync.
- **Action on pickup:** On a SIP-enabled Mac with Homebrew rsync, hand-edit the generated config to `use chroot = yes` and start the daemon — the open question is whether an unentitled Homebrew rsyncd can actually `chroot()`. If it starts, the inference was wrong and the special case must be dropped (it costs real confinement). If it fails with `EPERM`, the shipped behavior is correct — record the measurement here so nobody re-opens it. Either way confirm Apple's `/usr/bin/rsync` still receives `yes`.

### `rsync-over-tunnel.sh` on macOS: the cross-platform directions, the Homebrew/no-chroot branch, and payload edge cases are unverified on real hardware (added 2026-08-05)

- **Source:** rsync-over-tunnel macOS-support plan, task A7 step 4, 2026-08-05; surfaced as untracked by post-implementation review finding F8.
- **Problem:** macOS↔macOS runs green on real hardware — on 2026-08-07, both hosts on Apple's `/usr/bin/rsync`: the generated `rsyncd.conf` was fed to `openrsync`'s parser and accepted (see the entry on vetting new `rsyncd.conf` directives against openrsync's parameter table), the tunnel and daemon handshake worked, both `prompt_yes_no` consent gates — on the ACL degradation and on the no-chroot path — were answered on a real TTY, `sudo` and `chroot(2)` behaved under SIP, and a 2144-file transfer ran. That run is why the config emits numeric `uid = 0`/`gid = 0`: `gid = root` does not exist on macOS (gid 0 is `wheel`), so every macOS daemon rejected the connection at attach time with `@ERROR <module>: gid 'root' invalid`. The rest of the macOS evidence is shim-driven — the ACL/xattr degradation matrix, `require_rsync`'s absolute-path resolution, and the `@RSYNCD:` greeting probe were exercised by (a) a fake `rsync` on `PATH` that `cat`s a captured `--version` blob, (b) a `sudo` shim, and (c) a perl one-liner listening on the loopback port and speaking a greeting line; automated coverage in `utils/tests/test-rsync-over-tunnel.sh` covers the parsers, `validate_options`, `compose_transfer_args`, and the generated config. NOT exercised by any of it: the macOS→Linux and Linux→macOS directions (so the cross-platform `-A`/`-X` mapping entry is still untested in anger), the Homebrew-rsync/no-chroot branch including its `prompt_yes_no` consent gate, which has never been answered on a real macOS TTY, and payload-level edge cases — the 2026-08-07 run used a real project directory rather than the appendix's synthetic tree, so symlink preservation (the `/rsyncd-munged/` check), hardlinks, sparse files and cleanup were not individually verified.
- **Why deferred:** The 2026-08-05 work had no Mac, only shims; the 2026-08-07 session had two Macs, both running Apple's `/usr/bin/rsync`, so it could not cover a mixed macOS/Linux pair or a Homebrew rsync.
- **Action on pickup:** Run the three-step runbook macOS→Linux and Linux→macOS on real hardware and record the result here. Drive it with the appendix's synthetic tree so symlink preservation (the `/rsyncd-munged/` check), hardlinks, sparse files and cleanup are each verified, and include a Homebrew rsync so the no-chroot branch and its consent gate run.

### Any NEW directive added to the `rsyncd.conf` generated by `rsync-over-tunnel.sh` must first be checked against openrsync's parameter table (added 2026-08-06)

- **Source:** rsync-over-tunnel macOS-support plan iteration 3, key table verified 2026-08-06; re-surfaced by the post-implementation review, findings F7 and F34.
- **Problem:** openrsync (Apple's `/usr/bin/rsync` on macOS 15.4+) treats an **unknown key as an unrecoverable error**, so one stray directive kills step 1 on every macOS target running the Apple binary. The current set is sound: the 16 keys emitted today were verified present in `rsync_daemon_params[]` in `openrsync/daemon_cfg.c` on 2026-08-06, `build_daemon_config` records that, and a real Apple `/usr/bin/rsync` parsed and served the generated config on a macOS target on 2026-08-07 — so the table reading was correct for the `use chroot = yes` variant (15 keys — `munge symlinks` is omitted on that branch and therefore still unproven against a live parser). The exposure is future additions, and nothing enforces the check; it is manual discipline. A key being *accepted* is not the same as its *value* being valid: `gid = root` passed the parser and failed later, at client-attach time, in `daemon_chuser_resolve_name`.
- **Why deferred:** The check is a standing discipline rather than a code change, and no lint was built to enforce it.
- **Action on pickup:** Read the table in [`apple-oss-distributions/rsync`](https://github.com/apple-oss-distributions/rsync), cite the ref you read, and evaluate a lint that diffs the emitted keys against it so this stops being a manual discipline. Keys openrsync accepts that the script does *not* use, in case they are wanted later: `auth users`, `secrets file` (both needed by the entry on the unauthenticated rsync module), `refuse options`, `timeout`, `pre-xfer exec` / `post-xfer exec`, `strict modes`, `incoming chmod` / `outgoing chmod`, `write only`, `filter` / `include` / `exclude`. openrsync's own defaults differ in places worth knowing — `use chroot` defaults to `true` there, and `lock file` to `/var/run/rsyncd.lock`.

### `-A`/`-X` are lossy between APFS and Linux even when both sides negotiate protocol 30+ (added 2026-08-05)

- **Source:** rsync-over-tunnel macOS-support plan review, 2026-08-05.
- **Problem:** The 2026-08-05 work made `utils/rsync-over-tunnel.sh` detect whether ACLs and xattrs are *available*; it does nothing about whether they are *meaningful* across the pair. macOS ACLs are NFSv4-style and do not map onto Linux POSIX ACLs, and the xattr namespaces differ (`com.apple.*` vs `user.*`/`security.*`/`system.*`), so a macOS↔Linux transfer with `-A -X` can silently write metadata the destination cannot interpret — or drop it.
- **Why deferred:** A correct answer means either a per-direction allowlist (`--filter` on xattr names) or simply refusing `-A`/`-X` on cross-platform pairs, and choosing between those needs real-world testing on a mixed pair.
- **Action on pickup:** Start by capturing what actually survives a round trip in each direction before designing the guard. No macOS→Linux or Linux→macOS run has happened yet — see the entry on the unverified cross-platform directions.

### Pre-existing shellcheck warnings in five scripts (added 2026-07-15)

- **Source:** 2026-07-15 canonical-helper review (helper reconciliation).
- **Problem:** Five scripts carry shellcheck warnings despite the repo's stated "0 warnings, warnings→errors" standard (`AGENTS.md` §Linting): `github/gh_org_copy.sh` (~41), `system-setup/utils-sys.sh` (17), `kubernetes/utils-k8s.sh` (14), `github/gh_org_delete_issues.sh` (8), `github/gh_org_delete_repos.sh` (7). Those counts were measured 2026-07-15 by before/after `shellcheck` during the canonical-helper reconciliation, which confirmed the warnings are pre-existing and NOT introduced by that change. The `utils/` suite is outside this inventory: verified 2026-07-17, `utils/services-check.sh` and `utils/push-ghostty-terminfo.sh` (both no longer standalones) plus the rest of the `utils/` Modular Standalone conversion (`utils/utils-misc.sh`, `utils/_download-utils-scripts.sh`, `utils/dig-all.sh`, `utils/reset-macOS-display-settings.sh`, `utils/rsync-two-way.sh`, `utils/unlock-keychain.sh`) are clean under `shellcheck -x` (0 warnings each).
- **Why deferred:** Out of scope for the push-ghostty-terminfo review that surfaced them; each file is a mechanical per-file cleanup that warrants its own focused pass so diffs stay reviewable.
- **Action on pickup:** One focused pass per file, not a repo-wide sweep. Dominant codes: SC2155 (split `local x; x=$(...)`), SC2034 (unused vars), SC2016 (single-quoted `$` in GraphQL heredocs — usually intentional, annotate with a disable).

### `github/gh_org_copy-backup.sh` is a tracked backup file (added 2026-07-15)

- **Source:** 2026-07-15 canonical-helper review.
- **Problem:** `github/gh_org_copy-backup.sh` is committed as a backup file. Git history is the backup; a committed `-backup.sh` is drift-prone — it does NOT carry the canonical helpers, so it silently misses cross-copy fixes (e.g. the 2026-07-15 reconciliation skipped it).
- **Why deferred:** Removal needs a reference check first, and the file's intent — throwaway backup versus deliberate reference snapshot — was never settled during the review.
- **Action on pickup:** Confirm nothing references `github/gh_org_copy-backup.sh`, then remove it — or, if it is a deliberate reference snapshot, document why and exclude it from the Helper-Duplication audit.

### No `.shellcheckrc` and no CI gate for the "0 warnings, warnings→errors" standard (added 2026-07-17)

- **Source:** 2026-07-17 `utils/` Modular Standalone documentation cascade.
- **Problem:** The "0 warnings, warnings→errors" standard is stated in `AGENTS.md` §Linting and restated in this backlog, but nothing enforces it mechanically — there is no repo-root `.shellcheckrc` and no CI step. The pre-existing library warnings (`github/gh_org_copy.sh` ~41, `system-setup/utils-sys.sh` 17, `kubernetes/utils-k8s.sh` 14, `github/gh_org_delete_issues.sh` 8, `github/gh_org_delete_repos.sh` 7) have persisted across multiple reviews with no gate to catch regressions or force cleanup.
- **Why deferred:** Surfaced during a documentation-only cascade, which carried no room for lint configuration or build infrastructure.
- **Action on pickup:** Add a repo-root `.shellcheckrc` (severity/exclude policy) and a CI step that runs `shellcheck` over every `*.sh` and fails on any warning-or-above, then schedule the mechanical per-file cleanups already tracked in "Pre-existing shellcheck warnings in five scripts".

### `.ps1` scripts are out of scope for self-update / Modular Standalone conversion (added 2026-07-17)

- **Source:** 2026-07-17 `utils/` Modular Standalone conversion.
- **Problem:** `utils/compare-directories.ps1` and `utils/robocopy-two-way.ps1` remain plain standalone PowerShell with no self-update. They cannot `source` the bash `utils-misc.sh` library, so the `check_for_updates` self-update pattern used by the other 6 converted `utils/` scripts does not apply to them.
- **Why deferred:** No bash-side change reaches them, and self-update has not been requested for the two PowerShell scripts.
- **Action on pickup:** If self-update is ever wanted for `utils/compare-directories.ps1` and `utils/robocopy-two-way.ps1`, it needs a PowerShell-native equivalent — a separate design, NOT a port of the bash `check_for_updates` pattern.

### Decision-Guide contradiction in `AGENTS.md` (added 2026-07-17)

- **Source:** 2026-07-17 `utils/` Modular Standalone documentation cascade.
- **Problem:** `AGENTS.md`'s Decision Guide table labels the "Simple system task (start/stop services)" row **Standalone**, but its stated reason is "Source utils for shared functions, run independently" — sourcing shared utils is Modular Standalone behavior, not Standalone. The contradiction is pre-existing and was untouched by the `utils/` conversion.
- **Why deferred:** Left as-is per the documentation cascade's plan scope.
- **Action on pickup:** Either reclassify the row to Modular Standalone or reword the reason to drop "Source utils for shared functions."

### Graceful failure when `utils-misc.sh` is absent (added 2026-07-17)

- **Source:** 2026-07-17 `utils/` Modular Standalone conversion.
- **Problem:** Every converted `utils/` script does a bare `source "${SCRIPT_DIR}/utils-misc.sh"` under `set -e`. If the library is not co-located — e.g. a user curls a single script, the exact "no longer curl-able" trade-off the Modular Standalone pattern introduces, most likely to bite `utils/dig-all.sh` given its history as a popular single-file download — the script aborts with a raw bash "No such file or directory" error instead of a friendly message.
- **Why deferred:** A one-line existence-check-and-message guard would be friendlier but DEVIATES from the bare-source parity `lxc/` and `llm/` already establish for `utils-lxc.sh` / `utils-llm.sh`. This is a cross-suite owner decision, so do NOT one-off it in `utils/`.
- **Action on pickup:** Decide across `lxc/`, `llm/`, and `utils/` together (not just `utils/`) whether to add a guard, and if so, apply the same guard shape to all three per-directory libraries in one change.

### `setup-lxc.sh` has no `main()` or execution guard (added 2026-09-16)

- **Source:** Plan Review of the container protect/unprotect work, 2026-09-16.
- **Problem:** `lxc/setup-lxc.sh` runs everything at file scope and calls `check_for_updates` outside any function — the only `lxc/` script that does. This violates AGENTS.md §Important Implementation Notes #1.
- **Why deferred:** Restructuring a 600-line root-only host-setup script is unrelated to protection and cannot be exercised without a real LXC host.
- **Action on pickup:** Wrap `setup-lxc.sh`'s file-scope logic in a `main()` and add the standard `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"` execution guard, matching every other `lxc/` script.

### `setup-lxc.sh` tracks backups in a string, not an array (added 2026-09-16)

- **Source:** Plan Review of the container protect/unprotect work, 2026-09-16.
- **Problem:** `lxc/setup-lxc.sh` tracks backed-up files with `BACKED_UP_FILES=""`, substring-matched with `[[ "$BACKED_UP_FILES" == *"$file"* ]]`. AGENTS.md §Critical Syntax Rules mandates arrays for collections, and a path containing a space corrupts the substring match.
- **Why deferred:** Same file and same blocker as "`setup-lxc.sh` has no `main()` or execution guard" — restructuring is unrelated to protection and cannot be exercised without a real LXC host.
- **Action on pickup:** Convert `BACKED_UP_FILES` to an array and replace the substring match with the standard "check if already in array" loop pattern (AGENTS.md §Array Iteration).

### Unquoted word-splitting in `stop-lxc.sh` and `restart-lxc.sh` (added 2026-09-16)

- **Source:** Plan Review of the container protect/unprotect work, 2026-09-16.
- **Problem:** Both `lxc/stop-lxc.sh` and `lxc/restart-lxc.sh` use `RUNNING=( $(/usr/bin/lxc-ls --running) )` (the two `SC2207`s in `lxc/`) — the exact unquoted command-substitution-into-array pattern AGENTS.md §Anti-Patterns forbids. It works today only because container names cannot contain whitespace.
- **Why deferred:** Neither file is touched by this work, and the fix wants a `mapfile`-based rewrite verified on a host with running containers.
- **Action on pickup:** Replace `RUNNING=( $(/usr/bin/lxc-ls --running) )` in both files with `mapfile -t RUNNING < <(/usr/bin/lxc-ls -1 --running)` — the `-1` is required because plain `lxc-ls` pads every name to the longest name's column width and separates with a space or newline depending on terminal width, while `-1` prints one bare name per line — then verify against a host with running containers.

### Manual `lxc-destroy -s` leaves the container's systemd state behind (added 2026-09-16)

- **Source:** Review of the container protect/destroy work, 2026-09-16.
- **Problem:** `lxc/README.md` tells the operator to destroy a container that has snapshots by running `lxc-destroy -s` by hand, because `destroy-lxc.sh` deliberately passes neither `-f` nor `-s`. That manual path skips the script's Step 3/3, so the per-container `lxc-bg-start@<name>.service` / `lxc-priv-bg-start@<name>.service` instance and its drop-in directory survive, and `destroy-lxc.sh` can no longer clean them up afterwards (the config is gone, so it exits 66 `EX_NOINPUT`).
- **Why deferred:** Needs a host with snapshots to design and verify the right fix.
- **Action on pickup:** Add either a `--snapshots` pass-through to `destroy-lxc.sh` (so `lxc-destroy -s` runs through the script's own flow) or a cleanup-only mode that removes the systemd service instance and drop-ins for a container whose directory is already gone. Either way, the systemd cleanup must stay reachable after the container directory (and its config) no longer exist.

### `lxc_resolve_path` ignores a custom `lxc.lxcpath` (added 2026-09-16)

- **Source:** Review of the container protect/destroy work, 2026-09-16.
- **Problem:** `lxc_resolve_path` hardcodes `/var/lib/lxc` for EUID 0 and `${HOME}/.local/share/lxc` otherwise, while the `lxc-*` tools honour `lxc.lxcpath` from `~/.config/lxc/lxc.conf` (and `/etc/lxc/lxc.conf`). On a host that sets it, the seven callers read configs from the wrong root: `protect-lxc.sh --status` and `watch-lxc.sh`'s PROTECTED column would report `no` for a protected container, and `create-lxc.sh`'s guard would not fire (the destroy hook still vetoes, but `lxc-destroy --quiet` hides why).
- **Why deferred:** No host with a custom `lxc.lxcpath` is available to verify against, and the fix touches every caller.
- **Action on pickup:** Read the effective path from `lxc-config lxc.lxcpath` (falling back to the current hardcoded pair) inside `lxc_resolve_path`, verify on a host with `lxc.lxcpath` set, and check the `lxc-info`/`lxc-destroy` call sites that currently rely on the tools' own default.

### `create-lxc.sh` and `backup-lxc.sh` build paths from an unvalidated container name (added 2026-09-16)

- **Source:** Whole-branch review of the container protect/destroy work, 2026-09-16.
- **Problem:** `destroy-lxc.sh`, `protect-lxc.sh`, `unprotect-lxc.sh` and `restore-lxc.sh` (both its positional argument and the name it reads out of the archive) all run their container name through `lxc_valid_name` before building a path from it; `create-lxc.sh` and `backup-lxc.sh` do not. Both interpolate the raw name into paths (`$(lxc_resolve_path)/${CONTAINER_NAME}/config`, the backup archive path) and into `lxc-*` arguments.
- **Why deferred:** Lower exposure than the `restore-lxc.sh` case that prompted the guard — neither script runs `rm -rf` or `sed -i` on a path built from the name, and the `lxc-*` tools reject a name they cannot use — so the fix is a consistency sweep rather than a defect, and it wants a host with real containers to re-exercise both scripts end to end.
- **Action on pickup:** Add the same `lxc_valid_name` guard (`print_error "✖ Invalid container name: …"`, `exit 64`) to `create-lxc.sh` and `backup-lxc.sh` right after their name argument is parsed.

### The protect-append integrity check does not cover the re-run or the fence-scope case (added 2026-09-16)

- **Source:** Whole-branch review of the container protect/destroy work, 2026-09-16.
- **Problem:** Three residuals of the integrity check added to `lxc_protect_config`. (a) The check runs only on the append path: `lxc_is_protected "$config" && return 0` returns first, and `protect_one` short-circuits to `- Already protected` without calling the helper, so a BEGIN-only husk left by a failed append (full filesystem) is never re-detected on a later run — the re-run is exactly the scenario that makes the husk dangerous, because every gate then reports "protected" while a raw `lxc-destroy` finds no hook. (b) The check greps the whole file rather than the fenced block, so a config that legitimately carries its own `lxc.hook.destroy = /bin/false` outside the fences (hooks are a list key — see the protect helpers' comments) would mask a truncated append. (c) `destroy-lxc.sh`'s drop-in warn branch skips `daemon-reload`, so a partial `rm -rf` leaves systemd's view stale and the warning tells the operator to remove the directory but not to reload.
- **Why deferred:** All three need a failed-write or partial-removal state to exercise honestly, which this machine cannot produce (no LXC, no controllable ENOSPC), and each fix touches a path that currently fails loudly, so the branch's reviewers judged none of them merge-blocking.
- **Action on pickup:** Verify block integrity where protection is *read*, not only where it is written (the natural home is `lxc_is_protected` or a companion the callers use before trusting it, without changing the settled BEGIN-fence predicate); scope the integrity grep to the fenced range; and have the drop-in warn branch also run `daemon-reload` (or tell the operator to) when a partial removal is possible.
