// Unit tests of the pure pointer mappings (ADR 0011).

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/src/input/pointer/pointer_mapping.dart';

void main() {
  group('isRectangleSelect', () {
    test('Option on Apple platforms', () {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
        expect(isRectangleSelect(KeyModifiers.alt, platform), isTrue);
        expect(isRectangleSelect(KeyModifiers.ctrl, platform), isFalse);
        expect(isRectangleSelect(KeyModifiers.none, platform), isFalse);
      }
    });

    test('Ctrl+Alt or Super+Alt elsewhere', () {
      for (final platform in [
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.android,
        TargetPlatform.fuchsia,
      ]) {
        expect(isRectangleSelect(KeyModifiers.alt, platform), isFalse);
        expect(
          isRectangleSelect(KeyModifiers.ctrl | KeyModifiers.alt, platform),
          isTrue,
        );
        expect(
          isRectangleSelect(KeyModifiers.superKey | KeyModifiers.alt, platform),
          isTrue,
        );
        expect(isRectangleSelect(KeyModifiers.ctrl, platform), isFalse);
      }
    });
  });

  test('buttons map to terminal buttons, lowest first', () {
    expect(mouseButtonOf(kPrimaryButton), MouseButton.left);
    expect(mouseButtonOf(kSecondaryButton), MouseButton.right);
    expect(mouseButtonOf(kMiddleMouseButton), MouseButton.middle);
    expect(mouseButtonOf(kBackMouseButton), MouseButton.eight);
    expect(mouseButtonOf(kForwardMouseButton), MouseButton.nine);
    expect(mouseButtonOf(0x20), isNull);
    expect(buttonBits(kSecondaryButton | kPrimaryButton | 0x20).toList(), [
      kPrimaryButton,
      kSecondaryButton,
    ]);
    expect(
      heldButtonOf(kSecondaryButton | kMiddleMouseButton),
      MouseButton.right,
    );
    expect(heldButtonOf(0), isNull);
  });

  test('every mouse shape has a cursor', () {
    for (final shape in MouseShape.values) {
      expect(mouseCursorForShape(shape), isA<MouseCursor>());
    }
    expect(mouseCursorForShape(MouseShape.text), SystemMouseCursors.text);
    expect(
      mouseCursorForShape(MouseShape.text, text: SystemMouseCursors.precise),
      SystemMouseCursors.precise,
    );
    expect(mouseCursorForShape(MouseShape.pointer), SystemMouseCursors.click);
    expect(
      mouseCursorForShape(MouseShape.notAllowed),
      SystemMouseCursors.forbidden,
    );
    expect(
      mouseCursorForShape(MouseShape.defaultShape),
      SystemMouseCursors.basic,
    );
  });

  group('terminalMouseCursor', () {
    MouseCursor cursor({
      bool tracking = false,
      MouseShape shape = MouseShape.text,
      KeyModifiers modifiers = KeyModifiers.none,
      TargetPlatform platform = TargetPlatform.linux,
    }) => terminalMouseCursor(
      tracking: tracking,
      shape: shape,
      modifiers: modifiers,
      platform: platform,
    );

    test('I-beam by default, arrow while tracked', () {
      expect(cursor(), SystemMouseCursors.text);
      expect(cursor(tracking: true), SystemMouseCursors.basic);
    });

    test('Shift selects: I-beam even while tracked', () {
      expect(
        cursor(tracking: true, modifiers: KeyModifiers.shift),
        SystemMouseCursors.text,
      );
      expect(
        cursor(shape: MouseShape.wait, modifiers: KeyModifiers.shift),
        SystemMouseCursors.text,
      );
    });

    test('crosshair while a drag would select a block', () {
      final block = KeyModifiers.ctrl | KeyModifiers.alt;
      expect(cursor(modifiers: block), SystemMouseCursors.precise);
      expect(
        cursor(tracking: true, modifiers: block),
        SystemMouseCursors.basic,
        reason: 'the program gets the drag without Shift',
      );
      expect(
        cursor(tracking: true, modifiers: block | KeyModifiers.shift),
        SystemMouseCursors.precise,
      );
      expect(
        cursor(modifiers: KeyModifiers.alt, platform: TargetPlatform.macOS),
        SystemMouseCursors.precise,
      );
    });

    test("the program's OSC 22 shape wins otherwise", () {
      expect(cursor(shape: MouseShape.pointer), SystemMouseCursors.click);
      expect(
        cursor(tracking: true, shape: MouseShape.crosshair),
        SystemMouseCursors.precise,
      );
    });
  });

  testWidgets('currentKeyModifiers reads the hardware keyboard', (
    tester,
  ) async {
    expect(currentKeyModifiers(), KeyModifiers.none);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlRight);
    final held = currentKeyModifiers();
    expect(held.hasShift, isTrue);
    expect(held.hasCtrl, isTrue);
    expect(held.hasAlt, isFalse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(currentKeyModifiers(), KeyModifiers.none);
  });
}
