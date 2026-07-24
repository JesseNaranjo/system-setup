# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), date-based, newest first.
This changelog begins 2026-07-06. Entries below capture the project's major
features as of that date; earlier history is not individually recorded.

## [2026-07-24]

### Added

- `utils/rsync-over-tunnel.sh` — one-way LXC lxcpath migration to another host over an SSH tunnel, using a throwaway root rsync daemon bound to loopback on the target. Preserves numeric ids / hardlinks / ACLs / xattrs / sparseness for idmapped container rootfs; leaves no persistent privilege or config behind (interactive sudo, no `NOPASSWD` drop-in). Standardized to Modular Standalone (sources `utils-misc.sh`, self-updates via `check_for_updates`). Subcommands: `target-tunnel`, `source-tunnel`, `source-transfer`. `--path` is required (no auto-detection). SSH target is guarded against option-injection; no cipher is forced (ssh negotiates unless `--cipher` is given).

## [2026-07-17]

### Added
- `utils/utils-misc.sh` — shared utilities library for `utils/` (colors, prompts, self-update functions), the 5th per-directory parity copy of the canonical helper set alongside `utils-sys.sh`, `utils-k8s.sh`, `utils-lxc.sh`, and `utils-llm.sh`.
- `utils/_download-utils-scripts.sh` — self-updating script manager for `utils/`, mirroring the `_download-lxc-scripts.sh` / `_download-ollama-scripts.sh` pattern.
- `utils/reset-macOS-display-settings.sh` — new Modular Standalone utility that resets the macOS WindowServer display-preference plists (system-wide and per-user ByHost), backing up each plist before removal and requiring explicit confirmation. Replaces a previously broken, untracked stub.
- `utils/unlock-keychain.sh` — new Modular Standalone utility that unlocks the macOS login keychain in the current shell/session, so `security find-generic-password` works from a raw SSH shell.

### Changed
- Converted 4 previously-Standalone `utils/` scripts (`dig-all.sh`, `push-ghostty-terminfo.sh`, `rsync-two-way.sh`, `services-check.sh`) to Modular Standalone: each now sources `utils-misc.sh` and self-updates via `check_for_updates()` instead of duplicating helpers and self-update logic inline. `monitor-battery.sh` and `disable-kvm-module.sh` were intentionally kept as Lightweight standalone scripts (trivial one-offs, no shared utilities needed).
- Dropped the inline `self_update` function from `services-check.sh` and `push-ghostty-terminfo.sh` now that both source `utils-misc.sh`'s shared `check_for_updates()`.

## [2026-07-15]

### Fixed
- Self-update diff preview on macOS — the diff shown before a script self-updates now feature-detects `diff --color` (GNU diff supports it, BSD/macOS diff does not), fixing a silently-empty preview box on macOS. Applied to every copy of the shared `show_diff_box` helper.
- Shell-helper robustness (repo-wide) — hardened the duplicated `cleanup`, `sweep_stale_temps`, `self_update`, and `print_warning_box` helpers against EXIT-trap exit-code clobbering, a rare `set -e` abort during temp cleanup, an unreachable post-`exec` statement, and leaked function-local variables.
- **Sourced `utils-*.sh` libraries no longer get the executable bit on self-update (repo-wide).** `check_for_updates()` installed the downloaded utils library with `chmod +x` in its "Check utils file" branch — the same path as the executable caller — so every accepted update marked the sourced library executable. The utils branch now installs with `chmod 644` in all four copies (`system-setup/utils-sys.sh`, `kubernetes/utils-k8s.sh`, `llm/utils-llm.sh`, `lxc/utils-lxc.sh`); the caller branch keeps `chmod +x`. Also removed the utils entry from `llm/_download-ollama-scripts.sh` and `lxc/_download-lxc-scripts.sh` `get_script_list()` (their `update_modules` loop was a second `chmod +x` site), matching the other orchestrators; the library is still updated by `check_for_updates`. Restored the three drifted library files to mode `100644`.

## [2026-07-14]

### Added
- Ghostty terminfo push — `utils/push-ghostty-terminfo.sh` copies the local `xterm-ghostty` terminfo entry to a remote SSH host, defaulting to a **system-wide** install (`/usr/share/terminfo` via remote sudo) so every user including `root`/`su` resolves it, with a `--user` fallback to `~/.terminfo`. Complements Ghostty's per-user `ssh-terminfo` shell integration for cases where it is skipped (wrapper tools, non-interactive shells) or insufficient (root/other users). Multiplexes all SSH connections over one ControlMaster socket, so you authenticate to the host at most once — an interactive password/passphrase on a TTY, or key-based auth for non-interactive runs (cron, `ssh -T`); the system-wide default also prompts once for the remote sudo password. Idempotent, self-updating, single-host.
- Ghostty configuration reference — `configs/ghostty.md` documents the recommended `shell-integration-features = ssh-terminfo,ssh-env` settings and when to fall back to the push script.

## [2026-07-06]

### Added
- System setup suite — modular, idempotent Linux/macOS orchestrator (`system-setup/system-setup.sh`) that installs packages and configures git, nano, tmux, shell, swap, SSH socket activation, timezone, `/etc/issue`, systemd-networkd migration, container static IP, and APT DEB822 sources, with a choice of user or system scope.
- Remote desktop provisioning — `install-desktop.sh` sets up TigerVNC and XRDP with XFCE4 sessions, clipboard support, and TLS certificate management on Linux.
- LXC container management — full lifecycle scripts (`lxc/`) to configure the host, create containers (auto-detecting distro, release, and architecture), start/stop/restart them via systemd, watch live status, and back up or restore with 7z compression, for both privileged and unprivileged containers; includes flags for running Kubernetes inside LXC (cgroup delegation, swap restriction, `/proc/sys` writability, AppArmor).
- Kubernetes cluster setup — orchestrated, kubeadm-based provisioning (`kubernetes/`) with CRI-O runtime, kernel-module and sysctl configuration, swap disabling, Helm and Minikube installation, certificate lifecycle management, cluster init/join/validate, and LXC-container awareness.
- Ollama LLM runner — GNU screen launchers (`llm/`) for running Ollama locally or as a network-accessible API server, each with integrated GPU (nvtop) and CPU (htop) monitoring panes.
- GitHub organization tooling — bulk `gh`/`jq` scripts (`github/`) that migrate repositories between orgs (refs, LFS, wikis, labels, milestones, issues, PRs-as-issues, discussions) and bulk close/lock/delete issues or delete repositories, defaulting to dry-run for safety.
- Cross-platform utilities — standalone maintenance scripts (`utils/`) for DNS record queries, local service health checks, two-way rsync/Robocopy synchronization, battery monitoring, and macOS/KVM fixes.
- Self-updating scripts — each suite can fetch its latest version from GitHub on run, showing a diff and prompting before overwriting so local copies stay current without manual reinstalls.
- Configuration references and walkthroughs — curated notes (`configs/`, `walkthroughs/`, `raspberry-pi/`, and top-level docs) covering application configs (git, nano, tmux, shell, htop, VS Code, GNOME, macOS, Steam/Bazzite), setup walkthroughs, Raspberry Pi builds, and hardware notes (DKMS, GRUB, mDNS, NVIDIA drivers).
