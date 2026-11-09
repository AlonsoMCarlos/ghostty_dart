## 0.1.0-dev.1

- Initial development release: idiomatic Dart bindings for the
  libghostty-vt 1.0.0 C API.
  - `VtTerminal`: write, resize, reset, state and options, modes, colours,
    scrollback and viewport, memory and compression, stoppable writes and
    continuation, paste.
  - Effects: every terminal callback (`onWritePty`, `onBell`,
    `onTitleChanged`, clipboard, notifications, progress, shell
    integration, device/size/colour-scheme queries, unknown sequences).
  - `RenderState`: batched, allocation-light iteration of dirty rows,
    cells, styles, colours, cursor and image placements.
  - Input: `KeyEncoder` (legacy and Kitty keyboard protocol),
    `MouseEncoder`, focus, paste, size, mode and colour-scheme reports.
  - Text: `TerminalFormatter` (plain, VT, HTML), `VtSelection` and
    `SelectionGesture`, `TerminalSearch`.
  - Grid references, tracked references, snapshots, Kitty graphics,
    OSC/SGR parsers, colour utilities, Unicode width, logging and other
    process-wide settings.
- Forward compatible: enum values added by later 1.x releases decode as
  `unknown`; `GHOSTTY_UNSUPPORTED` is an `UnsupportedError`.
- Ownership: every native object has an idempotent `dispose()` and a
  finalizer; use after dispose throws `StateError`.
- Known limitations: verified on Linux x64 only; prebuilt binaries are
  not published yet (use the `path` or `system` hook source); no web
  backend yet.
