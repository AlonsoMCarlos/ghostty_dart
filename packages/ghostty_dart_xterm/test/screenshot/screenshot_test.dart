// The pub.dev screenshot `doc/screenshot.png` (pubspec `screenshots`): a
// real TerminalView of this package, drawn by ghostty_dart_flutter's
// renderer with the bundled, pinned JetBrains Mono. Linux only, like every
// golden (ADR 0011; the `golden` tag, dart_test.yaml). Regenerate on Linux
// with `mise run test:goldens:update` and review the image.
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

import 'fonts.dart';

/// A 96 x 22 grid in 1280 x 720 with the padding, as in
/// ghostty_dart_flutter's screenshot. `height: 1` keeps the font's own line
/// height; xterm's default (1.2) leaves gaps between box-drawing rows.
const _style = TerminalStyle(
  fontFamily: jetBrainsMonoFamily,
  fontSize: 22,
  height: 1,
  fontFamilyFallback: [],
);

const _reset = '\x1b[0m';
String _fg(int r, int g, int b) => '\x1b[38;2;$r;$g;${b}m';
String _bg(int r, int g, int b) => '\x1b[48;2;$r;$g;${b}m';

/// A shell session in an app migrated from xterm: the changed import, the
/// unchanged xterm code, and colours, styles and box drawing.
String _demoScreen() {
  final b = StringBuffer();
  void line([String text = '']) => b.write('$text$_reset\r\n');
  const prompt =
      '\x1b[1;32muser@ghostty\x1b[0m:\x1b[1;34m~/my_app\x1b[0m '
      '\x1b[35m(main)\x1b[0m \$ ';
  line(
    '\x1b[1;38;5;81m ghostty_dart_xterm \x1b[0;38;5;245m'
    "package:xterm 4.0.0's API on libghostty-vt",
  );
  line();
  line('${prompt}git diff --stat && git diff lib/main.dart | tail -4');
  line(
    ' lib/main.dart | 2 \x1b[32m+\x1b[31m-\x1b[0m   '
    ' pubspec.yaml | 2 \x1b[32m+\x1b[31m-\x1b[0m',
  );
  const kw = '\x1b[38;5;176m';
  const str = '\x1b[38;5;114m';
  const type = '\x1b[38;5;222m';
  line("\x1b[31m-import $str'package:xterm/xterm.dart'$_reset;");
  line("\x1b[32m+import $str'package:ghostty_dart_xterm/xterm.dart'$_reset;");
  line(
    ' ${kw}final$_reset terminal = ${type}Terminal$_reset(maxLines: '
    '\x1b[38;5;209m10000$_reset);',
  );
  line(
    '  ${type}TerminalView$_reset(terminal, theme: '
    '${type}TerminalThemes$_reset.defaultTheme)',
  );
  line('${prompt}flutter test');
  line(
    // This package's own run on 2026-11-12 (`mise run test:xterm`).
    '00:07 \x1b[32m+238\x1b[0m \x1b[33m~7\x1b[0m: All tests passed!  '
    '\x1b[38;5;245m(test/compat: xterm 4.0.0\'s own tests)$_reset',
  );
  line('${prompt}htop');
  String meter(String label, double used, (int, int, int) colour) {
    const width = 28;
    final filled = (used * width).round();
    final (r, g, bl) = colour;
    return '\x1b[1m$label\x1b[0m [${_fg(r, g, bl)}${'|' * filled}'
        '\x1b[38;5;238m${'|' * (width - filled)}$_reset] '
        '${(used * 100).toStringAsFixed(1).padLeft(5)}%';
  }

  line(
    '  ${meter('CPU', 0.48, (80, 220, 100))}  '
    '${meter('Mem', 0.29, (90, 160, 255))}',
  );
  const rule = '────────';
  const wide = '────────────────';
  line('  ┌$rule┬$wide┬$rule┐  ${_fg(255, 200, 80)}▁▂▃▄▅▆▇█▇▆▅▄▃▂▁');
  line(
    '  │ \x1b[1mPID\x1b[0m    │ \x1b[1mCOMMAND\x1b[0m        │ '
    '\x1b[1mCPU%\x1b[0m   │  ${_fg(120, 200, 255)}░░▒▒▓▓██▓▓▒▒░░',
  );
  line('  ├$rule┼$wide┼$rule┤');
  line(
    '  │   2718 │ ${_fg(255, 120, 120)}my_app$_reset         │   21.7 │  '
    '\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[9mstrike\x1b[0m',
  );
  line(
    '  │   1337 │ ${_fg(130, 230, 130)}zsh$_reset            │    0.4 │  '
    '\x1b[4munderline\x1b[0m \x1b[7minverse\x1b[0m',
  );
  line('  └$rule┴$wide┴$rule┘');
  final ramp = [for (var i = 16; i < 256; i += 3) '\x1b[48;5;${i}m '].join();
  line('  $ramp');
  final gradient = StringBuffer('  ');
  for (var i = 0; i < 92; i++) {
    final red = (255 * i / 91).round();
    gradient.write('${_bg(red, 90, 255 - red)} ');
  }
  line(gradient.toString());
  b.write(prompt);
  return b.toString();
}

void main() {
  setUpAll(() async {
    if (!skipWithoutBundledFonts) await requireJetBrainsMono();
  });

  testWidgets('screenshot for pub.dev (doc/screenshot.png)', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    final terminal = Terminal();
    addTearDown(terminal.dispose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: const ValueKey('view'),
          child: TerminalView(
            terminal,
            textStyle: _style,
            padding: const EdgeInsets.all(16),
            autofocus: true,
          ),
        ),
      ),
    );
    await tester.pump();
    terminal.write(_demoScreen());
    await tester.pump();
    await expectLater(
      find.byKey(const ValueKey('view')),
      matchesGoldenFile('../../doc/screenshot.png'),
    );
  }, skip: skipWithoutBundledFonts);
}
