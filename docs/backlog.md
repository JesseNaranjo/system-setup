# Backlog

<!-- DRIFT GUARD — Do not remove the audience line below. -->
> **Audience: AI coding agents only.** AI-maintained backlog of open work deferred from plans and reviews. The entry schema and the sweep rules are owned by §Project Docs in the global AI-instruction file (`~/.claude/CLAUDE.md`) and `~/.claude/rules/project-docs.md` — follow it exactly and do NOT restate it here, or the two copies drift. Completed work belongs in `changelog.md`, standing lessons and decision records in `lessons.md`.

## Open

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

### `rsync-over-tunnel.sh`: the generated rsync module is unauthenticated, so any local user on the TARGET can write the destination as root while step 1 runs (added 2026-07-24)

- **Source:** rsync-over-tunnel post-implementation review finding F5, 2026-07-24.
- **Problem:** The `rsyncd.conf` generated by `utils/rsync-over-tunnel.sh` has `uid = 0`, `read only = false`, and `hosts allow = 127.0.0.1` — which admits every local account on the target, not just the SSH tunnel, because rsyncd cannot distinguish local users by connection. A co-tenant on the target can therefore read or write the destination rootfs as root for the (foreground, supervised) life of the daemon. Mitigations already in place: `max connections = 1` (a running transfer holds the only slot), loopback-only `address`, `hosts deny = *`, and the daemon is foreground so it exists only while watched. The script header states the single-user constraint.
- **Why deferred:** The only safe design — `auth users` plus a generated secret in a `0600` `/run` file — forces the operator to hand-carry that secret from the target host to the source host, adding a fourth artifact to a deliberately three-step runbook, for a tool whose stated scope is single-user personal machines.
- **Action on pickup:** Generate a random secret in `cmd_target_tunnel`, write it `0600` under `/run`, add `auth users` + `secrets file` to the config, and give `source-transfer` a `--password-file` / `RSYNC_PASSWORD` path — then decide how the secret crosses hosts without weakening the "nothing persists" property. openrsync accepts both `auth users` and `secrets file`; confirm each in `rsync_daemon_params[]` (`openrsync/daemon_cfg.c`, apple-oss-distributions/rsync), cite the ref you read, and add both to `OPENRSYNC_VERIFIED_KEYS` in `utils/tests/test-rsync-over-tunnel.sh`, because its key-set assertions fail until you do.

### `rsync-over-tunnel.sh`: the Homebrew-rsyncd `use chroot = no` special case on macOS is an inference, never measured (added 2026-08-05)

- **Source:** rsync-over-tunnel macOS-support plan, task A6 step 5, 2026-08-05.
- **Problem:** `cmd_target_tunnel` ships `use chroot = no` whenever `DETECTED_OS == macos` and `RSYNC_BIN != /usr/bin/rsync`. That is an *inference* from `com.apple.private.vfs.chroot` being the sole key in Apple's [`rsyncd-entitlements.plist`](https://raw.githubusercontent.com/apple-oss-distributions/rsync/main/rsyncd-entitlements.plist), not a measurement: no Homebrew rsync has ever driven a live daemon, so neither `use chroot = no` nor the `munge symlinks = no` line emitted only on that branch has run. The Apple half is measured — a macOS↔macOS run on 2026-08-07 with Apple's `/usr/bin/rsync` on both ends took the `use chroot = yes` path, the no-chroot consent box never appeared, and the daemon started and served a full transfer, so a chrooted Apple rsyncd demonstrably works.
- **Why deferred:** No Mac carrying a Homebrew rsync has been available: the 2026-08-05 macOS-support work had no Mac at all, and neither host in the 2026-08-07 run had a Homebrew rsync.
- **Action on pickup:** On a SIP-enabled Mac with Homebrew rsync, hand-edit the generated config to `use chroot = yes` and start the daemon — the open question is whether an unentitled Homebrew rsyncd can actually `chroot()`. If it starts, the inference was wrong and the special case must be dropped (it costs real confinement). If it fails with `EPERM`, the shipped behavior is correct — record the measurement here so nobody re-opens it. Either way confirm Apple's `/usr/bin/rsync` still receives `yes`.

### `rsync-over-tunnel.sh` on macOS: the cross-platform directions, the Homebrew/no-chroot branch, and payload edge cases are unverified on real hardware (added 2026-08-05)

