# github/tests

Unit tests for the three `github/gh_org_*.sh` standalones.

## Tests

| File | Covers |
|------|--------|
| `test-gh-org.sh` | `gh_org_copy.sh`: `dest_milestone_number_by_title`, and through it `copy_labels_and_milestones`' existence check, finds a milestone whose title holds double quotes on the destination's second page, so it is not created again, while a missing one is created once; `create_issue_in_dest` puts that milestone's destination number on the copied issue, and prints nothing on stdout (the "skipped" signal its callers test for) both for a failed issue POST, which it reports on stderr with the response and follows with no PATCH, and for an existing issue, whose skip message goes to stderr; `copy_prs_as_archival_issues` attributes a deleted account's PR, issue comment, review comment and review to `@unknown`; `prepare_workdir` creates a new directory under `TMPDIR` when `WORKDIR` is unset, accepts (and creates) a `WORKDIR` you own, freezes one reached through a symlinked parent as its physical path, and exits 77 on a symlink, even one to a directory you own, and on a directory you do not own (that case is skipped as root). `gh_org_delete_issues.sh`: a failed close is counted, gh's own error reaches the user, and the run goes on to the next repository and prints `Issues failed: 1`; a repository whose issues cannot be listed counts as skipped, not processed. Both delete scripts: an unknown option exits 64, as do `gh_org_delete_repos.sh`'s "neither `--all` nor a repository" and "`--all` with a repository" errors, and `--help` exits 0 |

## Running

```bash
./github/tests/test-gh-org.sh          # exits non-zero if any assertion fails
TRACE=1 ./github/tests/test-gh-org.sh  # xtrace
```

No network, no GitHub account, no root, no test framework — just bash and `jq`
(the suite exits 69 without `jq`). `gh` is never run, so it need not be
installed: each case runs a child bash that sources one script with
`SELF_UPDATE_RESTARTED=1` set — its if-form execution guard keeps `main()` from
running — and replaces `gh` or `gh_api` with a function that dispatches on its
arguments to canned output. The cases that call `main()` also stub
`sweep_stale_temps`, which would otherwise act on `github/` itself. The
usage-error cases run sandbox copies of the two delete scripts as child
processes instead, because `show_help` prints the script's own header from
`$0`, with a failing `gh` first on `PATH`. Argument parsing comes first in their
`main()`, so nothing else runs; should a bad argument ever get past it, the
stale-temp sweep acts on the sandbox and the first `gh` call fails without
reaching the real one.

`_gh_serve` serves a canned body the way `gh api` does: the second page only to
a `--paginate` call, and through the call's own `--jq` filter when it has one.
That filter runs under `jq` here, while `gh` runs it under gojq, whose grammar is
looser — gojq accepts an unparenthesised `+` inside an object value, `jq` does
not. A filter only gojq parses fails here; parenthesise it, which means the same
to both.

## Adding Tests

1. Add canned API bodies as the JSON the real endpoint returns and serve them
   through `_gh_serve`, so the script's own `--jq` filter and `jq` pipelines
   process them. A body pre-filtered by hand skips the filter under test.
2. Give every call a case makes an arm in its shim; the `*) return 1` arm fails
   any other call, the way an unreachable API would.
3. Use `assert_eq` / `assert_contains` / `assert_not_contains`. This file holds
   the fifth copy of the trio — `tests/test-self-update.sh`,
   `utils/tests/test-rsync-over-tunnel.sh`, `utils/tests/test-rsync-two-way.sh`
   and `lxc/tests/test-protect-lxc.sh` carry the other four (all five are
   development-only, so the suite-isolation rule that forbids sharing does not
   apply and neither does the AGENTS.md §Helper Library Duplication roster);
   change all five files together.
4. Nothing here is distributed to target hosts: each `gh_org_*.sh` self-updates
   only its own file. The suite carries no `main`/execution guard for the same
   reason — nothing sources it.
