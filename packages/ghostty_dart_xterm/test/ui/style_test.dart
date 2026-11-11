// Own tests of the ported themes, text style, shortcuts and key maps.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/src/ui/input_map.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

void main() {
  test('TerminalStyle keeps xterm defaults and conversions', () {
    const style = TerminalStyle();
    expect(style.fontSize, 13);
    expect(style.height, 1.2);
    expect(style.fontFamily, 'monospace');
    expect(style.fontFamilyFallback.first, 'Menlo');
    expect(style.fontFamilyFallback.last, 'sans-serif');

    final text = style.toTextStyle(bold: true, underline: true);
    expect(text.fontWeight, FontWeight.bold);
    expect(text.decoration, TextDecoration.underline);
    expect(text.fontStyle, FontStyle.normal);

    final fromText = TerminalStyle.fromTextStyle(
      const TextStyle(fontFamilyFallback: ['Fira Code'], fontSize: 20),
    );
    expect(fromText.fontFamily, 'Fira Code');
    expect(fromText.fontSize, 20);
    expect(fromText.height, 1.2);

    final copy = style.copyWith(fontSize: 9);
    expect(copy.fontSize, 9);
    expect(copy.fontFamily, 'monospace');
  });

  test('TerminalThemes keep xterm colours', () {
    const theme = TerminalThemes.defaultTheme;
    expect(theme.background, const Color(0XFF1E1E1E));
    expect(theme.cursor, const Color(0XAAAEAFAD));
    expect(TerminalThemes.whiteOnBlack.background, const Color(0XFF000000));
    expect(TerminalCursorType.values, [
      TerminalCursorType.block,
      TerminalCursorType.underline,
      TerminalCursorType.verticalBar,
    ]);
    expect(SelectionMode.values, [SelectionMode.line, SelectionMode.block]);
  });

  test('defaultTerminalShortcuts follow the platform, as in xterm', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var shortcuts = defaultTerminalShortcuts;
    expect(
      shortcuts[const SingleActivator(
        LogicalKeyboardKey.keyC,
        control: true,
        shift: true,
      )],
      CopySelectionTextIntent.copy,
    );
    expect(
      shortcuts[const SingleActivator(LogicalKeyboardKey.keyV, control: true)],
      isA<PasteTextIntent>(),
    );
    expect(
      shortcuts[const SingleActivator(LogicalKeyboardKey.keyA, control: true)],
      isA<SelectAllTextIntent>(),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    shortcuts = defaultTerminalShortcuts;
    expect(
      shortcuts[const SingleActivator(LogicalKeyboardKey.keyV, meta: true)],
      isA<PasteTextIntent>(),
    );
  });

  test('keyToTerminalKey and charToTerminalKey map as in xterm', () {
    expect(keyToTerminalKey(LogicalKeyboardKey.keyA), TerminalKey.keyA);
    expect(keyToTerminalKey(LogicalKeyboardKey.enter), TerminalKey.enter);
    expect(keyToTerminalKey(LogicalKeyboardKey.f12), TerminalKey.f12);
    expect(charToTerminalKey('a'), TerminalKey.keyA);
    expect(charToTerminalKey('A'), TerminalKey.keyA);
    expect(charToTerminalKey('1'), TerminalKey.digit1);
    expect(charToTerminalKey('ab'), isNull);
    expect(charToTerminalKey('é'), isNull);
  });
}