- **Source:** rsync-over-tunnel macOS-support plan, task A7 step 4, 2026-08-05; surfaced as untracked by post-implementation review finding F8.
- **Problem:** macOS↔macOS runs green on real hardware — on 2026-08-07, both hosts on Apple's `/usr/bin/rsync`: the generated `rsyncd.conf` was fed to `openrsync`'s parser and accepted (its key set is pinned by `OPENRSYNC_VERIFIED_KEYS` in `utils/tests/test-rsync-over-tunnel.sh`), the tunnel and daemon handshake worked, both `prompt_yes_no` consent gates — on the ACL degradation and on the no-chroot path — were answered on a real TTY, `sudo` and `chroot(2)` behaved under SIP, and a 2144-file transfer ran. That run is why the config emits numeric `uid = 0`/`gid = 0`: `gid = root` does not exist on macOS (gid 0 is `wheel`), so every macOS daemon rejected the connection at attach time with `@ERROR <module>: gid 'root' invalid`. The rest of the macOS evidence is shim-driven — the ACL/xattr degradation matrix, `require_rsync`'s absolute-path resolution, and the `@RSYNCD:` greeting probe were exercised by (a) a fake `rsync` on `PATH` that `cat`s a captured `--version` blob, (b) a `sudo` shim, and (c) a perl one-liner listening on the loopback port and speaking a greeting line; automated coverage in `utils/tests/test-rsync-over-tunnel.sh` covers the parsers, `validate_options`, `validate_extra`, `compose_transfer_args`, and the generated config including its exact key set. NOT exercised by any of it: the macOS→Linux and Linux→macOS directions (so the cross-platform `-A`/`-X` mapping entry is still untested in anger), the Homebrew-rsync/no-chroot branch including its `prompt_yes_no` consent gate, which has never been answered on a real macOS TTY, and payload-level edge cases — the 2026-08-07 run used a real project directory rather than the appendix's synthetic tree, so symlink preservation (the `/rsyncd-munged/` check), hardlinks, sparse files and cleanup were not individually verified.
- **Why deferred:** The 2026-08-05 work had no Mac, only shims; the 2026-08-07 session had two Macs, both running Apple's `/usr/bin/rsync`, so it could not cover a mixed macOS/Linux pair or a Homebrew rsync.
- **Action on pickup:** Run the three-step runbook macOS→Linux and Linux→macOS on real hardware and record the result here. Drive it with the appendix's synthetic tree so symlink preservation (the `/rsyncd-munged/` check), hardlinks, sparse files and cleanup are each verified, and include a Homebrew rsync so the no-chroot branch and its consent gate run.

### `-A`/`-X` are lossy between APFS and Linux even when both sides negotiate protocol 30+ (added 2026-08-05)

- **Source:** rsync-over-tunnel macOS-support plan review, 2026-08-05.
- **Problem:** The 2026-08-05 work made `utils/rsync-over-tunnel.sh` detect whether ACLs and xattrs are *available*; it does nothing about whether they are *meaningful* across the pair. macOS ACLs are NFSv4-style and do not map onto Linux POSIX ACLs, and the xattr namespaces differ (`com.apple.*` vs `user.*`/`security.*`/`system.*`), so a macOS↔Linux transfer with `-A -X` can silently write metadata the destination cannot interpret — or drop it.
- **Why deferred:** A correct answer means either a per-direction allowlist (`--filter` on xattr names) or simply refusing `-A`/`-X` on cross-platform pairs, and choosing between those needs real-world testing on a mixed pair.
- **Action on pickup:** Start by capturing what actually survives a round trip in each direction before designing the guard. No macOS→Linux or Linux→macOS run has happened yet — see the entry on the unverified cross-platform directions.

### `.ps1` scripts are out of scope for self-update / Modular Standalone conversion (added 2026-07-17)

- **Source:** 2026-07-17 `utils/` Modular Standalone conversion.
- **Problem:** `utils/compare-directories.ps1` and `utils/robocopy-two-way.ps1` remain plain standalone PowerShell with no self-update. They cannot `source` the bash `utils-misc.sh` library, so the `check_for_updates` self-update pattern used by the other 6 converted `utils/` scripts does not apply to them.
- **Why deferred:** No bash-side change reaches them, and self-update has not been requested for the two PowerShell scripts.
- **Action on pickup:** If self-update is ever wanted for `utils/compare-directories.ps1` and `utils/robocopy-two-way.ps1`, it needs a PowerShell-native equivalent — a separate design, NOT a port of the bash `check_for_updates` pattern.

### Graceful failure when `utils-misc.sh` is absent (added 2026-07-17)

- **Source:** 2026-07-17 `utils/` Modular Standalone conversion.
- **Problem:** Every converted `utils/` script does a bare `source "${SCRIPT_DIR}/utils-misc.sh"` under `set -e`. If the library is not co-located — e.g. a user curls a single script, the exact "no longer curl-able" trade-off the Modular Standalone pattern introduces, most likely to bite `utils/dig-all.sh` given its history as a popular single-file download — the script aborts with a raw bash "No such file or directory" error instead of a friendly message.
- **Why deferred:** A one-line existence-check-and-message guard would be friendlier but DEVIATES from the bare-source parity `lxc/` and `llm/` already establish for `utils-lxc.sh` / `utils-llm.sh`. This is a cross-suite owner decision, so do NOT one-off it in `utils/`.
- **Action on pickup:** Decide across `lxc/`, `llm/`, and `utils/` together (not just `utils/`) whether to add a guard, and if so, apply the same guard shape to all three per-directory libraries in one change.

