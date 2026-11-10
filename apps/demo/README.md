# ghostty_dart demo

A Flutter app that shows `VtTerminalView` from
[`ghostty_dart_flutter`](../../packages/ghostty_dart_flutter) connected to a
program:

- **desktop (Linux, macOS, Windows):** your shell in a pseudo-terminal,
  through [`flutter_pty2`](https://pub.dev/packages/flutter_pty2) 3.0.0
  (`lib/src/shell/pty_shell.dart`); if no pty can be started, the fake shell
  runs instead and says why;
- **web, or `--fake`:** a small shell written in Dart (`lib/src/fake_shell/`)
  with `ls`, `cd`, `cat`, `colors`, `top` and line editing.

Unofficial, not affiliated with the Ghostty project.

```sh
mise run demo:run            # Linux desktop, your $SHELL
mise run demo:run --fake     # the fake shell
mise run demo:run macos      # on a Mac
mise run demo:test           # tests (no display and no real pty needed)
```

flutter_pty2 compiles its C code through a build hook whenever the demo's
dependencies are built, `demo:test` included, so every demo task needs a C
compiler: `clang` on PATH on Linux (native_toolchain_c does not fall back
to gcc), Xcode on macOS, Visual Studio with the C++ workload on Windows.

The web build (`mise run demo:build-web`) waits for `ghostty_dart`'s wasm
backend, which does not exist yet; the task stops with that message.

The macOS app is not sandboxed: a sandboxed shell could only see the app's
container.

## Known limitations

The demo switched from flutter_pty 0.4.2 to flutter_pty2 3.0.0 on
2026-11-10. flutter_pty2 fixed what the demo could not work around before:
it closes the pty and joins its threads on `close()`, writes without
blocking (a native queue; the demo uses `tryWrite` and queues up to 4 MiB
behind it, dropping input beyond that), reports a failed `exec` as a
`PtySpawnException` instead of returning into the app, has no one-second
`Sleep` on Windows, and delivers all output before `done` completes. The
comparison, with file and line references, is in
[`docs/internal/research/2026-11-10-pty-packages.md`](../../docs/internal/research/2026-11-10-pty-packages.md).

What is left:

- **A young dependency.** flutter_pty2 (SoFluffyOS, a fork of flutter_pty)
  had three major versions in 2026 and few users (2 likes, about 500
  downloads in 30 days on 2026-11-10). Its own CI failed on its last runs
  before 3.0.0 (2026-10-12) and 3.0.0 was published without a CI run. The
  demo pins it exactly; the hook and C sources are read again before any
  upgrade.
- **Native code compiled on your machine.** Its build hook compiles its
  own C sources only, with no download and no other process
  (`hook/build.dart`), but that still runs with your permissions, like any
  native package.
- **Hang-up, then SIGKILL.** `close()` kills the program's process groups
  with SIGKILL. So that shells can save their history, the demo first sends
  SIGHUP to the shell's process group and calls `close()` once the shell
  has exited, or after two seconds. Windows has no signals: `close()` ends
  the whole process tree there right away.
- **Input dropped past 4 MiB.** A paste into a program that never reads
  its input queues up to 4 MiB in Dart; the rest is dropped rather than
  buffered without bound. The UI does not freeze.
- **`FLUTTER_PTY2_LIBRARY`.** If that environment variable is set,
  flutter_pty2 loads the library at that path instead of the one built for
  the app (`lib/src/internal/native_library.dart`).
- **No sandbox on macOS** (above), and no Android or iOS build of the demo.
