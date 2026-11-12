# Changelog

## [0.1.1](https://github.com/AlonsoMCarlos/ghostty_dart/compare/ghostty_dart-v0.1.0...ghostty_dart-v0.1.1) (2026-11-12)


### Features

* **flutter:** scaffold ghostty_dart_flutter with frozen contracts ([510b7f7](https://github.com/AlonsoMCarlos/ghostty_dart/commit/510b7f7a0bc16315a664e1d252e12df723eca411))


### Bug Fixes

* **ghostty_dart:** say how to fix a missing source: path library ([8047076](https://github.com/AlonsoMCarlos/ghostty_dart/commit/80470767d454efd830ee7844f1913a25739e941b))
* **ghostty_dart:** ship the licences of the code in libghostty-vt in NOTICES ([ab559f8](https://github.com/AlonsoMCarlos/ghostty_dart/commit/ab559f84db35d6693fbb3b3942ee5690f849f39f))

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
