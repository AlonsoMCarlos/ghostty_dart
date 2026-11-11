import 'package:ghostty_dart/ghostty_dart.dart';

import '../input/pointer/mouse_reports.dart';
import '../seams/terminal_seams.dart';

/// Decides where a scroll of whole rows goes: wheel reports to the
/// program, alternate-scroll arrows, or the viewport. Shared by the
/// pointer layer and the scrollbar so the wheel and the trackpad act the
/// same over both (ADR 0011). Never exported.
///
/// Follows Ghostty's `scrollCallback` (`src/Surface.zig` at tag
/// `vt-1.0.0`):
/// 1. while the program tracks the mouse, every row is a wheel report
///    (buttons 4/5, columns 6/7) and a selection is cleared;
/// 2. otherwise, on the alternate screen, DEC 1007 turns every row into
///    the raw cursor-key sequence (`ESC [ A`/`ESC [ B`, or `ESC O A`/
///    `ESC O B` in application cursor-key mode, DEC 1), press only, and
///    clears the selection; without DEC 1007 nothing happens;
/// 3. otherwise the viewport scrolls.
///
/// One deviation, from the input research (xterm2): with Shift held the
/// rows always scroll the scrollback, never reports or arrows (Shift is
/// the "select instead of reporting" modifier).
///
/// [reports] may turn a wheel step down ([MouseReports.allows]): that row
/// then goes on to step 2 or 3 as if the program did not track the mouse
/// (a column is dropped), and an accepted step goes through
/// [MouseReports.send].
final class TerminalScrollRouter {
  /// A router over [viewport]. Without [pointer] every scroll moves the
  /// viewport (there are no modes to read). [text] carries the raw
  /// alternate-scroll sequences; without it the arrows go through
  /// [keys] (the key encoder, which differs from Ghostty under the Kitty
  /// keyboard protocol), and without either they are dropped.
  const TerminalScrollRouter({
    required this.viewport,
    this.pointer,
    this.keys,
    this.text,
    this.reports = MouseReports.none,
  });

  /// The viewport to scroll.
  final TerminalViewport viewport;

  /// Mouse tracking, modes and wheel reports.
  final TerminalPointerSink? pointer;

  /// Fallback for the alternate-scroll arrows.
  final TerminalKeySink? keys;

  /// Where the raw alternate-scroll sequences go.
  final TerminalTextSink? text;

  /// The view's mouse report filter and hook, for wheel reports.
  final MouseReports reports;

  /// Whether a scroll would do anything now: the viewport has scrollback,
  /// or the program gets the rows (tracking, or the alternate screen with
  /// DEC 1007). Touch and trackpad drags only claim the pointer then, so
  /// an enclosing scrollable keeps working over a terminal with nothing to
  /// scroll.
  bool get canScroll {
    if (viewport.isDisposed) return false;
    final bar = viewport.scrollbar;
    if (bar.total > bar.length) return true;
    final pointer = this.pointer;
    if (pointer == null || pointer.isDisposed) return false;
    return pointer.isMouseTracking ||
        (viewport.isAlternateScreen &&
            pointer.isModeEnabled(TerminalMode.mouseAlternateScroll));
  }

  /// Scrolls by [rows] (positive is down, towards newer output) and
  /// [cols] (positive is right; only ever reported). [surface] is the
  /// pointer in surface (device) pixels, for reports, and [cell] the
  /// viewport cell under it, for [MouseReports.send].
  void scroll(
    int rows, {
    int cols = 0,
    required ({double x, double y}) surface,
    required KeyModifiers modifiers,
    GridPoint cell = const GridPoint.viewport(0, 0),
  }) {
    if (viewport.isDisposed || (rows == 0 && cols == 0)) return;
    final pointer = this.pointer;
    final shift = modifiers.hasShift;
    if (pointer != null && !shift && pointer.isMouseTracking) {
      var cleared = false;
      // Returns how many of [count] steps the filter turned down.
      int report(MouseButton button, int count) {
        var refused = 0;
        for (var i = 0; i < count; i++) {
          final event = VtMouseEvent(
            action: MouseAction.press,
            button: button,
            modifiers: modifiers,
            x: surface.x,
            y: surface.y,
          );
          if (!reports.allows(event)) {
            refused++;
            continue;
          }
          if (!cleared) {
            cleared = true;
            _clearSelection(pointer);
          }
          reports.send(pointer, event, cell);
        }
        return refused;
      }

      final refusedRows = report(
        rows < 0 ? MouseButton.four : MouseButton.five,
        rows.abs(),
      );
      report(cols < 0 ? MouseButton.six : MouseButton.seven, cols.abs());
      if (refusedRows == 0) return;
      // The refused rows scroll as if the program did not track the mouse.
      rows = rows < 0 ? -refusedRows : refusedRows;
    }
    if (rows == 0) return;
    if (!shift && viewport.isAlternateScreen) {
      if (pointer == null ||
          !pointer.isModeEnabled(TerminalMode.mouseAlternateScroll)) {
        return;
      }
      _clearSelection(pointer);
      _sendArrows(pointer, rows);
      return;
    }
    viewport.scrollViewport(ViewportScroll.delta(rows));
  }

  void _sendArrows(TerminalPointerSink pointer, int rows) {
    final up = rows < 0;
    final text = this.text;
    if (text != null && !text.isDisposed) {
      final application = pointer.isModeEnabled(TerminalMode.cursorKeys);
      final sequence = '\x1b${application ? 'O' : '['}${up ? 'A' : 'B'}';
      text.sendText(sequence * rows.abs());
      return;
    }
    final keys = this.keys;
    if (keys == null) return;
    final key = up ? VtKey.arrowUp : VtKey.arrowDown;
    for (var i = 0; i < rows.abs(); i++) {
      keys.sendKey(VtKeyEvent(key: key));
    }
  }

  static void _clearSelection(TerminalPointerSink pointer) {
    if (pointer.selection != null) pointer.selection = null;
  }
}
