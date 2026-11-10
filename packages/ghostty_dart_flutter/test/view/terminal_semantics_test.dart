// Accessibility of the view (ADR 0011, "Accessibility (v1)"): the visible
// text as one semantics node, only while semantics are on, and opt-in,
// rate-limited announcements of new output.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/src/input/pointer/terminal_pointer_scope.dart';
import 'package:ghostty_dart_flutter/src/view/terminal_semantics.dart';

import 'view_harness.dart';

/// The view's semantics node widget, found by its label.
final _terminalNode = find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == 'Terminal',
);

/// Records the announcements sent on the accessibility channel.
List<String> recordAnnouncements(WidgetTester tester) {
  final messages = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
    SystemChannels.accessibility,
    (message) async {
      final map = message! as Map<Object?, Object?>;
      if (map['type'] == 'announce') {
        final data = map['data']! as Map<Object?, Object?>;
        messages.add(data['message']! as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
          SystemChannels.accessibility,
          null,
        ),
  );
  return messages;
}

void main() {
  testWidgets('no semantics node and no text reads while semantics are '
      'off', (tester) async {
    final h = await pumpTerminalView(tester);
    h.controller.write('hello');
    await tester.pump(TerminalSemantics.updateInterval * 2);
    expect(_terminalNode, findsNothing);
  }, semanticsEnabled: false);

  testWidgets('the visible text is the node value, updated at most every '
      'updateInterval', (tester) async {
    final semantics = tester.ensureSemantics();
    final h = await pumpTerminalView(tester);
    h.controller.write('hello\r\nworld');
    await tester.pump();
    expect(_terminalNode, findsOneWidget);
    // Not read yet: the first read was the blank screen.
    expect(tester.getSemantics(_terminalNode).value, '');
    await tester.pump(TerminalSemantics.updateInterval);
    final node = tester.getSemantics(_terminalNode);
    expect(node.label, 'Terminal');
    expect(node.value, 'hello\nworld');
    expect(node.flagsCollection.isMultiline, isTrue);
    // An interactive view is not announced as read-only.
    expect(node.flagsCollection.isReadOnly, isFalse);
    semantics.dispose();
  }, semanticsEnabled: false);

  testWidgets('the read-only flag follows readOnly', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpTerminalView(tester, readOnly: true);
    expect(
      tester.getSemantics(_terminalNode).flagsCollection.isReadOnly,
      isTrue,
    );
    semantics.dispose();
  }, semanticsEnabled: false);

  testWidgets('toggling accessibility keeps the view mounted', (tester) async {
    await pumpTerminalView(tester);
    // The pointer layer's state (press in progress, wheel remainder) is
    // outside the input layer's GlobalKey, so a remount would replace it.
    State<StatefulWidget> pointerState() =>
        tester.state(find.byType(TerminalPointerScope));
    final before = pointerState();
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(_terminalNode, findsOneWidget);
    expect(identical(pointerState(), before), isTrue);
    semantics.dispose();
    await tester.pump();
    expect(identical(pointerState(), before), isTrue);
  }, semanticsEnabled: false);

  testWidgets('turning semantics on reads the screen at once', (tester) async {
    final h = await pumpTerminalView(tester);
    h.controller.write('already here');
    await tester.pump();
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(tester.getSemantics(_terminalNode).value, 'already here');
    semantics.dispose();
  }, semanticsEnabled: false);

  testWidgets('new output is announced only when asked, coalesced', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final messages = recordAnnouncements(tester);
    final h = await pumpTerminalView(tester, announceOutput: true);
    h.controller.write(r'$ ls');
    await tester.pump(TerminalSemantics.updateInterval);
    expect(messages, [r'$ ls']);
    // Two writes within one interval: one announcement with both.
    h.controller
      ..write('\r\nfile1')
      ..write('\r\nfile2');
    await tester.pump(TerminalSemantics.updateInterval);
    expect(messages, [r'$ ls', 'file1\nfile2']);
    // Scrolling output announces only the new lines.
    writeLines(h.controller, 12);
    await tester.pump(TerminalSemantics.updateInterval);
    // Rows that scrolled away within the interval were never visible.
    expect(messages.last, [for (var i = 3; i < 12; i++) 'line $i'].join('\n'));
    semantics.dispose();
  }, semanticsEnabled: false);

  testWidgets('no announcements by default', (tester) async {
    final semantics = tester.ensureSemantics();
    final messages = recordAnnouncements(tester);
    final h = await pumpTerminalView(tester);
    h.controller.write('quiet');
    await tester.pump(TerminalSemantics.updateInterval);
    expect(messages, isEmpty);
    semantics.dispose();
  }, semanticsEnabled: false);

  testWidgets('the tap action focuses the view', (tester) async {
    final semantics = tester.ensureSemantics();
    final h = await pumpTerminalView(tester, autofocus: false);
    tester.semantics.tap(find.semantics.byLabel('Terminal'));
    await tester.pump();
    await tester.pump();
    expect(h.render.focused, isTrue);
    semantics.dispose();
  }, semanticsEnabled: false);

  testWidgets('disposing the controller with semantics on', (tester) async {
    final semantics = tester.ensureSemantics();
    final h = await pumpTerminalView(tester);
    h.controller
      ..write('x')
      ..dispose();
    await tester.pump(TerminalSemantics.updateInterval);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
    semantics.dispose();
  }, semanticsEnabled: false);

  group('newOutput', () {
    test('first snapshot: every non-blank line', () {
      expect(newOutput(const [], ['a', '', 'b']), 'a\nb');
    });

    test('a changed cursor row', () {
      expect(newOutput(['\$', ''], [r'$ ls', '']), r'$ ls');
    });

    test('output that scrolled the screen', () {
      expect(
        newOutput(['a', 'b', 'c', r'$ ls'], ['c', r'$ ls', 'x', 'y']),
        'x\ny',
      );
    });

    test('a cleared screen announces what is new', () {
      expect(newOutput(['a', 'b'], ['', 'c']), 'c');
      expect(newOutput(['a', 'b'], ['a', 'b']), '');
    });
  });
}
