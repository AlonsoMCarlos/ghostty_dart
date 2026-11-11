# ghostty_dart_xterm

[![CI](https://github.com/AlonsoMCarlos/ghostty_dart/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AlonsoMCarlos/ghostty_dart/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/LICENSE)

**English** | [Español](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/README.es.md)

An adapter that offers the public API of
[`xterm`](https://pub.dev/packages/xterm) 4.0.0 on top of
[`ghostty_dart`](https://pub.dev/packages/ghostty_dart) and
[`ghostty_dart_flutter`](https://pub.dev/packages/ghostty_dart_flutter),
which run [libghostty-vt](https://lib.ghostty.org/vt/) 1.x, the terminal
emulation engine of [Ghostty](https://ghostty.org). The goal is that an
app moves from `xterm` by changing its import.

> [!NOTE]
> **Unofficial.** This is an independent project. It is not affiliated
> with, endorsed by or sponsored by the Ghostty project or Hack Club, nor
> by the authors of `xterm`. "Ghostty" is a trademark of its respective
> owners and is used here only to describe what this package builds on.

> [!WARNING]
> **Work in progress, not published.** Only xterm's value types exist so
> far (`CellOffset`, `BufferRange`, `CursorStyle`, `TerminalState`, …);
> `Terminal`, `TerminalView` and `TerminalController` are being written.
> The design is in
> [ADR 0013](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/docs/internal/adr/0013-xterm-adapter-design.md).
> We will not call it a drop-in replacement until a generated
> `COMPATIBILITY.md` and xterm's own tests, ported and passing, show it.

- **xterm's API.** The same class, member and parameter names as `xterm`
  4.0.0, with every difference listed member by member.
- **Ghostty's engine.** Parsing, the screen, scrollback and key encoding
  come from libghostty-vt instead of a Dart emulator.
- **`ghostty_dart_flutter`'s renderer**, which redraws only the rows that
  changed.

## Platforms

| Platform | Status |
|---|---|
| Linux, macOS, Windows | In progress |
| Android, iOS | In progress (not yet tried on a device) |
| Web | Planned: needs a wasm backend in `ghostty_dart` |

## Quick start

Not usable yet. Once `Terminal` and `TerminalView` exist:

```dart
// import 'package:xterm/xterm.dart';
import 'package:ghostty_dart_xterm/xterm.dart';
```

## License

MIT (see `LICENSE`). Parts are ported from `xterm` 4.0.0, also MIT; see
[`LICENSE.xterm`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/LICENSE.xterm).
