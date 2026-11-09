# 0001. Target libghostty-vt 1.0 stable ABI

**Status:** Accepted (2026-11-09)

## Context
libghostty-vt 1.0.0 (tag `vt-1.0.0`, 2026-11-06) declares its C ABI stable under semver: minor releases only add; behaviour changes ship as new functions. Every existing Dart binding (`libghostty`, `ghostty_vte`) is pinned to pre-1.0 commits. See `../research/2026-11-09-libghostty-and-xterm.md`.

## Decision
- Bind against libghostty-vt **1.x**, starting at 1.0.0. Nothing pre-1.0.
- Pin the exact upstream version and its source tarball hash in one place (`native/upstream.json`).
- Check the runtime version with `ghostty_version()` on load and fail with a clear error below the minimum.
- Treat newer optional symbols as feature-detected (`GHOSTTY_UNSUPPORTED` → `UnsupportedError` in Dart).

## Consequences
- We can promise users ABI stability through the 1.x line.
- Zig 0.17.x is required for source builds; the Zig version is not covered by upstream's guarantees, so it is pinned too.
- The snapshot byte format is not stable upstream; we will not persist snapshots across library versions.
