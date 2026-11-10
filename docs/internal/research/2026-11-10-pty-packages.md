# Pty packages for the demo app and for the README

Date: **2026-11-10**. Copied from the plan-run research of that day (the archives were downloaded again and re-verified on 2026-11-10 before `flutter_pty2` 3.0.0 was adopted). Decision: ADR 0011, "Demo app".

Method: pub.dev API (`/api/search?q=pty|pseudoterminal|conpty|forkpty`,
`/api/packages/<p>`, `/score`, `/publisher`), `gh api` for repo activity, and the
published archives downloaded with `curl` into an empty scratch dir, sha256
compared to the API's `archive_sha256` (all six matched), extracted with `tar`,
and **read only**. Nothing was built, run, or added to any lockfile.

Archives read (sha256 prefix): flutter_pty 0.4.2 (c2f3b316), pty2 0.8.0
(49b8a74a), flutter_pty2 3.0.0 (9802f793), portable_pty 0.0.5 (0770e4f0),
kyroon_pty 1.0.7 (3bf1b8d0), flutter_pty_new 1.0.0 (8894d9e7).

Other search hits are not pty libraries for us: `artisanal_pty`, `termui_pty`,
`twk_term`, `d_zero_terminal`, `voo_terminal` are whole terminal emulators/widgets;
`pty` (TerminalStudio, last 2021) and `dart_pty` (2021, no repo) are abandoned.

## Metadata

