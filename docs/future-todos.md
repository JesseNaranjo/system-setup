# Future TODOs

Deferred work items discovered during plans and reviews. Each entry explains why it was deferred and what a future implementation would need to know.

## utils/dig-all.sh

- **Reverse-lookup convenience (`-x IP`).** Accepting an IP argument and running `dig -x IP` across the same record-type loop would be a small, self-contained addition. Deferred during the 2026-04-18 standardization because the reverse-lookup use case is niche enough that users can invoke `dig -x` directly.
- **Resolver port-suffix support (`SERVER#PORT`).** `dig` accepts `@1.1.1.1#5353` syntax to target a resolver on a non-standard port, but `validate_resolver`'s regex `^[A-Za-z0-9][A-Za-z0-9._:-]*$` rejects `#`. Surfaced during the 2026-04-18 post-implementation review as a genuine feature gap. Deferred because (a) non-standard DNS ports are uncommon outside test labs, and (b) adding `#` to the allowlist requires confirming it does not weaken injection defenses — a separate analysis.
