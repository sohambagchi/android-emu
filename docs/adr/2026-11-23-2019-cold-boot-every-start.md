# Cold boot on every start

**Status:** accepted

**Context:** Snapshots make boots faster but carry state between runs, and can resume a snapshot taken under a different kernel.
**Decision:** `emu-up` always passes `-no-snapshot`: cold boot, no snapshot written.
**Alternatives:** quick-boot snapshots — faster, but runs stop being comparable.
**Consequences:** every start costs about 20–25 s; only the data partition persists.
