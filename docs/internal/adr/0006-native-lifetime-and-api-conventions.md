# 0006. Native lifetime and public API conventions for ghostty_dart

**Status:** Accepted (2026-11-09)

## Context
The idiomatic API (10 modules, built and reviewed one task at a time) needed shared rules so modules fit together, stay forward compatible across libghostty-vt 1.x, and never corrupt memory. Several rules came from bugs found in review.

## Decision
The full conventions live in `docs/internal/architecture/ghostty_dart-conventions.md`. The key rules:

- **No `dart:ffi` types in the public API.** This keeps a future wasm backend possible. It is enforced by `test/e2e/public_api_test.dart`, which runs an analyzer audit.
- **Raw enums are int constants** (`EnumStyle.intConstants` in ffigen). Public Dart enums always have an `unknown` case. Minor releases add values, and those must never throw.
- **`NativeHandle` owns every native object:**
  - an idempotent `dispose()` and `StateError` on use after dispose;
  - an epoch, so borrowed views throw once they are stale;
  - dependents disposed before their owner;
  - frees deferred out of callbacks (`use()`).
- **Finalizers depend on what the free touches:**
  - `NativeFinalizer` only when the `_free` touches nothing but its own memory.
  - Objects whose free mutates their terminal (tracked refs, searches, selection gestures) use a Dart `Finalizer`, whose token holds the terminal handle. A GC-thread free racing a terminal call corrupted memory, which review found.
- **`NativeCallable.isolateLocal` with `keepIsolateAlive = false`:**
  - Callables are reused, and closed only on dispose or finalization. Closing one while it runs is undefined behaviour.
  - A forgotten terminal used to keep the isolate alive forever, which review found.
  - The process-wide sys handlers have a documented single-isolate restriction.
- **Packed cells are decoded in Dart** for performance (about 250k rows/s). The bit positions are checked against `ghostty_type_json()` at startup, and there is a per-cell fallback. This is the approach upstream documents for bindings.
- **Naming** (§11 of the conventions):
  - `Vt` prefix only on collision-prone names (`VtCursorStyle`, `VtSelection`, `VtKey`, …).
  - `Terminal…` for per-terminal qualified nouns.
  - Properties for readable options, `set…` for write-only ones.

## Consequences
- Adapters (widget, xterm) must copy data out of borrowed views and always `dispose()`.
- Upstream quirks we work around are listed in `docs/internal/research/2026-11-09-upstream-findings.md`.
