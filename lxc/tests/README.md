# lxc/tests

Unit tests for the container-protection helpers in `lxc/utils-lxc.sh`.

## Tests

| File | Covers |
|------|--------|
| `test-protect-lxc.sh` | `lxc_valid_name`, `lxc_resolve_path`, `lxc_is_protected`, `lxc_protect_config`, `lxc_unprotect_config`, `lxc_protected_since`, and `lxc_list_containers`: the protect/unprotect round trip, idempotent double-protect, repeated protect/unprotect cycles leaving no residue, a successful unprotect with a real config line after the block, an unterminated last line, a block with no END fence, a stray second BEGIN fence, fences in the wrong order, a fenced block with a hand-deleted date line, and a missing config file |

No LXC, no root, no network — every case runs against a config file in a
`mktemp -d` sandbox. Run it as your own user: the `lxc_resolve_path` case
asserts the non-root path, and the EUID-0 branch cannot be exercised here.

## Running

```bash
./lxc/tests/test-protect-lxc.sh          # exits non-zero if any assertion fails
TRACE=1 ./lxc/tests/test-protect-lxc.sh  # xtrace
```

## Adding Tests

1. Add fixtures with `make_container`, not paraphrased config content.
2. Use `assert_eq` / `assert_contains` / `assert_not_contains`. They are the trio's
   **third** copy — `tests/test-self-update.sh` and `utils/tests/test-rsync-over-tunnel.sh`
   carry the other two (all three are development-only, so the suite-isolation rule
   that forbids sharing does not apply and neither does the AGENTS.md §Helper Library
   Duplication roster); change all three files together.
3. This file is NOT in `_download-lxc-scripts.sh`'s `get_script_list()`: it is
   development-only and is not distributed to target hosts. It carries no
   `main`/execution guard for the same reason — nothing sources it.
