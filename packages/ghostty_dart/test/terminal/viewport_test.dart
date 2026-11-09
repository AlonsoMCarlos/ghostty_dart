// Viewport scrolling over real scrollback.

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

/// A 10x3 terminal with 20 lines written: 17 rows of scrollback.
void withScrollback(void Function(VtTerminal terminal) body) =>
    withTerminal(10, 3, (terminal) {
      writeText(terminal, List.generate(20, (i) => 'line $i').join('\r\n'));
      body(terminal);
    });

void main() {
  test('starts pinned to the active area', () {
    withScrollback((terminal) {
      expect(terminal.isViewportActive, isTrue);
      expect(
        terminal.scrollbar,
        const ViewportScrollbar(total: 20, offset: 17, length: 3),
      );
    });
  });

  test('top, bottom, delta and row', () {
    withScrollback((terminal) {
      terminal.scrollViewport(const ViewportScroll.top());
      expect(terminal.scrollbar.offset, 0);
      expect(terminal.isViewportActive, isFalse);

      terminal.scrollViewport(const ViewportScroll.delta(5));
      expect(terminal.scrollbar.offset, 5);
      terminal.scrollViewport(const ViewportScroll.delta(-2));
      expect(terminal.scrollbar.offset, 3);

      terminal.scrollViewport(const ViewportScroll.row(10));
      expect(terminal.scrollbar.offset, 10);
      expect(terminal.scrollbar.isAtBottom, isFalse);

      terminal.scrollViewport(const ViewportScroll.bottom());
      expect(terminal.scrollbar.offset, 17);
      expect(terminal.isViewportActive, isTrue);
    });
  });

  test('deltas and rows are clamped to the scrollable area', () {
    withScrollback((terminal) {
      terminal.scrollViewport(const ViewportScroll.delta(-1000));
      expect(terminal.scrollbar.offset, 0);
      terminal.scrollViewport(const ViewportScroll.delta(1000));
      expect(terminal.scrollbar.offset, 17);
      terminal.scrollViewport(const ViewportScroll.row(1 << 40));
      expect(terminal.scrollbar.offset, 17);
    });
  });

  test('a scrollbar offset round-trips through ViewportScroll.row', () {
    withScrollback((terminal) {
      terminal.scrollViewport(const ViewportScroll.delta(-7));
      final saved = terminal.scrollbar;
      terminal.scrollViewport(const ViewportScroll.top());
      terminal.scrollViewport(ViewportScroll.row(saved.offset));
      expect(terminal.scrollbar, saved);
    });
  });

  test('prompt navigation follows OSC 133 markers; zero is a no-op', () {
    withTerminal(10, 3, (terminal) {
      for (var i = 0; i < 4; i++) {
        writeText(terminal, '\x1b]133;A\x07\$ cmd$i\r\n');
        writeText(terminal, List.generate(4, (j) => 'out$j').join('\r\n'));
        writeText(terminal, '\r\n');
      }
      final bottom = terminal.scrollbar.offset;
      terminal.scrollViewport(const ViewportScroll.prompts(0));
      expect(terminal.scrollbar.offset, bottom);
      terminal.scrollViewport(const ViewportScroll.prompts(-1));
      final previous = terminal.scrollbar.offset;
      expect(previous, lessThan(bottom));
      terminal.scrollViewport(const ViewportScroll.prompts(-1));
      expect(terminal.scrollbar.offset, lessThan(previous));
      terminal.scrollViewport(const ViewportScroll.prompts(1));
      expect(terminal.scrollbar.offset, previous);
    });
  });

  test('the alternate screen stays on the active area', () {
    withScrollback((terminal) {
      writeText(terminal, '\x1b[?1049h');
      terminal.scrollViewport(const ViewportScroll.top());
      expect(terminal.isViewportActive, isTrue);
      expect(terminal.scrollbar.total, 3);
    });
  });

  test('negative rows throw RangeError; scrolling bumps the epoch', () {
    withScrollback((terminal) {
      expect(
        () => terminal.scrollViewport(const ViewportScroll.row(-1)),
        throwsRangeError,
      );
      final handle = handleOf<GhosttyTerminalImpl>(terminal);
      final before = handle.epoch;
      terminal.scrollViewport(const ViewportScroll.top());
      expect(handle.epoch, before + 1);
    });
  });

  test('ViewportScroll values have value equality', () {
    expect(const ViewportScroll.top(), const ScrollToTop());
    expect(const ViewportScroll.bottom(), isNot(const ViewportScroll.top()));
    expect(const ViewportScroll.delta(3), const ScrollByRows(3));
    expect(const ViewportScroll.delta(3), isNot(const ViewportScroll.delta(4)));
    expect(const ViewportScroll.row(3), isNot(const ViewportScroll.delta(3)));
    expect(const ViewportScroll.prompts(-1), const ScrollByPrompts(-1));
    expect(const ViewportScroll.row(3).hashCode, const ScrollToRow(3).hashCode);
    expect('${const ViewportScroll.delta(-5)}', 'ViewportScroll.delta(-5)');
  });
}
