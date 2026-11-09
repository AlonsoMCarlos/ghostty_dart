# 0004. xterm compatibility as a thin adapter

**Status:** Accepted (2026-11-09)

## Context
`package:xterm` 4.0.0 is the de facto Flutter terminal (~253k downloads/30 days) but unmaintained since 2024. Its API forces `String` input, exposes its internal cell model (`BufferLine` as `Uint32List`), its Dart parser (`EscapeHandler`), and an index-ordered `TerminalKey` without meta. Copying that as our core would cap our performance. ghostty-web's "drop-in" claim for xterm.js was publicly contradicted by its own company's migration PR.

## Decision
- `ghostty_xterm` mirrors the **public API of `xterm` 4.0.0** (not forks), so migration is an import change for typical apps (`flutter_pty`, `dartssh2`).
- Full fidelity: `Terminal` (constructor, callbacks, `write`, `keyInput`, `charInput`, `textInput`, `paste`, `mouseInput`, `resize`, modes), `TerminalView`, `TerminalController`, themes/styles, `TerminalKey`, mouse types.
- Read-only views: `Buffer`, `BufferLine`, `CellData` and related bit-packing, materialised lazily from the render state.
- Not provided: `EscapeHandler`/`EscapeParser` subclassing (parsing lives in C). Documented as an incompatibility.
- Extensions beyond xterm are additive only (e.g. `writeBytes(Uint8List)`).
- We **do not say "drop-in"** until the compatibility suite proves it. Evidence: `COMPATIBILITY.md` (member-by-member table, generated), xterm.dart's MIT tests ported and run in CI, `MIGRATING_FROM_XTERM.md`.

## Consequences
- Some low-level xterm users will need code changes; we tell them exactly which.
- The adapter is a maintenance surface; its tests are the contract.
