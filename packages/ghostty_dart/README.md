# ghostty_dart

Dart bindings for [libghostty-vt](https://lib.ghostty.org/vt/) 1.x, the
terminal emulation engine of [Ghostty](https://ghostty.org). Feed it the
bytes a program writes to its pty and read back a fully emulated screen:
cells, styles, colours, cursor, scrollback, modes and the replies the
program expects.

> **Unofficial.** This is an independent project. It is not affiliated
> with, endorsed by or sponsored by the Ghostty project or Hack Club.
> "Ghostty" is a trademark of its respective owners and is used here only
> to describe what this package binds to.

> **Status: pre-release (`0.1.0-dev.1`).** The API is complete for the
> libghostty-vt 1.0.0 C API but may still change before 0.1.0. This README
> is a stub; the full, bilingual README comes with the first release.

- An idiomatic Dart API over the whole C API: terminal state and options,
  every callback (pty replies, bell, title, clipboard, notifications, ...),
  a batched render state, key and mouse encoding (including the Kitty
  keyboard protocol), selection, search, plain/VT/HTML formatting, grid
  references, snapshots, Kitty graphics, OSC/SGR parsers, colour and Unicode
  width utilities.
- No `dart:ffi` types in the public API. Native objects are owned by their
  Dart wrappers: call `dispose()` (a finalizer is the safety net).
- Pure Dart, no Flutter dependency.

## Example

```dart
import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';

void main() {
  final terminal = VtTerminal(cols: 80, rows: 24);
  final renderState = RenderState();
  try {
    terminal.onWritePty = (bytes) {/* send to the child process */};
    terminal.write(utf8.encode('Hello, \x1b[1;32mworld\x1b[0m!\r\n'));

    renderState.update(terminal);
    for (final row in renderState.dirtyRows) {
      for (var x = 0; x < row.length; x = row.styleRunEnd(x)) {
        final style = row.styleAt(x); // draw the run [x, styleRunEnd(x))
      }
    }
  } finally {
    renderState.dispose();
    terminal.dispose();
  }
}
```

A longer tour (effects, ANSI rendering, key encoding, selection, copy and
search) is in [`example/main.dart`](example/main.dart):

```sh
dart run example/main.dart
```

## Platforms

| Platform | Status |
|---|---|
| Linux x64 | Verified (the test suite runs against the real library) |
| macOS, Windows, Linux arm64, Android, iOS | Pending CI builds |
| Web (wasm) | Planned |

The native library is provided by the package's build hook. Its default
`prebuilt` source downloads the binary for your target from this project's
GitHub release and verifies it against a sha256 pinned in the package
source; a mismatch fails the build. Prebuilt binaries are coming with
release `native-v1.0.0-r1` for Linux (x64, arm64; glibc 2.28+), Windows
(x64; arm64 best effort), macOS (arm64, x64; macOS 13+), Android (arm64,
arm, x64; API 24+) and iOS (arm64 device, arm64 and x64 simulator; iOS
13+). **That release is not published and no hashes are pinned yet**, so
today the `prebuilt` source fails with instructions.

Hook options, in `hooks: user_defines: ghostty_dart:` of your root
`pubspec.yaml`:

- `source: path` with `path:` (a library file, or a directory holding it)
  and `source: system` (an installed libghostty-vt 1.x) work now. Use one
  of them until prebuilt binaries are published, and for air-gapped
  builds:

  ```yaml
  hooks:
    user_defines:
      ghostty_dart:
        source: path    # or `system`, which needs no `path`
        path: path/to/libghostty-vt.so.1.0.0
  ```

- `url_pattern` takes effect once hashes are pinned. It downloads from an
  https mirror or internal store instead of GitHub. `$TAG` (release tag),
  `$VERSION` (libghostty-vt version) and `$FILENAME` (asset name) are
  substituted, for example `https://mirror.example/$TAG/$FILENAME`. The
  pinned sha256 is still verified.

Downloads use connect and idle timeouts, a 10-minute limit per attempt, a
64 MiB size cap, https-only redirects and one retry on transient errors.
They honour `HTTPS_PROXY` and `NO_PROXY`. Behind a TLS-intercepting proxy,
point `url_pattern` at a mirror the build can reach, or use `source: path`.
The hook never runs downloaded code.

## License

This package is MIT licensed (see [LICENSE](LICENSE)). libghostty-vt,
which the build hook provides as a native library, is also MIT licensed
(Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors); apps that
ship it must include its notice.
