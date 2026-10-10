# lxc/tests

Unit tests for the `lxc/` suite: the container-protection helpers in `lxc/utils-lxc.sh`, and launcher behaviour no helper owns.

## Tests

| File | Covers |
|------|--------|
| `test-protect-lxc.sh` | `lxc_valid_name`, `lxc_resolve_path`, `lxc_is_protected`, `lxc_protect_config`, `lxc_unprotect_config`, `lxc_protected_since`, and `lxc_list_containers`: the protect/unprotect round trip, idempotent double-protect, repeated protect/unprotect cycles leaving no residue, a successful unprotect with a real config line after the block, an unterminated last line, a block with no END fence, a stray second BEGIN fence, fences in the wrong order, a fenced block with a hand-deleted date line, and a missing config file. Launchers: `stop-lxc.sh` hands `lxc-stop` each name `/usr/bin/lxc-ls -1 --running` lists, reports an empty list as no running containers, and exits 1 when `lxc-ls` fails; `create-lxc.sh` and `backup-lxc.sh` refuse `../etc`, `a/b` and `.hidden` with exit 64 and the rejected name — `create-lxc.sh` before any `lxc-*` or `sudo` call — and let a valid name through; `create-lxc.sh` warns and still reaches `lxc-create` when `/etc/os-release` names no distribution or release; `backup-lxc.sh` and `restore-lxc.sh` answer `--help`, a bad name and a missing input before they check for `7z`; `backup-lxc.sh` hands `7z` each option of all three compression presets as its own argument; `restore-lxc.sh` reads the archive's top-level name although `head -1` closes the pipe on `tar`, refuses `..` as that name with exit 65 and `a/b` as the new name with exit 64. `config-lxc-ssh.sh`: `configure_container_ssh` appends the key to a plain home's `authorized_keys`, and refuses a home that resolves outside the rootfs and a symlinked `.ssh` or `authorized_keys`, leaving the link target untouched |

No LXC, no root, no network — every case runs in a `mktemp -d` sandbox. Run it
as your own user: it refuses root with exit 64, because the launcher cases rely
on `lxc_resolve_path` resolving under the sandboxed `HOME`, which root bypasses
for the real `/var/lib/lxc`; the EUID-0 branch of `lxc_resolve_path` is
therefore not exercised here.

## Running

```bash
./lxc/tests/test-protect-lxc.sh          # exits non-zero if any assertion fails
TRACE=1 ./lxc/tests/test-protect-lxc.sh  # xtrace
```

## Adding Tests

1. Add fixtures with `make_container`, not paraphrased config content.
2. Use `assert_eq` / `assert_contains` / `assert_not_contains`. They are one of the
   trio's five copies — `tests/test-self-update.sh`, `utils/tests/test-rsync-over-tunnel.sh`,
   `utils/tests/test-rsync-two-way.sh` and `github/tests/test-gh-org.sh` carry the other
   four (all five are development-only, so the suite-isolation rule that forbids sharing
   does not apply and neither does the AGENTS.md §Helper Library Duplication roster);
   change all five files together.
3. This file is NOT in `_download-lxc-scripts.sh`'s `get_script_list()`: it is
   development-only and is not distributed to target hosts. It carries no
   `main`/execution guard for the same reason — nothing sources it.
4. Drive a launcher through `_lxc_main <script> <args…>`, which prints
   `<rc>|<output>`. It sources the script in a child bash (its `if`-form
   execution guard keeps `main()` from running on source), stubs
   `sweep_stale_temps`, `check_for_updates`, `check_required_tools`,
   `prompt_yes_no`, `lxc-info`, `lxc-create`, `sudo`, `7z` and `tar` (whose
   listing's top-level name is `TAR_TOP`, default `restored-box`), points `HOME`
   into the sandbox and reads stdin from `/dev/null`. `EXTRA_STUBS='…' _lxc_main …`
   evaluates further stub definitions after those, to add or replace a stub for
   one case; a command run by absolute path, such as `/usr/bin/lxc-ls`, is
   stubbed by a function of that name. Before a case can reach any other
   external command, add a stub for it — a test never runs a real `lxc-*`,
   `sudo` or `rm`.
5. Drive `config-lxc-ssh.sh` through `_ssh_configure <container>`, which
   prints `<rc>|<output>` of `configure_container_ssh` for a container under
   `SSH_ROOT` (build one with `make_ssh_container`), with the sshd probe,
   `chown` and `backup_file` stubbed.
