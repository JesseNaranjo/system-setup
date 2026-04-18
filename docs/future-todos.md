# Future TODOs

Deferred work items discovered during plans and reviews. Each entry explains why it was deferred and what a future implementation would need to know.

## utils/dig-all.sh

- **Reverse-lookup convenience (`-x IP`).** Accepting an IP argument and running `dig -x IP` across the same record-type loop would be a small, self-contained addition. Deferred during the 2026-04-18 standardization because the reverse-lookup use case is niche enough that users can invoke `dig -x` directly.
