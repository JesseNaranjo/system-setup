# tests/

Repo-wide tests: behaviour that spans several suites and so has no single folder to live in. Suite-local tests stay beside their suite (`utils/tests/`).

## Tests

| File | Covers |
|------|--------|
| `test-self-update.sh` | `check_for_updates` in all five helper libraries (`system-setup/utils-sys.sh`, `kubernetes/utils-k8s.sh`, `lxc/utils-lxc.sh`, `llm/utils-llm.sh`, `utils/utils-misc.sh`): `DOWNLOAD_CMD` is populated on the post-restart path and the `SCRIPTS_UPDATED` guard is consumed there, the up-to-date path fetches exactly twice and leaves no `~*.tmp.??????` temps, and the accept path exec-restarts the new caller with `SCRIPTS_UPDATED=1` exported. Also pins the five bodies to a single `check_for_updates` digest (the AGENTS.md §Helper Library Duplication roster audit, as an assertion); `kubernetes-setup.sh`'s `--help`, `--skip-update`, `--debug`, and unknown-flag handling. |

## Running

```bash
./tests/test-self-update.sh          # exits non-zero if any assertion fails
TRACE=1 ./tests/test-self-update.sh  # xtrace
```

No network, no root, no test framework — just bash 5+. Every library is copied into a `mktemp -d` sandbox beside a fake caller and a recording `curl` shim, then sourced in a child bash, so the repository and the network are never touched.

## Adding Tests

1. One file per mechanism; sandbox anything that writes, and shim anything that reaches the network.
2. Use `assert_eq` / `assert_contains` / `assert_not_contains`. They are a deliberate second copy of the trio in `utils/tests/test-rsync-over-tunnel.sh`; change both files together.
3. A script that ends in `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"` returns 1 when sourced and its own `set -e` then exits the sourcing shell — source it as `source "$f" || true`.
4. Nothing in `tests/` is listed in any `get_script_list()`: development-only, never distributed to target hosts.
