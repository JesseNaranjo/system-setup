# Future TODOs

Deferred work items discovered during plans and reviews. Each entry explains why it was deferred and what a future implementation would need to know.

## utils/dig-all.sh

- **Reverse-lookup convenience (`-x IP`).** Accepting an IP argument and running `dig -x IP` across the same record-type loop would be a small, self-contained addition. Deferred during the 2026-04-18 standardization because the reverse-lookup use case is niche enough that users can invoke `dig -x` directly.
- **Resolver port-suffix support (`SERVER#PORT`).** `dig` accepts `@1.1.1.1#5353` syntax to target a resolver on a non-standard port, but `validate_resolver`'s regex `^[A-Za-z0-9][A-Za-z0-9._:-]*$` rejects `#`. Surfaced during the 2026-04-18 post-implementation review as a genuine feature gap. Deferred because (a) non-standard DNS ports are uncommon outside test labs, and (b) adding `#` to the allowlist requires confirming it does not weaken injection defenses — a separate analysis.

## system-setup/utils-sys.sh

- **Add HTTP timeouts to `download_script` and fix the `-fsSL || echo "000"` HTTP-error bug.** `download_script` calls curl/wget with no `--connect-timeout`/`--max-time` (curl) or `--connect-timeout=`/`--timeout=` (wget). On a flaky network or DNS sinkhole, callers can hang for the system default (5+ minutes) before falling back. Separately, the curl branch's `-fsSL ... -w "%{http_code}" ... || echo "000"` produces `"404000"` (not `"404"`) on HTTP errors because curl with `-f` still writes `%{http_code}` via `-w` AND exits non-zero, so the `|| echo "000"` appends — breaking the case match. The private `system-setup-private` repo's pings-loop.sh self-update plan (2026-04-27) shipped both fixes atomically across `utils/pings-loop.sh`, `utils/tools-update.sh`, and `tmux/utils-tmux.sh` — backport to the public repo for parity. Add `--connect-timeout 5 --max-time 30` (curl) and `--connect-timeout=5 --timeout=30` (wget); drop `-f` from the curl flags and only set `"000"` when the captured `http_status` is empty (signals a transport failure with no HTTP response). Verified via [everything.curl.dev/usingcurl/timeouts.html](https://everything.curl.dev/usingcurl/timeouts.html).
