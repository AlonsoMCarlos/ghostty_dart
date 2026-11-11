// Own tests of TerminalController without a view (xterm's own logic over
// anchors), and of its pointer settings.

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

Terminal _terminal() {
  final terminal = Terminal();
  addTearDown(terminal.dispose);
  return terminal;
}

TerminalController _controller() {
  final controller = TerminalController();
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  group('TerminalController without a view', () {
    test('selection follows the anchors and the mode', () {
      final terminal = _terminal();
      final controller = _controller();
      var notified = 0;
      controller.addListener(() => notified++);
      expect(controller.selection, isNull);

      final base = terminal.buffer.createAnchor(0, 0);
      final extent = terminal.buffer.createAnchor(2, 2);
      controller.setSelection(base, extent);
      expect(controller.selection, isA<BufferRangeLine>());
      expect(controller.selection!.begin, const CellOffset(0, 0));
      expect(controller.selection!.end, const CellOffset(2, 2));

      controller.setSelectionMode(SelectionMode.block);
      expect(controller.selection, isA<BufferRangeBlock>());
      // The same mode again changes nothing.
      controller.setSelectionMode(SelectionMode.block);

      controller.setSelection(
        terminal.buffer.createAnchor(1, 1),
        terminal.buffer.createAnchor(3, 1),
        mode: SelectionMode.line,
      );
      expect(controller.selectionMode, SelectionMode.line);
      // The anchors of the replaced selection were disposed.
      expect(base.attached, isFalse);
      expect(extent.attached, isFalse);

      controller.clearSelection();
      expect(controller.selection, isNull);
      expect(notified, 4);
    });

    test('highlights are listed until disposed', () {
      final terminal = _terminal();
      final controller = _controller();
      final highlight = controller.highlight(
        p1: terminal.buffer.createAnchor(5, 5),
        p2: terminal.buffer.createAnchor(5, 10),
        color: const Color(0xFFFFFF00),
      );
      expect(controller.highlights, [highlight]);
      expect(highlight.owner, same(controller));
      expect(highlight.range, isA<BufferRangeLine>());
      expect(highlight.range!.end, const CellOffset(5, 10));
      var disposedEvents = 0;
      highlight.onDisposed((_) => disposedEvents++);

      highlight.dispose();
      expect(controller.highlights, isEmpty);
      expect(highlight.disposed, isTrue);
      expect(disposedEvents, 1);
    });

    test('pointer settings', () {
      final controller = _controller();
      expect(controller.pointerInput.inputs, {PointerInput.tap});
      expect(controller.shouldSendPointerInput(PointerInput.tap), isTrue);
      expect(controller.shouldSendPointerInput(PointerInput.drag), isFalse);

      controller.setPointerInputs(const PointerInputs.all());
      expect(controller.shouldSendPointerInput(PointerInput.move), isTrue);

      controller.setSuspendPointerInput(true);
      expect(controller.suspendedPointerInputs, isTrue);
      expect(controller.shouldSendPointerInput(PointerInput.tap), isFalse);

      expect(const PointerInputs.none().inputs, isEmpty);
      expect(PointerInput.values, [
        PointerInput.tap,
        PointerInput.scroll,
        PointerInput.drag,
        PointerInput.move,
      ]);
    });
  });
}