| Package | Version considered (published) | Age today | Publisher | Likes / points / 30-day dl | Repo activity (gh, 2026-11-10) | License |
|---|---|---|---|---|---|---|
| flutter_pty | 0.4.2 (2025-01-06), latest | 22 months | terminal.studio ✓ | 24 / 150 / 11 108 | TerminalStudio/flutter_pty: last commit 2025-01-06, 18 open issues/PRs, fix PRs since 2024 unmerged (#16 waitpid, #20 remove `Sleep(1000)`, #22 Windows argv[0] duplication, #24/#25 1 KB read buffer). **Unmaintained.** | MIT |
| pty2 | 0.8.0 (2026-11-04); 0.8.1 (2026-11-10) is too new | 6 days | mcdole.org ✓ | 2 / 160 / 35 741 (mostly via termui) | jtmcdole/termui monorepo, commits daily, 0 open issues, publish CI green. Release churn: 0.5.7→0.8.1 in 3 weeks. | MIT |
| flutter_pty2 | 3.0.0 (2026-10-21), latest | 20 days | sofluffy.io ✓ (also publishes xterm2, already in our lock) | 2 / 150 / 489 | SoFluffyOS/flutter_pty2, fork of flutter_pty (history: xtyxtyx 74, simonpham 323 commits); last commit 2026-10-23 (unreleased); 0 open issues. **Its CI was red on the last runs (2026-10-12, TSan/strict build/Android/Windows stress)**, no runs since; 3.0.0 published without a CI run. Majors: 1.0 Jul, 2.0 Sep, 3.0 Oct 2026. | MIT |
| portable_pty | 0.0.5 (2026-05-02); 0.0.7-beta.2 | 6 months | glenfordwilliams.com ✓ | 4 / 130 / 157 | kingwill101/dart_terminal, last push 2026-08-29; repo has no license file detected by GitHub | MIT (pubspec) |
| kyroon_pty | 1.0.7 (2026-10-16) | 25 days | none (unverified) | 0 / 160 / 153 | 1 star; Portuguese-commented fork of flutter_pty | MIT |
| flutter_pty_new | 1.0.0 (2026-07-10) | 4 months | none (unverified) | 0 / 150 / 147 | 1 star; fork of flutter_pty | MIT |

## Build-time code (what runs on the developer's machine)

- **flutter_pty 0.4.2**: Flutter `ffiPlugin`. CMake (`src/CMakeLists.txt`,
  `linux/`, `windows/`) and podspecs compile one C library; no download, no
  `execute_process`. macOS needs CocoaPods (no `Package.swift`). (Confirmed again;
  matches T4-review-skeptic §1.)
- **pty2 0.8.0**: `hook/build.dart` (22 lines) builds `src/pty2_unix.c` with
  `native_toolchain_c` `CBuilder.library` on Linux/macOS only; Windows is pure
  Dart FFI to `kernel32` through `package:win32`. No network, no `Process`.
  Runtime only: `PseudoTerminal.ensureConPtyReady(download: true)` can fetch the
  `Microsoft.Windows.Console.ConPTY` NuGet package from api.nuget.org with a
  pinned sha256 (`lib/src/impl/conpty_bundle.dart:74,321`); default is
  `download: false`. It also loads a sidecar `conpty.dll` from `PTY2_CONPTY_DIR`
  or the per-user cache if one is present (`conpty_bundle.dart:189-200`).
- **flutter_pty2 3.0.0**: pure Dart package (no Flutter plugin dirs).
  `hook/build.dart` (54 lines) builds the C sources with `native_toolchain_c`
  for every OS; `src/CMakeLists.txt` is only for its own native tests. No
  network, no `Process`. Runtime: `FLUTTER_PTY2_LIBRARY` env var makes it
  `DynamicLibrary.open` another library (`lib/src/internal/native_library.dart`),
  same class of risk as `LD_PRELOAD`, i.e. none new.
- **portable_pty 0.0.5**: **ruled out, confirmed.** `hook/build.dart:29-79`:
  (1) copies a library from `PORTABLE_PTY_PREBUILT`, (2) `.prebuilt/`,
  (3) **downloads a prebuilt binary from GitHub releases at build time**
  (`releaseTag portable_pty-v0.0.5`, sha256 pinned in
  `lib/src/hook/asset_hashes.dart`, extracted with `Process.run('tar')`), and on
  failure (4) **falls back to building Rust with `native_toolchain_rust`**
  (`rust/Cargo.toml`: `portable-pty 0.9`, build-dep `cbindgen`; 86-crate
  `Cargo.lock`), i.e. third-party `build.rs` at build time, the exact vector of
  the 2026-08-20 incident. Correction to T4.md: it does not use
  `native_prebuilt`; it has its own downloader. Either way it violates AGENTS.md
  (binaries without our provenance; unpinned-by-us Rust build).
- **kyroon_pty / flutter_pty_new**: same plugin layout as flutter_pty.

Transitive dependencies (from the pubspecs, compared with our workspace
`pubspec.lock`):

| Package | Direct deps | New lock entries for us |
|---|---|---|
| flutter_pty | `ffi` | none (current) |
| pty2 0.8.0 | `code_assets ^2.1`, `crypto`, `ffi`, `hooks ^2.2`, `native_toolchain_c ^0.19.5`, `path`, `win32 ^6` | `win32` 6.x (halildurmus.dev, pure Dart, no hook); rest already locked |
| flutter_pty2 3.0.0 | `code_assets >=1.2 <3`, `ffi ^2.0.1`, `hooks ^2.0`, `native_toolchain_c ^0.19.2` | **none**: lock already has code_assets 2.2.0, hooks 2.2.0, native_toolchain_c 0.19.5 (labs.dart.dev), ffi 2.2.0 |

`native_toolchain_c` 0.19.5 (read in `~/.pub-cache`) only locates a compiler
(`cbuilder/compiler_resolver.dart:51-95`: on a Linux host targeting Linux it
looks for **clang** only, no gcc fallback; Apple clang on macOS; MSVC on
Windows) and runs it on the package's own sources.

## The flutter_pty defects, per candidate

flutter_pty 0.4.2 references are to its archive; the forks inherit them unless
noted.

| Defect | flutter_pty 0.4.2 | pty2 0.8.0 | flutter_pty2 3.0.0 | kyroon_pty / flutter_pty_new |
|---|---|---|---|---|
| Failed exec continues the child as the app | yes: `src/flutter_pty_unix.c:183-188` (`perror` only, then falls into `malloc`, threads, `return`) | no: child uses only async-signal-safe calls, `_exit(1)` on every failure incl. after `execve` (`src/pty2_unix.c:94-144`). Spawn still "succeeds"; the failure shows as exit code 1 | no: `_exit(126/127)` everywhere (`src/unix/pty_unix_spawn.c:1088-1168`), and the errno travels back on a CLOEXEC status pipe so `Pty.spawn` **throws** `PtyException` (`NOT_FOUND`, `PERMISSION_DENIED`, `WORKING_DIRECTORY`) (`:1185-1215`); executable resolved via `PATH` in the parent (`:322-419`) | kyroon fixes it (`_exit(127)`); flutter_pty_new does not |
| Non-async-signal-safe calls after fork (`putenv`, `perror`, `chdir` on a heap env) | yes: `flutter_pty_unix.c:151,180,187` | no: env passed to `execve`, signals reset, `close_range` (`pty2_unix.c:34-49,95-144`) | no: env/argv prepared before fork; fd list pre-allocated (`pty_unix_spawn.c:462-476,1068`) | yes |
| pts not CLOEXEC / not closed in parent; no close API → fd + reader-thread leak per restart | yes: `src/forkpty.c` (pts kept, not CLOEXEC); no `pty_close`; Windows `ClosePseudoConsole` never called | no: both fds CLOEXEC (`pty2_unix.c:76-77`), parent closes pts (`:147`); reader isolate ends on POLLHUP/stop flag and closes its dup; `NativeFinalizer` frees state (`lib/src/impl/unix.dart:195-220,392-446`). Windows closes the pseudo console (`impl/windows.dart:127-132`) | no: everything CLOEXEC (`pty_unix_spawn.c:870-873,426-456`), explicit `Future<void> close()` closes master, slave, pipes, joins workers (`src/unix/pty_unix_session.c:540-560`); `NativeFinalizer` → `pty_session_abandon` if the Dart object is dropped. Windows: `ClosePseudoConsole` + handle cleanup (`src/windows/pty_windows_session.c:150,225,274,726-736`) | yes (flutter_pty_new also yes; kyroon closes the Windows pipe ends) |
| SIGTERM close (interactive shells ignore it) | default `sigterm` (`lib/flutter_pty.dart:190`) | `kill()` closes the master and also sends SIGHUP to the process group when the signal is not KILL/HUP (`impl/unix.dart:266-287`) | `close()`/`kill()` send **SIGKILL** to the foreground process group and the shell's group (`pty_unix_session.c:562-579`); `sendSignal(PosixSignal.hup, target: shellProcessGroup)` available (Unix only; `PtyUnsupportedException` on Windows); Windows uses a Job Object + `TerminateJobObject` so the whole tree dies (`pty_windows_spawn.c:218`, `pty_windows_session.c:606`) | same as flutter_pty |
| Blocking `write` on the UI thread | yes: `flutter_pty_unix.c:207` | **yes**: master fd stays blocking (no `O_NONBLOCK` anywhere), `write()` loops synchronously (`impl/unix.dart:314-361`); Windows `WriteFile` synchronous (`impl/windows.dart:765-781`) | no: master set `O_NONBLOCK` (`pty_unix_spawn.c:1234`), native write queue + writer thread; `PtyInput.write` returns a `Future`, `tryWrite` reports `backpressured`; input capped by `inputBufferBytes` (`lib/src/pty_input.dart`, `src/common/pty_write_queue.c`) | yes |
| Near-empty environment on Windows | yes: only TERM/LANG + 6 vars (`lib/flutter_pty.dart:61-84`) | no on Windows (null env → inherited; a map is merged over `GetEnvironmentStringsW`, `impl/windows.dart:240-245`). **Unix: allowlist of 6 vars + forced `LANG=en_US.UTF-8`** unless the caller passes them (`impl/unix.dart:60-79`) | no: default `PtyEnvironment.inherit(overrides:, remove:)`, full `Platform.environment`, case-folded on Windows (`lib/src/pty_environment.dart`, `internal/ffi_driver.dart:34-36`) | yes |
| Forced `LANG` | yes (`lib/flutter_pty.dart:63`) | yes by default (overridable) | no | yes |
| `Sleep(1000)` on Windows start | yes (`src/flutter_pty_win.c:365`) | no | no (only condition-variable waits) | kyroon removed it; flutter_pty_new keeps it |
| Lost output tail at exit | yes (two ports, `_onExitCode` closes stdout) | stream closes when the reader sees HUP; exit on a separate isolate, ordering not guaranteed | no: `done` "completes after the child exits and all native output is delivered" (`lib/src/pty_session.dart`); `processExit` separate | yes |

## API shape

| | flutter_pty 0.4.2 | pty2 0.8.0 | flutter_pty2 3.0.0 |
|---|---|---|---|
| Start | `Pty.start(...)` sync | `PseudoTerminal.start(exe, args, ...)` sync; **no initial size** (hard-coded 80×20, `impl/unix.dart:152-153`) | `Pty.spawn(PtySpawnOptions(executable, arguments, workingDirectory, environment, size: PtySize(columns:, rows:)))` → **`Future<PtySession>`** |
| Output | `Stream<Uint8List>` | **`Stream<String>`** (UTF-8 decoded in an isolate, malformed replaced) | `Stream<Uint8List>`, single subscription, pause = backpressure |
| Input | `write(Uint8List)` sync | **`write(String)`** sync | `input.write(Uint8List)` → Future; `tryWrite` |
| Resize | `resize(rows, cols)` | `resize(width, height)` | `resize(PtySize(columns:, rows:))` (named) |
| Exit | `Future<int>` | `Future<int>` (signal → 128+n) | `processExit`/`done`: `PtyExitCode(code)` or `PtySignalExit(signal)` |
| Signals | `kill([signal])` via `Process.killPid` | `kill([signal])` | `sendSignal(PosixSignal, target:)`, `kill()`, `close()`; `capabilities` |
| Threads | 2 native threads per pty, never joined | 2 isolates per pty | native reactor/worker threads, joined on close |
| Platforms (pub tags) | Linux, macOS, Windows, Android (iOS tag, but fork is not allowed there) | Linux, macOS, Windows | Linux, macOS, Windows, Android (iOS tag, same caveat) |
| Flutter needed | yes (plugin) | no | no |

## Recommendation

**Switch the demo to `flutter_pty2` 3.0.0, pinned exactly**, and recommend it in
our READMEs as "a pty package that works with `VtTerminalController.writeBytes`"
(our packages stay pty-agnostic; no dependency from any published package).

Why: it is the only candidate that fixes every defect the review found
(exec failure reported as an exception, no fd/thread leaks, real `close()`,
non-blocking writes with backpressure, full inherited environment, no forced
`LANG`, no `Sleep`, output drained before `done`). Its API is bytes in/bytes out
like ours. Its build code is a 54-line native-assets hook over its own C sources
with no network and no process spawning, and it adds **zero new packages** to our
lockfile (its deps are already locked). Being a native-assets package rather than
a Flutter plugin, it also removes the **CocoaPods** requirement on macOS and the
Windows plugin-symlink requirement. 3.0.0 is 20 days old (cooldown ok).

Risks to record: small project (2 likes, 489 downloads/30 d), three majors in
four months, its own CI was failing on the last runs and 3.0.0 was released
without one, and a native-assets C build now runs wherever the demo's
dependencies are built (including `flutter test` in `demo:test` on all three CI
OSes): Linux needs `clang` on PATH (native_toolchain_c has no gcc fallback;
present on ubuntu-latest and required by Flutter Linux desktop anyway), Windows
needs MSVC, macOS Xcode. Re-review the C sources before any upgrade.

Not chosen: **pty2** (good spawn/fd hygiene, but `String` I/O, blocking writes,
no initial size, Unix env allowlist + forced LANG, very fast release churn,
adds `win32`); **flutter_pty** (unmaintained, defects above); **kyroon_pty /
flutter_pty_new** (unverified publishers, 1 star, keep most defects);
**portable_pty** (build-time binary download + Rust fallback).

## Exact demo changes (for the implementing task)

1. `apps/demo/pubspec.yaml`: replace `flutter_pty: 0.4.2` with
   `flutter_pty2: 3.0.0` and rewrite the comment (native-assets hook compiles its
   own C with native_toolchain_c, no download, reviewed 2026-11-10, exact pin).
   `mise run deps`; the lock diff must only drop `flutter_pty` and add
   `flutter_pty2` 3.0.0 (sha256 `9802f793109fe7241cc172780571d501e50db6b247624a6b7c4df889bb9cbfe6`).
   `mise run cooldown`.
2. `DemoShellFactory` becomes async: `Future<DemoShell> Function(int cols, int rows)`.
   `startDefaultShell` awaits `PtyShell.start` and keeps the `FakeShell(notice:)`
   fallback in a `try`/`on PtyException`/`on Object`. `FakeShell` is wrapped in
   `Future.value`. `DemoApp._start` awaits it (guard with `mounted` and an epoch
   so a restart during spawn disposes the stale shell); tests' factories return
   `Future.value(...)`.
3. `apps/demo/lib/src/shell/pty_shell.dart` on `PtySession`:
   - spawn: `Pty.spawn(PtySpawnOptions(executable: shell, arguments: Platform.isWindows ? [] : ['-l'], workingDirectory: home, environment: PtyEnvironment.inherit(overrides: {'TERM': 'xterm-256color', 'COLORTERM': 'truecolor'}), size: PtySize(columns: cols, rows: rows)))`.
     Drop the `/bin/sh -c 'exec "$0" "$@"'` wrapper (exec failure now throws) and
     the env spreading/LANG workaround.
   - `output` → `session.output`; `exitCode` → `session.done.then((e) => switch (e) { PtyExitCode(:final code) => code, PtySignalExit(:final signal) => 128 + signal })`
     (use `done`, not `processExit`, so the tail is shown before the banner).
   - `write` → `session.input.tryWrite(data)`; on `backpressured` fall back to
     `unawaited(session.input.write(data))` (order is preserved by the queue);
     drop on `closed`. Keep the "no input after exit" guard.
   - `resize` → `session.resize(PtySize(columns: cols, rows: rows))` (no more
     rows/cols swap).
   - `dispose` → on Unix, if running, `sendSignal(PosixSignal.hup, target: PosixSignalTarget.shellProcessGroup)`,
     then `unawaited(session.done.timeout(const Duration(seconds: 2)).whenComplete(session.close))`
     (or `.catchError` → `close()`); on Windows just `close()`.
4. `apps/demo/README.md`: replace the flutter_pty "Known limitations" list with
   the flutter_pty2 notes (risks above, clang/MSVC/Xcode needed to build, macOS
   sandbox still off); delete "needs CocoaPods for flutter_pty".
   CONTRIBUTING: the Windows Developer-Mode/symlink note is no longer needed if
   the demo has no other plugin (check `windows/flutter/generated_plugins.cmake`).
5. ADR 0011 "Demo app" paragraph: record the switch and the reason (one line,
   link this research), and the T4.md alternatives paragraph's portable_pty
   correction (own downloader + Rust fallback, not `native_prebuilt`).
6. Verify: `mise run demo:test`, `mise run check`, a manual run on Linux
   (`mise run demo:run`): start, type, big paste into `sleep 100` (UI must not
   freeze), `exit` (tail then banner), Restart ×20 (`ls /proc/<pid>/fd | wc -l`
   stable), `SHELL=/nonexistent` (fake-shell fallback with notice).