### `setup-lxc.sh` has no `main()` or execution guard (added 2026-09-16)

- **Source:** Plan Review of the container protect/unprotect work, 2026-09-16.
- **Problem:** `lxc/setup-lxc.sh` runs everything at file scope and calls `check_for_updates` outside any function — the only `lxc/` script that does. This violates AGENTS.md §Important Implementation Notes #1, and it is why nothing in the file can be sourced into a test. The file is otherwise at 0 shellcheck findings; only this restructure and the `BACKED_UP_FILES` array conversion remain.
- **Why deferred:** Restructuring a 600-line root-only host-setup script cannot be exercised without a real LXC host; the lint pass that brought the file to 0 findings was limited to quoting and declaration splits for that reason.
- **Action on pickup:** Wrap `setup-lxc.sh`'s file-scope logic in a `main()` and end the file in the if-form execution guard (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`, on three lines — AGENTS.md §Important Implementation Notes #1), matching every other `lxc/` script. Do it in the same change as "`setup-lxc.sh` tracks backups in a string, not an array" — same file, same host verification — and verify on a real LXC host in both modes: `sudo ./setup-lxc.sh <username>` and `sudo ./setup-lxc.sh --privileged`. Design-principle candidates for the same change: `backup_file`'s macOS `stat -f` branch and `get_network_interfaces`' `networksetup` branch are dead in a root-only LXC host script; `setup-lxc.sh` and `config-lxc-ssh.sh` each carry a private `backup_file` that is a DRY candidate for `lxc/utils-lxc.sh`.

### `setup-lxc.sh` tracks backups in a string, not an array (added 2026-09-16)

- **Source:** Plan Review of the container protect/unprotect work, 2026-09-16.
- **Problem:** `lxc/setup-lxc.sh` tracks backed-up files with `BACKED_UP_FILES=""`, substring-matched with `[[ "$BACKED_UP_FILES" == *"$file"* ]]`. AGENTS.md §Critical Syntax Rules mandates arrays for collections, and a path containing a space corrupts the substring match. shellcheck does not flag this pattern, so the file's 0-finding lint status does not cover it.
- **Why deferred:** Blocked on "`setup-lxc.sh` has no `main()` or execution guard": the file runs everything at file scope, so `backup_file` cannot be sourced into a test until that restructure lands, and neither change can be exercised without a real LXC host.
- **Action on pickup:** Convert `BACKED_UP_FILES` to an array and replace the substring match with the standard "check if already in array" loop pattern (AGENTS.md §Array Iteration) — `lxc/config-lxc-ssh.sh`'s own `backup_file` already has that shape. Land it with the `main()` restructure.

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

### The protect-append integrity check does not cover the re-run or the fence-scope case (added 2026-09-16)

- **Source:** Whole-branch review of the container protect/destroy work, 2026-09-16.
- **Problem:** Three residuals of the integrity check added to `lxc_protect_config`. (a) The check runs only on the append path: `lxc_is_protected "$config" && return 0` returns first, and `protect_one` short-circuits to `- Already protected` without calling the helper, so a BEGIN-only husk left by a failed append (full filesystem) is never re-detected on a later run — the re-run is exactly the scenario that makes the husk dangerous, because every gate then reports "protected" while a raw `lxc-destroy` finds no hook. (b) The check greps the whole file rather than the fenced block, so a config that legitimately carries its own `lxc.hook.destroy = /bin/false` outside the fences (hooks are a list key — see the protect helpers' comments) would mask a truncated append. (c) `destroy-lxc.sh`'s drop-in warn branch skips `daemon-reload`, so a partial `rm -rf` leaves systemd's view stale and the warning tells the operator to remove the directory but not to reload.
- **Why deferred:** All three need a failed-write or partial-removal state to exercise honestly, which this machine cannot produce (no LXC, no controllable ENOSPC), and each fix touches a path that currently fails loudly, so the branch's reviewers judged none of them merge-blocking.
- **Action on pickup:** Verify block integrity where protection is *read*, not only where it is written (the natural home is `lxc_is_protected` or a companion the callers use before trusting it, without changing the settled BEGIN-fence predicate); scope the integrity grep to the fenced range; and have the drop-in warn branch also run `daemon-reload` (or tell the operator to) when a partial removal is possible.
