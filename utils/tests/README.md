# utils/tests

Unit tests for the pure functions in `utils/`.

## Tests

| File | Covers |
|------|--------|
| `test-rsync-over-tunnel.sh` | `rsync-over-tunnel.sh`: the `rsync --version` implementation / capability / protocol parsers, the `@RSYNCD:` greeting parser, `detect_os`, `require_rsync`'s wiring, `resolve_transfer_path`'s option-injection guards, `validate_options` (port / module / control-character rejection), `validate_extra` (every refused ssh and rsync spelling after `--`, the accepted everyday options, and `main`'s call to it before dispatch), `cmd_source_tunnel`'s ssh option-injection guard, `cmd_target_tunnel`'s refusal to write over an existing `--conf` or lock file, every confinement directive in the generated `rsyncd.conf` including the chroot ↔ `munge symlinks` pairing, `compose_transfer_args` (the flag set a root-privileged rsync runs with), `_sanitize_ansi`, and `print_warning_box`'s column alignment |
| `test-rsync-two-way.sh` | `rsync-two-way.sh`: `validate_sync_args` — the `user@host` / `host` split into `REMOTE_USER_HOST` and `REMOTE_HOST`, the option-injection guard on a remote user or host that begins with `-` (including the dash-leading user part a host-only check misses, and a dash-leading host after a second `@`) and on a local directory that begins with `-` even when that directory exists, the `./` escape its error message offers, the missing-colon format error, and — in one child-process run with `ssh` and `rsync` shimmed — that `main` refuses a bad spec before either runs |

`rsync`, `sudo`, `curl` and `ssh` are shimmed where `test-rsync-over-tunnel.sh` needs them, and
`test-rsync-two-way.sh` shims `ssh` and `rsync` for its one child-process check and
stops before either would run elsewhere, so both suites run the same on a host that
has none of them installed.

## Running

```bash
./test-rsync-over-tunnel.sh          # exits non-zero if any assertion fails
./test-rsync-two-way.sh              # exits non-zero if any assertion fails
TRACE=1 ./test-rsync-over-tunnel.sh  # xtrace
```

No network, no root, no second host, no test framework — just bash. It does
require **bash 5+**, the same baseline as the rest of `utils/`: each suite sources
its script under test, which sources `utils-misc.sh`, which asserts the version
and exits 69 on an older shell. Sourcing is safe because each script's
`BASH_SOURCE == $0` guard keeps `main()`, and with it `check_for_updates`, from running.

`print_warning_box`'s alignment assertions measure **characters**, so they need a
UTF-8 locale; under `LC_ALL=C` they compare bytes and will report a mismatch on
the multi-byte rows.

Everything here is pure text processing or pure decision logic, except one child-process check in each suite (`ssh` shimmed, plus `rsync` in `test-rsync-two-way.sh`; `SELF_UPDATE_RESTARTED=1` so nothing is fetched), proving `main` refuses an option-like or denied argument before `ssh` can start. Daemon startup,
chroot enforcement, and real transfers need two hosts and are still covered only
by manual verification — see `docs/backlog.md` for exactly what that manual
pass did and did not exercise.

## Adding Tests

1. Add fixtures as `readonly` variables holding real captured output — not paraphrases.
2. Use `assert_eq` / `assert_contains` / `assert_not_contains`. This directory holds two of the four copies of the trio — `test-rsync-over-tunnel.sh` and `test-rsync-two-way.sh`; `tests/test-self-update.sh` and `lxc/tests/test-protect-lxc.sh` carry the other two (all four are development-only, so the suite-isolation rule that forbids sharing does not apply and neither does the AGENTS.md §Helper Library Duplication roster); change all four files together.
3. These tests are NOT in `_download-utils-scripts.sh`'s `get_script_list()`: they are
   development-only and are not distributed to target hosts.
