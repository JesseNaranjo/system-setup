# tests/

Repo-wide tests: behaviour that spans several suites and so has no single folder to live in. Suite-local tests stay beside their suite (`utils/tests/`).

## Tests

| File | Covers |
|------|--------|
| `test-self-update.sh` | `check_for_updates` in all five helper libraries (`system-setup/utils-sys.sh`, `kubernetes/utils-k8s.sh`, `lxc/utils-lxc.sh`, `llm/utils-llm.sh`, `utils/utils-misc.sh`): `DOWNLOAD_CMD` is populated on the post-restart path and the `SELF_UPDATE_RESTARTED` guard is consumed there; the up-to-date path fetches exactly twice, by repo-relative path, and leaves no `~*.tmp.??????` temps; an accepted caller update exec-restarts the new caller with the guard exported, the original arguments forwarded, and the file installed executable; an accepted library update replaces the library at mode 644 and restarts so the new copy is loaded. Edge paths, on one library because the digest assertion pins the other four identical: a declined update, a nested caller (`system-modules/…`), a caller outside the library directory, an HTTP 429, and unwritable library / caller directories — every one of which must still return 0. Also pins the five bodies to a single `check_for_updates` digest (the AGENTS.md §Helper Library Duplication roster audit, as an assertion); both orchestrators' `--help`, `--skip-update`, `--debug`, no-flag and unknown-flag handling, that the original arguments survive the parse loop and reach the exec restart, that neither reaches the stale-temp sweep before rejecting a bad flag, that a partial `update_modules` failure is tolerated and a missing module is named; the three `_download-*-scripts.sh` run `cleanup_obsolete_scripts` after a partial `update_modules` failure and exit 1; and the three `github/gh_org_*.sh` spell their guard `GH_SCRIPTS_UPDATED`, test it as a string, and consume it. |

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
4. Disarm a sourced library's own EXIT trap (`trap - EXIT`) before asserting that no temp file was left behind. That trap is Layer 2 of AGENTS.md §Defense-in-depth Cleanup and reaps everything when the child exits, so the assertion would otherwise pass with Layer 1's per-branch `rm -f` deleted.
5. Nothing in `tests/` is listed in any `get_script_list()`: development-only, never distributed to target hosts. These files carry no `main`/execution guard for the same reason — nothing sources them.
