# lxc/tests

Unit tests for the `lxc/` suite: the container-protection helpers in `lxc/utils-lxc.sh`, and launcher behaviour no helper owns.

## Tests

| File | Covers |
|------|--------|
| `test-protect-lxc.sh` | `lxc_valid_name`, `lxc_resolve_path`, `lxc_is_protected`, `lxc_protect_config`, `lxc_unprotect_config`, `lxc_protected_since`, and `lxc_list_containers`: the protect/unprotect round trip, idempotent double-protect, repeated protect/unprotect cycles leaving no residue, a successful unprotect with a real config line after the block, an unterminated last line, a block with no END fence, a stray second BEGIN fence, fences in the wrong order, a fenced block with a hand-deleted date line, and a missing config file. Launchers: `stop-lxc.sh` and `restart-lxc.sh` capture `lxc-ls -1 --running` and split it with `mapfile` (pinned as source text — both call `/usr/bin/lxc-ls` by absolute path, which no stub can replace); `create-lxc.sh` and `backup-lxc.sh` refuse `../etc`, `a/b` and `.hidden` with exit 64 before any `lxc-*` or `sudo` call, and let a valid name through; `backup-lxc.sh` hands `7z` each option of all three compression presets as its own argument; `restore-lxc.sh` reads the archive's top-level name although `head -1` closes the pipe on `tar` |

No LXC, no root, no network — every case runs in a `mktemp -d` sandbox or
reads a launcher's source text. Run it as your own user: the `lxc_resolve_path`
case asserts the non-root path, the EUID-0 branch cannot be exercised here, and
the launcher cases rely on `lxc_resolve_path` resolving under the sandboxed
`HOME`, which root bypasses for `/var/lib/lxc`.

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
   `check_for_updates`, `check_required_tools`, `prompt_yes_no`, `lxc-info`,
   `lxc-create`, `sudo`, `7z` and `tar`, points `HOME` into the sandbox and reads
   stdin from `/dev/null`. Before a case can reach any other external command,
   add a stub for it to `_lxc_main` — a test never runs a real `lxc-*`, `sudo`
   or `rm`.
