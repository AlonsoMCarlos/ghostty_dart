// Golden images of the renderer (ADR 0011: Linux only, bundled JetBrains
// Mono 2.304). Other operating systems rasterise text differently, so these
// tests skip there. Regenerate on Linux with
// `flutter test --update-goldens test/goldens`.
//
// flutter_tester has no system fonts: characters JetBrains Mono lacks (CJK,
// emoji) render as the test framework's fallback boxes. The goldens still
// pin their placement: centred in their cells, scaled down when wider.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../render/render_harness.dart';
import '../support/fonts.dart';

final _skip = !Platform.isLinux || skipWithoutBundledFonts;

/// Every SGR attribute and colour kind, one block per row band, plus text,
/// box drawing, wide characters and a long plain line: a 200 × 60 screen.
String _mixedScreen() {
  final b = StringBuffer();
  void line(String text) => b.write('$text\x1b[0m\r\n');
  line('\x1b[1mghostty_dart_flutter\x1b[0m mixed screen: 200 x 60');
  // 16 ANSI colours, foreground then background.
  line([for (var i = 0; i < 8; i++) '\x1b[3${i}m fg3$i '].join());
  line([for (var i = 0; i < 8; i++) '\x1b[9${i}m fg9$i '].join());
  line([for (var i = 0; i < 8; i++) '\x1b[4${i}m bg4$i '].join());
  line([for (var i = 0; i < 8; i++) '\x1b[10${i}m bg10$i '].join());
  // 256-colour cube and truecolor ramp.
  line([for (var i = 16; i < 232; i += 3) '\x1b[48;5;${i}m '].join());
  line(
    [for (var i = 0; i < 200; i += 2) '\x1b[48;2;$i;${200 - i};128m '].join(),
  );
  // Attributes.
  line(
    'plain \x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[1;3mbold italic\x1b[0m '
    '\x1b[2mfaint\x1b[0m \x1b[7minverse\x1b[0m \x1b[8minvisible\x1b[0m '
    '\x1b[9mstrike\x1b[0m \x1b[53moverline\x1b[0m \x1b[5mblink\x1b[0m',
  );
  line(
    '\x1b[4msingle\x1b[0m \x1b[4:2mdouble\x1b[0m \x1b[4:3mcurly\x1b[0m '
    '\x1b[4:4mdotted\x1b[0m \x1b[4:5mdashed\x1b[0m '
    '\x1b[4:3;58;2;255;64;64mred curly\x1b[0m '
    '\x1b[31;7minverse red\x1b[0m \x1b[44;2;37mfaint on blue',
  );
  // Box drawing and symbols (each placed in its own cell).
  line('┌──────────┬──────────┐  ▀▄█▌▐░▒▓  ←↑→↓  ✓✗  ⏎');
  line('│ box cell │ another  │  λ → Ω ж é ß');
  line('└──────────┴──────────┘');
  // Wide characters and a combining mark.
  line('wide: 漢字かなカナ한글 | é | ab中cd');
  for (var i = b.toString().split('\r\n').length; i < 59; i++) {
    final text =
        'line ${i.toString().padLeft(2)} '
        '${'The quick brown fox jumps over the lazy dog. ' * 5}';
    line(text.substring(0, 200));
  }
  b.write('\x1b[1;1H');
  return b.toString();
}

void main() {
  setUpAll(() async {
    if (!_skip) await requireJetBrainsMono();
  });

  testWidgets('200 x 60 mixed screen', (tester) async {
    await pumpRenderer(tester, cols: 200, rows: 60, initial: _mixedScreen());
    await expectLater(
      find.byKey(terminalKey),
      matchesGoldenFile('mixed_screen_200x60.png'),
    );
  }, skip: _skip);

  for (final dpr in [1.5, 2.0]) {
    testWidgets('underline styles, strikethrough and overline at dpr $dpr', (
      tester,
    ) async {
      await pumpRenderer(
        tester,
        cols: 24,
        rows: 8,
        devicePixelRatio: dpr,
        initial:
            '\x1b[4msingle underline\x1b[0m\r\n'
            '\x1b[4:2mdouble underline\x1b[0m\r\n'
            '\x1b[4:3mcurly underline\x1b[0m\r\n'
            '\x1b[4:4mdotted underline\x1b[0m\r\n'
            '\x1b[4:5mdashed underline\x1b[0m\r\n'
            '\x1b[4:3;58;5;196mcoloured curly\x1b[0m\r\n'
            '\x1b[9mstrikethrough\x1b[0m\r\n'
            '\x1b[53moverline\x1b[0m\x1b[?25l',
      );
      await expectLater(
        find.byKey(terminalKey),
        matchesGoldenFile(
          dpr == 2.0 ? 'decorations.png' : 'decorations_dpr$dpr.png',
        ),
      );
    }, skip: _skip);
  }

  testWidgets('wide characters and emoji', (tester) async {
    await pumpRenderer(
      tester,
      cols: 16,
      rows: 4,
      devicePixelRatio: 2,
      initial:
          '\x1b[?2027h'
          'a中b文c\r\n'
          '\x1b[42m漢字\x1b[0m|\x1b[7mかな\x1b[0m|\r\n'
          'x\u{1F600}y\u{1F469}‍\u{1F4BB}z\r\n'
          'é ✓ → ─\x1b[?25l',
    );
    await expectLater(
      find.byKey(terminalKey),
      matchesGoldenFile('wide_and_emoji.png'),
    );
  }, skip: _skip);

  for (final (name, sequence, focused) in [
    ('block', '\x1b[2 q', true),
    ('bar', '\x1b[6 q', true),
    ('underline', '\x1b[4 q', true),
    ('hollow_unfocused', '\x1b[2 q', false),
    ('block_on_wide', '\x1b[2 q\x1b[1;3H', true),
  ]) {
    testWidgets('cursor: $name', (tester) async {
      await pumpRenderer(
        tester,
        cols: 8,
        rows: 2,
        devicePixelRatio: 2,
        focused: focused,
        initial: 'ab中d\r\nxy$sequence',
      );
      await expectLater(
        find.byKey(terminalKey),
        matchesGoldenFile('cursor_$name.png'),
      );
    }, skip: _skip);
  }

  testWidgets('selection across wide characters', (tester) async {
    final h = await pumpRenderer(
      tester,
      cols: 16,
      rows: 3,
      devicePixelRatio: 2,
      initial: 'select 中文 text\r\n\x1b[41mred\x1b[0m line\r\nthird\x1b[?25l',
    );
    h.seams.selection = h.seams.terminal.selectRange(
      const GridPoint.viewport(4, 0),
      const GridPoint.viewport(5, 1),
    );
    await tester.pump();
    await expectLater(
      find.byKey(terminalKey),
      matchesGoldenFile('selection.png'),
    );
  }, skip: _skip);

  testWidgets('padding and background opacity', (tester) async {
    final h = await pumpRenderer(
      tester,
      cols: 10,
      rows: 2,
      padding: const EdgeInsets.all(6),
      initial: 'padded\x1b[?25l',
    );
    await h.rebuild(backgroundOpacity: 0.5);
    await expectLater(
      find.byKey(terminalKey),
      matchesGoldenFile('padding_opacity.png'),
    );
  }, skip: _skip);
}
