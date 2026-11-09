# ghostty_dart

[![pub package](https://img.shields.io/pub/v/ghostty_dart.svg)](https://pub.dev/packages/ghostty_dart)
[![pub points](https://img.shields.io/pub/points/ghostty_dart)](https://pub.dev/packages/ghostty_dart/score)
[![CI](https://github.com/AlonsoMCarlos/ghostty_dart/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AlonsoMCarlos/ghostty_dart/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart/LICENSE)

**English** | [Español](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart/README.es.md)

Dart bindings for [libghostty-vt](https://lib.ghostty.org/vt/) 1.x, the
terminal emulation engine of [Ghostty](https://ghostty.org). Feed it the
bytes a program writes to its pty and read back a fully emulated screen:
cells, styles, colours, cursor, scrollback, modes and the replies the
program expects.

> [!NOTE]
> **Unofficial.** This is an independent project. It is not affiliated
> with, endorsed by or sponsored by the Ghostty project or Hack Club.
> "Ghostty" is a trademark of its respective owners and is used here only
> to describe what this package binds to.

- **The whole libghostty-vt 1.0 C API, in idiomatic Dart.** Terminal state
  and options, every callback (pty replies, bell, title, clipboard, ...), a
  batched render state, key and mouse encoding (including the Kitty keyboard
  protocol), selection, search, formatting, snapshots and Kitty graphics. No
  `dart:ffi` types in the public API, and no Flutter dependency.
- **Fast input processing.** In our benchmark it consumed pty output
  3.8–7.6× faster than the faster of xterm 4.0.0 and xterm2_core (AOT, 64
  KiB chunks, end to end), with less memory growth. See [Benchmarks](#benchmarks) for the
  numbers and their caveats.
- **No toolchain needed.** The build hook downloads a prebuilt binary for
  your target (12 targets), verifies it against a sha256 pinned in this
  package's source, and fails the build on any mismatch. Every binary has a
  build provenance attestation.

## Platforms

| Platform | Prebuilt binary | Tested |
|---|---|---|
| Linux x64, arm64 (glibc 2.28+) | ✅ | Full test suite |
| macOS arm64, x64 (macOS 13+) | ✅ | Full test suite |
| Windows x64, arm64 | ✅ | Full test suite (arm64 best effort) |
| Android arm64, arm, x64 (API 24+) | ✅ | Format checks only (exports, deps, 16 KB pages) |
| iOS arm64, simulator arm64 and x64 (iOS 14+) | ✅ | Format checks only |
| Web (wasm) | — | Planned |

The full test suite runs on every pull request on Linux x64, macOS arm64
and Windows x64, and against the release binaries on all six desktop
targets (adding Linux arm64, macOS x64 and Windows arm64).

## Quick start

```sh
dart pub add ghostty_dart
```

```dart
import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';

void main() {
  final terminal = VtTerminal(cols: 80, rows: 24);
  terminal.write(utf8.encode('Hello, \x1b[1;32mworld\x1b[0m!\r\n'));
  print(TerminalFormatter(terminal).formatText()); // Hello, world!
  terminal.dispose(); // also frees the formatter
}
```

To draw a screen, update a `RenderState` once per frame and walk its dirty
rows by style run, so you issue one draw call per run rather than per cell:

```dart
final renderState = RenderState();
terminal.onWritePty = replies.add; // queue; send to the pty later
terminal.write(chunk); // a Uint8List read from the pty

renderState.update(terminal);
for (final row in renderState.dirtyRows) {
  for (var x = 0; x < row.length; x = row.styleRunEnd(x)) {
    final style = row.styleAt(x); // draw the run [x, styleRunEnd(x))
  }
}
renderState.markClean(); // frame drawn: clears the dirty flags
renderState.dispose();
```

Native objects belong to their Dart wrappers: call `dispose()` when you are
done (a finalizer is the safety net). A longer tour, covering effects, ANSI
rendering, key encoding, selection, copy and search, is in
[`example/main.dart`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart/example/main.dart).

**Roadmap:** a Flutter widget (`ghostty_dart_flutter`) and an adapter with
the API of `package:xterm` 4.0.0 (`ghostty_dart_xterm`) are planned as
separate packages, as is a web (wasm) backend. None of them exists yet.

## Benchmarks

Input processing throughput (VT parsing plus screen and scrollback updates)
on the same deterministic byte streams, measured on 2026-11-09: AMD Ryzen 5
3600, Linux, Dart 3.13.7, libghostty-vt 1.0.0 ReleaseFast, AOT, 64 KiB
chunks, a 200×50 terminal with 10,000 lines of scrollback. The xterm engines
include UTF-8 decoding, as apps that read a pty do.

| Workload | ghostty_dart | xterm 4.0.0 | xterm2_core 1.0.0 | Speed-up vs the faster other |
|---|---:|---:|---:|---:|
| `ascii` | 99.5 MB/s | 11.6 MB/s | 24.4 MB/s | 4.1× |
| `sgr` | 88.9 MB/s | 15.1 MB/s | 23.4 MB/s | 3.8× |
| `unicode` | 131.8 MB/s | 25.1 MB/s | 8.7 MB/s | 5.3× |
| `tui` | 171.4 MB/s | 14.4 MB/s | 22.7 MB/s | 7.6× |
| `wrapped` | 318.5 MB/s | 14.2 MB/s | 57.5 MB/s | 5.5× |

Resident memory grew by +0.5 to +17.6 MiB for ghostty_dart, against +1.5 to
+81.2 MiB for the xterm engines, over the same workloads.

Caveats, in short:

- Only input processing is measured, not painting, layout or widgets, so
  these numbers do not predict frame rates in a Flutter app.
- The 10,000-line scrollback used for a fair comparison is the slow
  configuration for libghostty-vt 1.0.0; with its default byte limit it is
  considerably faster.
- In the `unicode` workload the screens differ in cell layout: libghostty-vt
  clusters graphemes, the xterm engines give code points their own widths.
- One shared cloud VM, so expect a few percent of noise, and RSS deltas are
  coarse. Re-run on your hardware before quoting a figure.

The methodology, the JIT and 4 KiB tables, the correctness checks and every
caveat are in
[`benchmarks/README.md`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/benchmarks/README.md),
with the command that reproduces them.

## How it compares

Facts as of 2026-11-09. Each of these projects made a different trade-off,
and `xterm` in particular is the mature, widely used choice today.

| Package | Engine | Flutter widget | Web | `xterm` 4.0.0 API |
|---|---|---|---|---|
| `ghostty_dart` 0.1.0 | libghostty-vt 1.0.0 (stable C ABI), FFI | No (planned, separate package) | No (planned) | No (adapter planned) |
| [`xterm`](https://pub.dev/packages/xterm) 4.0.0 | Pure Dart | Yes | Yes | It is the API |
| [`xterm2`](https://pub.dev/packages/xterm2) 5.4.0 | Pure Dart (`xterm2_core`) | Yes | Yes | Same API (a fork) |
| [`libghostty`](https://pub.dev/packages/libghostty) 0.0.13 + [`flterm`](https://pub.dev/packages/flterm) 0.0.6 | A pre-1.0 libghostty-vt commit, FFI and wasm | Yes (`flterm`) | Yes | No |

What `ghostty_dart` does **not** do yet: it has no widget, so you draw the
screen yourself; it does not run on the web; and it cannot replace
`package:xterm` in an existing app. If you need any of those today, the
packages above already offer them.

## Supply chain

The build hook runs on your machine, so it is held to a strict standard:

- **Pinned and verified.** The default `prebuilt` source downloads the
  binary for your target from the GitHub release
  [`native-v1.0.0-r1`](https://github.com/AlonsoMCarlos/ghostty_dart/releases/tag/native-v1.0.0-r1)
  (with its `SHA256SUMS`) and checks it against the sha256 pinned in the
  package source. A mismatch fails the build. The hook never runs
  downloaded code and never fetches anything unpinned.
- **Built in CI from signed source.** The binaries are built by this
  repository's CI from the upstream libghostty-vt tarball, after checking
  its minisign signature and a pinned sha256.
- **Attested and reproducible.** Every binary carries a build provenance
  attestation, and all but the Apple ones are bit-reproducible.

To check the binaries yourself (checksums, attestations, rebuilding), follow
[Verifying the prebuilt binaries](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/SECURITY.md#verifying-the-prebuilt-binaries)
in the security policy. The repository also commits its lockfiles and does
not adopt any dependency version younger than 3 days.

## Build hook options

Set them in `hooks: user_defines: ghostty_dart:` of your root
`pubspec.yaml`:

```yaml
hooks:
  user_defines:
    ghostty_dart:
      source: path    # prebuilt (default), path or system
      path: path/to/libghostty-vt.so.1.0.0
```

- `source: prebuilt` (default) downloads the pinned binary. `url_pattern`
  points it at an https mirror; the pinned sha256 is still verified.
- `source: path` uses a library file, or a directory holding it, for
  air-gapped builds or your own compilation.
- `source: system` loads an installed libghostty-vt 1.x.

The full reference (placeholders, timeouts, proxies and minimum OS versions)
is the
[Build hook options](https://pub.dev/documentation/ghostty_dart/latest/topics/build-hook-options-topic.html)
topic.

## Documentation

- [API reference](https://pub.dev/documentation/ghostty_dart/latest/)
- [Build hook options](https://pub.dev/documentation/ghostty_dart/latest/topics/build-hook-options-topic.html)
- [Changelog](https://pub.dev/packages/ghostty_dart/changelog)
- [Contributing](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/CONTRIBUTING.md)
  and [security policy](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/SECURITY.md)
- [Issues](https://github.com/AlonsoMCarlos/ghostty_dart/issues)

## License

This package is MIT licensed (see
[LICENSE](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart/LICENSE)).
libghostty-vt, which the build hook provides as a native library, is also
MIT licensed (Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors);
apps that ship it must include its notice.
