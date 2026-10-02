# tests/

Repo-wide tests: behaviour that spans several suites and so has no single folder to live in. Suite-local tests stay beside their suite (`utils/tests/`, `lxc/tests/`).

## Tests

| File | Covers |
|------|--------|
| `test-self-update.sh` | `check_for_updates` in all five helper libraries (`system-setup/utils-sys.sh`, `kubernetes/utils-k8s.sh`, `lxc/utils-lxc.sh`, `llm/utils-llm.sh`, `utils/utils-misc.sh`): `DOWNLOAD_CMD` is populated on the post-restart path and the `SELF_UPDATE_RESTARTED` guard is consumed there; the up-to-date path fetches exactly twice, by repo-relative path, and leaves no `~*.tmp.??????` temps; an accepted caller update exec-restarts the new caller with the guard exported, the original arguments forwarded, and the file installed at mode 755; an accepted library update replaces the library at mode 644 and restarts so the new copy is loaded — both modes asserted exactly, because `chmod +x` on a 0600 temp yields 0711, which an executable-bit check would accept. Edge paths, on one library because the digest assertion pins the other four identical: a declined update, a nested caller (`system-modules/…`), a caller outside the library directory, an HTTP 429, and unwritable library / caller directories — every one of which must still return 0. `download_script`'s wget branch, on the same one library with `DOWNLOAD_CMD=wget` forced and a `wget` shim on `PATH`: exits 4 and 5 print `✖ Network/SSL error (wget exit N)`, 6 `✖ Authentication failed (wget exit 6)`, 8 `✖ Server error (HTTP 4xx/5xx) — check the URL above`, and any other code the generic `✖ Download failed (wget exit N)`, each returning 1 with the partial `-O` body removed; exit 0 returns 0 and keeps the file. Also pins the five bodies to a single `check_for_updates` digest and the eight `download_script` bodies — the five libraries plus the three `github/gh_org_*.sh` standalones — to a single `download_script` digest (the AGENTS.md §Helper Library Duplication roster audit, as assertions); both orchestrators' `--help`, `--skip-update`, `--debug`, no-flag and unknown-flag handling, that the original arguments survive the parse loop and reach the exec restart, that neither reaches the stale-temp sweep before rejecting a bad flag, that a partial `update_modules` failure is tolerated and a missing module is named; the three `_download-*-scripts.sh` run `cleanup_obsolete_scripts` after a partial `update_modules` failure and exit 1; and the three `github/gh_org_*.sh` spell their guard `SELF_UPDATE_RESTARTED` — the same literal the libraries use — test it as a string, consume it, and leave no retired guard name anywhere in the distributed scripts; and that no distributed script ends in the `&&`-form execution guard. Finally pins the executable bits: every tracked `*.sh` is `100755` in the index, and the five libraries (sourced) are `100644`. |
| `test-shellcheck.sh` | Every tracked `*.sh` is shellcheck-clean at the default severity (`style`), linted by a bare `shellcheck` through the repo-root `.shellcheckrc` (`external-sources=true`, `source-path=SCRIPTDIR`); an unread rc turns every library-sourcing script red with SC1091, so a green run proves the rc was used. Also fails when the rc is missing, carries a `disable=` directive, or is shadowed by a nested rc, and unsets `SHELLCHECK_OPTS` so a personal default cannot weaken the run. |

## Running

```bash
./test-all.sh                        # every suite in the repository, these included
./tests/test-self-update.sh          # exits non-zero if any assertion fails
./tests/test-shellcheck.sh           # exits non-zero naming each file with a finding
TRACE=1 ./tests/test-self-update.sh  # xtrace
```

No network, no root, no test framework — just bash 5+. `test-self-update.sh` copies every library into a `mktemp -d` sandbox beside a fake caller and a recording `curl` shim (plus a `wget` shim for the wget-branch cases), then sources it in a child bash, so the repository and the network are never touched. `test-shellcheck.sh` reads the working tree in place and writes nothing; it needs `shellcheck` on `PATH` (exits 69 without it) and lints only files in the git index, so a new `*.sh` is checked once it is staged. A full pass takes about 80 seconds.

## Adding Tests

1. One file per mechanism; sandbox anything that writes, and shim anything that reaches the network.
2. For assertions, use `assert_eq` / `assert_contains` / `assert_not_contains` (`test-shellcheck.sh` reports per file and carries no copy). `test-self-update.sh` holds one of four copies of the trio — `utils/tests/test-rsync-over-tunnel.sh`, `utils/tests/test-rsync-two-way.sh`, and `lxc/tests/test-protect-lxc.sh` carry the other three; change all four files together.
3. Source a script under test bare — `source "$f"`, never `source "$f" || true`. Every distributed script with a `main` (or `main_<module>`) entry point ends in the if-form execution guard (AGENTS.md §Important Implementation Notes #1), which returns 0 when sourced; `|| true` would suspend `set -e` for the whole sourced file and hide any failure in it, including a guard that returns 1.
4. Disarm a sourced library's own EXIT trap (`trap - EXIT`) before asserting that no temp file was left behind. That trap is Layer 2 of AGENTS.md §Defense-in-depth Cleanup and reaps everything when the child exits, so the assertion would otherwise pass with Layer 1's per-branch `rm -f` deleted.
5. Nothing in `tests/` is listed in any `get_script_list()`: development-only, never distributed to target hosts. These files carry no `main`/execution guard for the same reason — nothing sources them.
6. A new suite needs no registration: commit it as `<dir>/test-<name>.sh` at mode `100755` and `test-all.sh` picks it up from the git index.
