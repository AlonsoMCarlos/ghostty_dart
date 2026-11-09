## 0.1.0

- Initial release: idiomatic Dart bindings for the libghostty-vt 1.0.0 C
  API, on Linux, macOS, Windows, Android and iOS (native only).
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
- Build hook with three sources, chosen with `hooks: user_defines`:
  - `prebuilt` (default): downloads the binary for the target from release
    `native-v1.0.0-r1` (12 targets: Linux, Windows, macOS, Android, iOS
    device and simulator), verified against a sha256 pinned in the package;
    fails closed on mismatch. Downloads have connect, idle and per-attempt
    timeouts, a 64 MiB size cap, https-only redirects and one retry on
    transient errors, and their error messages point at `url_pattern`,
    `path` and `system`. `url_pattern` (with `$TAG`, `$VERSION` and
    `$FILENAME`) selects an https mirror; the hash is still checked. The
    source refuses Android below API 24, iOS below 14 and macOS below 13.
  - `path`: a local library file, or a directory holding it.
  - `system`: an installed libghostty-vt 1.x.
- Known limitations: Android and iOS binaries are format-checked but not
  yet run on devices or emulators; no web backend yet.
