# utils/tests

Unit tests for the pure functions in `utils/`.

## Tests

| File | Covers |
|------|--------|
| `test-rsync-over-tunnel.sh` | `rsync-over-tunnel.sh`: the `rsync --version` implementation / capability / protocol parsers, the `@RSYNCD:` greeting parser, `detect_os`, `require_rsync`'s wiring, `resolve_transfer_path`'s option-injection guards, `validate_options` (port / module / control-character rejection), `cmd_source_tunnel`'s ssh option-injection guard, `cmd_target_tunnel`'s refusal to write over an existing `--conf` or lock file, every confinement directive in the generated `rsyncd.conf` including the chroot ↔ `munge symlinks` pairing, `compose_transfer_args` (the flag set a root-privileged rsync runs with), `_sanitize_ansi`, and `print_warning_box`'s column alignment |

`rsync` and `sudo` are shimmed where a test needs them, so the suite runs the
same on a host that has neither installed.

## Running

```bash
./test-rsync-over-tunnel.sh          # exits non-zero if any assertion fails
TRACE=1 ./test-rsync-over-tunnel.sh  # xtrace
```

No network, no root, no second host, no test framework — just bash. It does
require **bash 5+**, the same baseline as the rest of `utils/`: the suite sources
the script under test, which sources `utils-misc.sh`, which asserts the version
and exits 69 on an older shell. Sourcing is safe because the script's
`BASH_SOURCE == $0` guard keeps `main()` from running.

`print_warning_box`'s alignment assertions measure **characters**, so they need a
UTF-8 locale; under `LC_ALL=C` they compare bytes and will report a mismatch on
the multi-byte rows.

Everything here is pure text processing or pure decision logic. Daemon startup,
chroot enforcement, and real transfers need two hosts and are still covered only
by manual verification — see `docs/backlog.md` for exactly what that manual
pass did and did not exercise.

## Adding Tests

1. Add fixtures as `readonly` variables holding real captured output — not paraphrases.
2. Use `assert_eq` / `assert_contains` / `assert_not_contains`. They are a deliberate second copy of the trio in `tests/test-self-update.sh` (both files are development-only, so the suite-isolation rule that forbids sharing does not apply and neither does the AGENTS.md §Helper Library Duplication roster); change both files together.
3. These tests are NOT in `_download-utils-scripts.sh`'s `get_script_list()`: they are
   development-only and are not distributed to target hosts.
