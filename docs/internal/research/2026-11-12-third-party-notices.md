# Third-party notices of the shipped code

Checked 2026-11-12, against the pinned sources: libghostty-vt 1.0.0
(`native/upstream.json`, tarball and deps tarball unpacked by
`tool/native/build.sh`), Zig 0.17.1 and Android NDK r28c (`mise.toml`,
`native/toolchain.json`), Flutter 3.47.9, pana 0.23.19. Reported by an app
built on the 0.1.0 packages: Flutter's generated `NOTICES` had no trace of
libghostty-vt's licence.

## What the prebuilt libghostty-vt contains

Upstream documents it: `PACKAGING-LIBGHOSTTY.md` ("license texts") and the
generated `deps/libghostty-vt-third-party.json` list every third-party project
of a libghostty-vt build; `"use": "linked"` means compiled into the library
(`src/build/LibVtPackages.zig` explains how the report follows every module,
C source and object reachable from the library's root module, "too much, but
never too little").

| Project | Licence (SPDX, upstream) | Text used | Notes |
|---|---|---|---|
| libghostty-vt | MIT | tarball `LICENSE` | |
| highway 1.2.0 | Apache-2.0 OR BSD-3-Clause | deps `N-V-__8AAGmZ…/LICENSE-BSD3` | `-Dsimd` (default on every native target) |
| simdutf 9.0.0 | Apache-2.0 OR MIT | `pkg/simdutf/vendor/LICENSE-MIT` | vendored; strings `SIMDUTF_*` in the .so |
| wuffs 0.4.0-alpha.10 | Apache-2.0 OR MIT | deps `N-V-__8AAP5J…/LICENSE-MIT` | strings `wuffs_*` in the .so (Kitty graphics PNG) |
| uucode 0.2.0 | MIT AND Unicode-3.0 | `LICENSE.md` (MIT part) + Unicode License v3 | tables generated from the UCD 18.0 files in `ucd/` (headers "© 2026 Unicode, Inc.") |
| translate_c 2.0.0 | MIT | deps `translate_c-…/LICENSE` | byte-identical to Zig's own `LICENSE` |
| aro | MIT AND Unicode-3.0 | — | `"use": "build"`: ships nothing |

For the dual-licensed projects the notices use the permissive-notice option
(BSD-3-Clause, MIT), which is what a binary redistribution has to reproduce.
The Unicode License v3 text comes from aro's `LICENSE-UNICODE` (identical
licence) with the copyright years set to 1991-2026 to match the UCD 18.0
files that uucode compiles in.

uucode's `LICENSE.md` also points at `licenses/LICENSE_Bjoern_Hoehrmann`
(not in the tarball). That licence covers `src/utf8.zig`, which libghostty-vt
reaches only from a Zig `test` block (`src/unicode/grapheme.zig:281`), so it
is not compiled into the library and upstream's report does not list it.

Toolchain code linked into the binaries, not in upstream's report:

- Zig's standard library and compiler-rt: MIT, "Copyright (c) Zig
  contributors" (`$(mise where zig)/LICENSE`, same text as translate_c's).
- Windows (`*-windows-gnu`): the DLL carries mingw-w64 runtime start-up code
  (string "Mingw-w64 runtime failure:"); ZPL 2.1 text from Zig's
  `lib/libc/mingw/COPYING`, whose clause 2 asks binary redistributions to
  reproduce the notice.
- Android: Zig links the NDK's `crtbegin_so.o`/`crtend_so.o`
  (`lib/std/zig/LibCInstallation.zig:751`); their bionic notice (BSD-2-Clause,
  "Copyright (C) 2008 The Android Open Source Project") is copied verbatim
  from the NDK r28c `sysroot/NOTICE`.
- Linux (glibc): the shared object links `crti.o`/`crtn.o` built from glibc,
  whose licence exception allows unrestricted distribution; libc, libm and
  librt are dynamic (`readelf -d`). Apple targets link libSystem dynamically.
  No notice needed.
- No libc++: the vendored C++ is built in no-libcxx mode
  (`src/build/GhosttyLibVt.zig:631`); `readelf -d` shows no libc++ dependency.

## How Flutter collects notices

`packages/flutter_tools/lib/src/license_collector.dart` (Flutter 3.47.9):

- For every package in `package_config.json` it reads `NOTICES`, and only
  when that file does not exist, `LICENSE`.
- A file holding more than one licence separates them with a line of exactly
  80 hyphens (`'\n${'-' * 80}\n'`); each licence starts with the package
  names, one per line, then a blank line, then the text. Identical texts are
  merged across packages.
- `asset.dart` also reads `flutter: licenses:` from a dependency's pubspec,
  but that needs a `flutter:` section, which the pure Dart `ghostty_dart`
  should not have.
- At run time `services/binding.dart` `_parseLicenses` splits the bundled
  NOTICES the same way for `LicenseRegistry`.

## Why `NOTICES` and not a multi-licence `LICENSE`

pana 0.23.19 (`lib/src/license.dart`) reads only `LICENSE`, and returns no
licence (`unknown`) when more than half of the tokens, or 50 consecutive
tokens, match no SPDX text. A combined file would at best be reported as a
list of seven licences on pub.dev, misdescribing the package's own licence,
and at worst as `unknown`, losing the OSI-licence points. A separate
`NOTICES` is read by Flutter in preference to `LICENSE` and ignored by pana,
so `LICENSE` stays plain MIT. The cost is that `NOTICES` must repeat
`LICENSE`; `tool/test/notices_test.dart` checks that it does.

## Other packages

- `ghostty_dart_flutter` bundles no third-party code or assets: the
  JetBrains Mono fonts are test-only and kept out of the archive by
  `.pubignore`. It needs no `NOTICES`; its users get ghostty_dart's.
- `ghostty_dart_xterm` ports xterm.dart 4.0.0 code into `lib/`. Flutter never
  read `LICENSE.xterm`, so its `NOTICES` now carries xterm's licence (the
  verbatim `LICENSE` of `xterm-4.0.0` in the pub cache).
