import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';

Finder _key(String label) =>
    find.byKey(ValueKey('ghostty_dart_flutter.toolbar.$label'));

void main() {
  late VtTerminalController controller;
  late List<String> output;

  Future<void> pumpToolbar(
    WidgetTester tester, {
    bool readOnly = false,
    double? height,
    Color latchedColor = VtTerminalKeyToolbar.defaultLatchedColor,
  }) async {
    output = [];
    controller = VtTerminalController(
      cols: 20,
      rows: 5,
      onOutput: (bytes) => output.add(utf8.decode(bytes)),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            child: VtTerminalKeyToolbar(
              controller: controller,
              readOnly: readOnly,
              height: height,
              latchedColor: latchedColor,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('Esc, Tab and the arrows are sent through the encoder', (
    tester,
  ) async {
    await pumpToolbar(tester);
    for (final label in ['Escape', 'Tab', 'Left', 'Down', 'Up', 'Right']) {
      await tester.tap(_key(label));
    }
    expect(output, ['\x1b', '\t', '\x1b[D', '\x1b[B', '\x1b[A', '\x1b[C']);
    // Cursor key application mode (DECCKM).
    controller.write('\x1b[?1h');
    await tester.tap(_key('Up'));
    expect(output.last, '\x1bOA');
  });

  testWidgets('Ctrl and Alt latch for one key and show it', (tester) async {
    await pumpToolbar(tester);
    final latched = ControllerSeams(controller).latchedModifiers;
    await tester.tap(_key('Control'));
    await tester.pump();
    expect(latched.value, KeyModifiers.ctrl);
    expect(
      tester.getSemantics(_key('Control')),
      matchesSemantics(
        isButton: true,
        hasToggledState: true,
        isToggled: true,
        label: 'Control',
        hasTapAction: true,
      ),
    );
    await tester.tap(_key('Alt'));
    expect(latched.value, KeyModifiers.ctrl | KeyModifiers.alt);
    await tester.tap(_key('Up'));
    expect(output, ['\x1b[1;7A']);
    expect(latched.value, KeyModifiers.none);
    await tester.tap(_key('Up'));
    expect(output.last, '\x1b[A');
  });

  testWidgets('tapping a latched modifier releases it', (tester) async {
    await pumpToolbar(tester);
    final latched = ControllerSeams(controller).latchedModifiers;
    await tester.tap(_key('Control'));
    await tester.tap(_key('Control'));
    expect(latched.value, KeyModifiers.none);
  });

  testWidgets('the keys never take the focus', (tester) async {
    await pumpToolbar(tester);
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            Focus(focusNode: node, child: const SizedBox(height: 10)),
            VtTerminalKeyToolbar(controller: controller),
          ],
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    await tester.tap(_key('Escape'));
    await tester.pump();
    expect(node.hasFocus, isTrue);
  });

  testWidgets('a disposed controller shows an empty bar', (tester) async {
    await pumpToolbar(tester);
    controller.dispose();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: VtTerminalKeyToolbar(controller: controller),
      ),
    );
    expect(_key('Escape'), findsNothing);
  });

  testWidgets('readOnly sends and latches nothing', (tester) async {
    await pumpToolbar(tester, readOnly: true);
    await tester.tap(_key('Escape'));
    await tester.tap(_key('Control'));
    expect(output, isEmpty);
    expect(
      ControllerSeams(controller).latchedModifiers.value,
      KeyModifiers.none,
    );
  });

  testWidgets('height follows the platform touch target, or is given', (
    tester,
  ) async {
    await pumpToolbar(tester);
    final expected = switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => 44.0,
      _ => 48.0,
    };
    expect(tester.getSize(find.byType(VtTerminalKeyToolbar)).height, expected);
  }, variant: TargetPlatformVariant.all());

  testWidgets('a given height and latched colour are used', (tester) async {
    await pumpToolbar(
      tester,
      height: 60,
      latchedColor: const Color(0xFF00FF00),
    );
    expect(tester.getSize(find.byType(VtTerminalKeyToolbar)).height, 60);
    await tester.tap(_key('Alt'));
    await tester.pump();
    final fill = find.descendant(
      of: _key('Alt'),
      matching: find.byType(ColoredBox),
    );
    expect(tester.widget<ColoredBox>(fill).color, const Color(0xFF00FF00));
  });
}
