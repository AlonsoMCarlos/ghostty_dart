# ghostty_dart_xterm

[![CI](https://github.com/AlonsoMCarlos/ghostty_dart/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AlonsoMCarlos/ghostty_dart/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/LICENSE)

**English** | [Español](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/README.es.md)

The public API of [`xterm`](https://pub.dev/packages/xterm) 4.0.0
(`Terminal`, `TerminalView`, `TerminalController`, themes, key and mouse
handlers) on top of
[`ghostty_dart_flutter`](https://github.com/AlonsoMCarlos/ghostty_dart/tree/main/packages/ghostty_dart_flutter)
and [`ghostty_dart`](https://pub.dev/packages/ghostty_dart), which run
[libghostty-vt](https://lib.ghostty.org/vt/) 1.x, the terminal emulation
engine of [Ghostty](https://ghostty.org). Most apps move from `xterm` by
changing their import.

> [!NOTE]
> **Unofficial.** This is an independent project. It is not affiliated
> with, endorsed by or sponsored by the Ghostty project or Hack Club, nor
> by the authors of `xterm`. "Ghostty" is a trademark of its respective
> owners and is used here only to describe what this package builds on.

> [!IMPORTANT]
> **Not published yet, and not a drop-in replacement.** It waits for
> `ghostty_dart_flutter` to be on pub.dev. Every xterm 4.0.0 member and its
> status (same, differs, planned, won't support) is listed in the generated
> [`COMPATIBILITY.md`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/COMPATIBILITY.md),
> and what the differences mean for an app is in the
> [migration guide](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/MIGRATING_FROM_XTERM.md).

There is no live web demo yet: it waits for the web (wasm) backend of
`ghostty_dart`.

- **xterm's API, checked by machine.** The same class, member and parameter
  names as `xterm` 4.0.0. An analyzer pass compares both APIs on every CI
  run; xterm's own tests are ported and run against this package, and its
  `flutter_pty` and `dartssh2` examples compile with only the import
  changed.
- **Ghostty's engine.** Parsing, the screen, scrollback, reflow, key
  encoding (including the Kitty keyboard protocol) and mouse reports come
  from libghostty-vt 1.0 instead of a Dart emulator.
- **`ghostty_dart_flutter`'s renderer.** `TerminalView` is a
  `VtTerminalView`: only the rows that changed are redrawn, from a glyph
  atlas, with IME and soft keyboards built in.

## Platforms

| Platform | Status | Tested |
|---|---|---|
| Linux, macOS, Windows | ✅ | Tests in CI on all three |
| Android, iOS | ⚠️ | Not yet tried on a device |
| Web | — | Planned: needs a wasm backend in `ghostty_dart` |

## Quick start

Once published, swap the dependency and the import:

```yaml
dependencies:
  # xterm: ^4.0.0
  ghostty_dart_xterm: ^0.1.0
```

```dart
// import 'package:xterm/xterm.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

final terminal = Terminal(maxLines: 10000);
terminal.onOutput = (data) => pty.write(utf8.encode(data)); // keys, pastes, replies
terminal.write('Hello, world!\r\n');

// In build():
TerminalView(terminal, autofocus: true);

// When done (not in xterm: the terminal holds native memory):
terminal.dispose();
```

[`example/lib/main.dart`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/example/lib/main.dart)
is xterm's mock-shell example, ported: a complete app that runs without a
pty.

## Migrating from xterm

For a typical app (a `flutter_pty` shell, a `dartssh2` session, a virtual
keyboard as a custom `inputHandler`), the import change is the whole
migration, plus `terminal.dispose()`. What you may notice:

- Keys typed into `TerminalView` are encoded by libghostty-vt, so a few
  byte sequences differ from xterm's keytab (Kitty keyboard protocol when
  the program asks for it, for example). A custom `inputHandler` still gets
  every key, as in xterm.
- Mouse reports use the correct row (xterm 4.0.0 sends one row too low).
- The screen that is not active (the main screen while a full-screen
  program runs) reads as blank lines.
- `maxLines` is approximate: scrollback is dropped in whole pages, so a bit
  more is kept.
- One `TerminalView` per `Terminal`, and no web yet.

The [migration guide](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/MIGRATING_FROM_XTERM.md)
covers each difference with code.

## Benchmarks

This package has not been benchmarked on its own yet. What it is built on
has been, against `xterm` 4.0.0 on the same byte streams:

- **Parsing:** `ghostty_dart` consumed pty output 3.3–7.6× faster than the
  faster of `xterm` 4.0.0 and `xterm2_core`
  ([parser benchmark](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/benchmarks/README.md#results)).
  `Terminal.write` goes through the same parser, plus a listener
  notification per chunk.
- **Frames:** `ghostty_dart_flutter`'s view, which `TerminalView` wraps,
  spent about 23× less UI time per frame than `xterm` 4.0.0's when a few
  rows change, and 3.5× less on a full screen of new text
  ([frame benchmark](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/benchmarks/README.md#frame-time-benchmark-widgets)).
  The adapter's own work per frame (its key, text and mouse hooks) is not
  measured there.
- **Slower:** reading `terminal.buffer.lines` builds each line from the
  engine on first access (about 50 µs per 80-column line in a debug
  build), where xterm keeps the lines in Dart. Fine for copying a
  selection or a search; avoid walking the whole scrollback every frame.

## How it compares

Facts as of 2026-11-12. `xterm` is the mature, widely used choice today,
and this package exists to keep its API.

| | `ghostty_dart_xterm` (unreleased) | [`xterm`](https://pub.dev/packages/xterm) 4.0.0 |
|---|---|---|
| Engine | libghostty-vt 1.0.0, FFI | Pure Dart |
| Web | No (planned) | Yes |
| API | xterm 4.0.0's, with the differences in `COMPATIBILITY.md` | It is the API |
| Escape parser in Dart (`EscapeParser`, `EscapeHandler`) | No: parsing is native | Yes |
| ZModem (`zmodem.dart`) | Not yet | Yes |
| Debugger (`utils.dart`) | No | Yes |

If you need the web, ZModem or xterm's Dart parser today, use `xterm`.

## Supply chain

- **Dependencies besides Flutter:** `ghostty_dart_flutter` and
  `ghostty_dart`, from the same repository. `ghostty_dart`'s build hook
  downloads a prebuilt libghostty-vt for your target, checks it against a
  sha256 pinned in its source, fails the build on a mismatch, and never
  runs downloaded code. The binaries are built in this repository's CI
  from the signed upstream source, with provenance attestations.
- **No build-time code of its own.** No build hook, no native code. Parts
  are ported from `xterm` 4.0.0 (MIT), each file marked.
- The repository commits its lockfiles, pins its GitHub Actions by commit,
  and does not adopt any dependency version younger than 3 days. Details
  are in the
  [security policy](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/SECURITY.md).

## Documentation

- [Migration guide](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/MIGRATING_FROM_XTERM.md)
  and [`COMPATIBILITY.md`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/COMPATIBILITY.md)
- [`ghostty_dart_flutter`](https://github.com/AlonsoMCarlos/ghostty_dart/tree/main/packages/ghostty_dart_flutter),
  for the widget underneath
- [Design decision (ADR 0013)](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/docs/internal/adr/0013-xterm-adapter-design.md)
- [Changelog](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/CHANGELOG.md)
- [Contributing](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/CONTRIBUTING.md)
  and [issues](https://github.com/AlonsoMCarlos/ghostty_dart/issues)

## License

MIT (see
[LICENSE](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/LICENSE)).
Parts are ported from `xterm` 4.0.0, also MIT; see
[`LICENSE.xterm`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/LICENSE.xterm).
libghostty-vt is MIT licensed too (Copyright (c) 2024 Mitchell Hashimoto,
Ghostty contributors); apps that ship it must include its notice.
