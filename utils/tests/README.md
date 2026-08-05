# utils/tests

Unit tests for the pure functions in `utils/`.

## Tests

| File | Covers |
|------|--------|
| `test-rsync-over-tunnel.sh` | `rsync-over-tunnel.sh` version/capability parsers, daemon-greeting parser, generated daemon config |

## Running

```bash
./test-rsync-over-tunnel.sh          # exits non-zero if any assertion fails
TRACE=1 ./test-rsync-over-tunnel.sh  # xtrace
```

No dependencies: pure bash, no network, no root, no second host. Tests source
the script under test — its `BASH_SOURCE == $0` guard keeps `main()` from running.

These tests cover only logic that is pure text processing. Daemon startup,
chroot behaviour, and real transfers need two hosts and are covered by manual
verification.

## Adding Tests

1. Add fixtures as `readonly` variables holding real captured output — not paraphrases.
2. Use `assert_eq` / `assert_contains` / `assert_not_contains`.
3. These tests are NOT in `_download-utils-scripts.sh`'s `get_script_list()`: they are
   development-only and are not distributed to target hosts.
