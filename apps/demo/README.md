# ghostty_dart demo

A Flutter app that shows `VtTerminalView` from
[`ghostty_dart_flutter`](../../packages/ghostty_dart_flutter) connected to a
program:

- **desktop (Linux, macOS, Windows):** your shell in a pseudo-terminal,
  through [`flutter_pty`](https://pub.dev/packages/flutter_pty) 0.4.2;
- **web, or `--fake`:** a small shell written in Dart (`lib/src/fake_shell/`)
  with `ls`, `cd`, `cat`, `colors`, `top` and line editing.

Unofficial, not affiliated with the Ghostty project.

```sh
mise run demo:run            # Linux desktop, your $SHELL
mise run demo:run --fake     # the fake shell
mise run demo:run macos      # on a Mac (needs CocoaPods for flutter_pty)
mise run demo:test           # tests (no display needed)
```

The web build (`mise run demo:build-web`) waits for `ghostty_dart`'s wasm
backend, which does not exist yet; the task stops with that message.

The macOS app is not sandboxed: a sandboxed shell could only see the app's
container.

## Known limitations

flutter_pty 0.4.2 is published by terminal.studio, the authors of
xterm.dart. The demo works around what it can
(`lib/src/shell/pty_shell.dart`); what is left comes from its native code
(paths relative to the package in `~/.pub-cache`):

- **Leaked descriptors and threads per shell.** The parent never closes the
  pty's slave side (`src/forkpty.c:38`, not close-on-exec either) nor the
  master, and there is no call to close a pty. The reader thread
  (`src/flutter_pty_unix.c:67`) therefore never sees end-of-file: every
  Restart leaks two descriptors and one thread, and later shells inherit
  the old slave descriptor. On Windows the pseudo console created at
  `src/flutter_pty_win.c:312` is never closed.
- **Blocking writes on the UI thread.** `pty_write` is a plain `write()`
  (`src/flutter_pty_unix.c:207`). A large paste into a program that does not
  read its input freezes the app until the program reads. The demo stops
  forwarding input once the shell has exited.
- **One-second freeze on Windows** at every start or Restart:
  `Sleep(1000)` in `pty_create` (`src/flutter_pty_win.c:365`).
- **A failed `execvp` returns into the app** (`src/flutter_pty_unix.c:183`,
  no `_exit` after it). The demo always executes `/bin/sh`, which exists on
  every Unix system, and lets it `exec` your shell; only a failure to start
  `/bin/sh` itself (out of memory, for example) could still hit this.
- **The last output can be lost** when the shell exits: output and exit
  arrive on separate ports, and the output port is closed on exit
  (`lib/flutter_pty.dart`, `_onExitCode`).

Newer pty packages fix several of these; the demo keeps flutter_pty for
v0.1.
