# 0002. Own bindings and three-package layout

**Status:** Accepted (2026-11-09)

## Context
Existing bindings are pre-1.0, have fast-moving APIs, and download third-party binaries from their build hooks. None offers `xterm` compatibility. We want a high-performance core without inheriting `xterm`'s API limits.

## Decision
A pub workspace with three published packages:

| Package | Depends on Flutter | Role |
|---|---|---|
| `ghostty_vt` | No (pure Dart) | ffigen bindings, idiomatic Dart API, FFI backend (native) and wasm backend (web) behind one interface, build hook |
| `ghostty_vt_flutter` | Yes | `GhosttyTerminalView` widget, renderer, input (keyboard/mouse/IME), selection |
| `ghostty_xterm` | Yes | API-compatible adapter for `package:xterm` 4.0.0 on top of the other two |

- Bindings are generated with ffigen (Dart-API config, `@Native`), committed, never hand-edited.
- The main library of `ghostty_vt` uses a conditional export (`dart.library.js_interop`) so it never imports `dart:ffi` on web; this keeps full pana platform points.
- Existing projects (`libghostty`, `ghostty_vte`, `libghostty-rs`, `sqlite3`) are references, not dependencies.

## Consequences
- More work than wrapping an existing binding, but full control of ABI target, API quality and supply chain.
- The native API (`ghostty_vt_flutter`) is the recommended path; `ghostty_xterm` is the migration path.
