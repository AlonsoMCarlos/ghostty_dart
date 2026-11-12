# xterm 4.0.0 compatibility tests

The tests of [xterm.dart](https://github.com/TerminalStudio/xterm.dart) 4.0.0
(MIT, Copyright (c) 2020 xuty, see [`LICENSE.xterm`](LICENSE.xterm)), ported to
run against `ghostty_dart_xterm` (ADR 0004, ADR 0013). A failing compat test is
a bug, not a flaky test.

Run them with `mise exec -- flutter test test/compat` in
`packages/ghostty_dart_xterm` (they also run with the rest of the package's
tests in `mise run test:xterm`).

## Rules

- Each ported file starts with xterm's MIT notice and a `Changes:` line that
  lists every adaptation. The usual ones: `package:test` becomes
  `flutter_test`, `package:xterm` becomes `package:ghostty_dart_xterm`, debug
  `print`s are dropped, and a collection literal gets a type argument where our
  stricter analyzer settings ask for one. No assertion is weakened.
- Tests import the public libraries (`xterm.dart`, `core.dart`, `ui.dart`).
  Where xterm's test imports an unexported xterm file that the adapter also
  ports unexported (`Keytab`, `MouseReporter`), the import points at the same
  file under this package's `src/`.
- A test that hits a **documented difference** (a ⚠️ or 🚫 row in
  [`COMPATIBILITY.md`](../../COMPATIBILITY.md)) is kept unchanged and skipped
  with `skip: 'differs from xterm: <reason>, see COMPATIBILITY.md'`, naming the
  member. Right after it, a test marked `// ghostty_dart_xterm: … Not part of
  xterm's suite.` pins the documented behaviour instead.
- A test that hits an **adapter bug** is skipped with
  `skip: 'adapter bug: <one line> (see ...)'` until the bug is fixed. There are
  none in `core/` today.
- Tests of xterm internals the adapter does not have are not ported. Where
  the behaviour still matters, a replacement test checks it through `Terminal`
  (no xterm header, since it is not a copy).
- No mockito: the one mock in xterm's suite is a hand-written fake here.

## `core/` (from `test/src/core/**` and `test/src/terminal_test.dart`)

| xterm file | Here | Ported | Pass | Skipped (documented difference) |
|---|---|---:|---:|---:|
| `src/terminal_test.dart` | `core/terminal_test.dart` | 11 | 7 | 4: mouse row (`ClickMouseHandler.call`), hidden cells without reflow (`Terminal.reflowEnabled`), OSC 66 ×2 (`Terminal.onPrivateOSC`) |
| `src/core/buffer/buffer_test.dart` | `core/buffer/buffer_test.dart` | 13 | 13 | 0 |
| `src/core/buffer/line_test.dart` | `core/buffer/line_test.dart` | 12 | 11 | 1: anchor after IL (`CellAnchor`) |
| `src/core/buffer/range_block_test.dart` | `core/buffer/range_block_test.dart` | 9 | 9 | 0 |
| `src/core/buffer/range_line_test.dart` | `core/buffer/range_line_test.dart` | 9 | 9 | 0 |
| `src/core/buffer/segment_test.dart` | `core/buffer/segment_test.dart` | 1 | 1 | 0 |
| `src/core/reflow_test.dart` | `core/reflow_test.dart` | 4 | 4 | 0 |
| `src/core/input/handler_test.dart` | `core/input/handler_test.dart` | 2 | 2 | 0 |
| `src/core/input/keytab/keytab_test.dart` | `core/input/keytab/keytab_test.dart` | 1 | 1 | 0 |
| `src/core/mouse/reporter_test.dart` | `core/mouse/reporter_test.dart` | 4 | 2 | 2: mouse row, normal and utf (`ClickMouseHandler.call`) |
| **Total** | | **66** | **59** | **7** |

Besides the ported tests, `core/` has 7 marked tests of the documented
behaviour (one after each skipped test) and 5 replacement tests:

| Not ported (xterm internal) | Replacement |
|---|---|
| `src/core/tabs_test.dart` (3 tests, `TabStops`) | `core/tabs_test.dart` (3): default stops every 8 columns, end excluded, set/clear through `Terminal` |
| `src/core/escape/parser_test.dart` (1 test, `EscapeParser` + mockito) | `core/escape/parser_test.dart` (2): `CSI 8;24;80 t` reaches `onResize` and resizes, also split across writes |
| `src/utils/circular_buffer_test.dart` (20 tests, `IndexAwareCircularBuffer`) | none: scrollback storage belongs to libghostty-vt; `maxLines` is covered by the adapter's own tests |

Not ported either: the four files that contain only commented-out xterm 2.x
tests (`buffer/buffer_line_test.dart`, `frontend/input_test.dart`,
`terminal/terminal_isolate_test.dart`, `terminal/terminal_search_test.dart`).

## `ui/` and `xterm_test.dart`

From `test/src/ui/controller_test.dart`, `test/src/terminal_view_test.dart`
and `test/xterm_test.dart`; see the headers of those files.

## `_fixture/`

`htop_80x25_3s.txt` and `colors.txt` are xterm's raw VT fixtures, copied
unchanged; `_fixture.dart` loads them from `test/compat/_fixture/`. xterm's
goldens are not reused: they are xterm's renderer pixels.
