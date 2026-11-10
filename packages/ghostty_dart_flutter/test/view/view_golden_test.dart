// Goldens of the whole VtTerminalView (ADR 0011: Linux only, bundled
// JetBrains Mono 2.304), and the pub.dev screenshot `doc/screenshot.png`.
// The `golden` tag skips them off Linux (dart_test.yaml). Regenerate on
// Linux with `mise run test:goldens:update`.
@Tags(['golden'])
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

import '../support/fonts.dart';

const _style = TextStyle(fontFamily: jetBrainsMonoFamily, fontSize: 13);

/// The screenshot font: 13 x 30 px cells, a 96 x 22 grid in 1280 x 720.
const _screenshotStyle = TextStyle(
  fontFamily: jetBrainsMonoFamily,
  fontSize: 22,
);

/// SGR helpers for the demo screens.
String _fg(int r, int g, int b) => '\x1b[38;2;$r;$g;${b}m';
String _bg(int r, int g, int b) => '\x1b[48;2;$r;$g;${b}m';
const _reset = '\x1b[0m';

/// A 96-column screen that shows off colours, styles and box drawing: the
/// screenshot on pub.dev.
String _demoScreen() {
  final b = StringBuffer();
  void line([String text = '']) => b.write('$text$_reset\r\n');
  const prompt =
      '\x1b[1;32muser@ghostty\x1b[0m:\x1b[1;34m~/app\x1b[0m '
      '\x1b[35m(main)\x1b[0m \$ ';
  line(
    '\x1b[1;38;5;81m ghostty_dart_flutter \x1b[0;38;5;245m'
    'libghostty-vt rendering in a Flutter widget',
  );
  line();
  line('${prompt}ls --color');
  line(
    '\x1b[1;34mandroid\x1b[0m  \x1b[1;34mlib\x1b[0m  \x1b[1;34mtest\x1b[0m  '
    '\x1b[1;34mweb\x1b[0m  README.md  pubspec.yaml  '
    '\x1b[1;32mbuild.sh\x1b[0m  \x1b[1;31mrelease.tar.gz\x1b[0m',
  );
  line('${prompt}git log --oneline --graph -4');
  line(
    '\x1b[31m*\x1b[0m \x1b[33m5a7a3cd\x1b[0m '
    '\x1b[36m(\x1b[1;36mHEAD -> \x1b[1;32mmain\x1b[0;36m)\x1b[0m '
    'feat: dirty-row renderer',
  );
  line('\x1b[31m*\x1b[0m \x1b[33m582df5f\x1b[0m feat: keyboard, IME and mouse');
  line(
    '\x1b[31m|\x1b[32m\\\x1b[0m  \x1b[33m411819b\x1b[0m '
    'Merge branch \x1b[3m\'scrollback\'\x1b[0m',
  );
  line(
    '\x1b[31m|\x1b[0m \x1b[32m*\x1b[0m \x1b[33m510b7f7\x1b[0m '
    'test: \x1b[4mgoldens\x1b[0m on Linux',
  );
  line('${prompt}top');
  // Meters.
  String meter(String label, double used, (int, int, int) colour) {
    const width = 28;
    final filled = (used * width).round();
    final (r, g, bl) = colour;
    return '\x1b[1m$label\x1b[0m [${_fg(r, g, bl)}${'|' * filled}'
        '\x1b[38;5;238m${'|' * (width - filled)}$_reset] '
        '${(used * 100).toStringAsFixed(1).padLeft(5)}%';
  }

  line(
    '  ${meter('CPU', 0.62, (80, 220, 100))}  '
    '${meter('Mem', 0.37, (90, 160, 255))}',
  );
  // A table in box drawing, block elements and text styles beside it.
  const rule = '────────';
  const wide = '────────────────';
  line('  ┌$rule┬$wide┬$rule┐  ${_fg(255, 200, 80)}▁▂▃▄▅▆▇█▇▆▅▄▃▂▁');
  line(
    '  │ \x1b[1mPID\x1b[0m    │ \x1b[1mCOMMAND\x1b[0m        │ '
    '\x1b[1mCPU%\x1b[0m   │  ${_fg(120, 200, 255)}░░▒▒▓▓██▓▓▒▒░░',
  );
  line('  ├$rule┼$wide┼$rule┤');
  line(
    '  │   4242 │ ${_fg(255, 120, 120)}flutter_tester$_reset │   38.5 │  '
    '\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[9mstrike\x1b[0m',
  );
  line(
    '  │   1337 │ ${_fg(130, 230, 130)}zsh$_reset            │    0.4 │  '
    '\x1b[4:3;58;2;255;80;80mcurly\x1b[0m \x1b[4:2mdouble\x1b[0m '
    '\x1b[7minverse\x1b[0m',
  );
  line('  └$rule┴$wide┴$rule┘');
  // 256-colour ramp and a truecolor gradient.
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

Future<VtTerminalController> _pumpView(
  WidgetTester tester, {
  required Size logicalSize,
  required double dpr,
  required String screen,
  EdgeInsets padding = EdgeInsets.zero,
  bool focused = true,
  TextStyle style = _style,
}) async {
  tester.view
    ..devicePixelRatio = dpr
    ..physicalSize = logicalSize * dpr;
  addTearDown(tester.view.reset);
  final controller = VtTerminalController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: const ValueKey('view'),
        child: VtTerminalView(
          controller: controller,
          textStyle: style,
          padding: padding,
          autofocus: focused,
        ),
      ),
    ),
  );
  await tester.pump();
  controller.write(screen);
  await tester.pump();
  return controller;
}

void main() {
  setUpAll(() async {
    if (!skipWithoutBundledFonts) await requireJetBrainsMono();
  });

  testWidgets('the whole view: padding, selection and scrollbar', (
    tester,
  ) async {
    final controller = await _pumpView(
      tester,
      logicalSize: const Size(320, 160),
      dpr: 1,
      padding: const EdgeInsets.all(6),
      screen: [
        for (var i = 0; i < 20; i++) 'line \x1b[3${i % 8}m$i\x1b[0m of output',
      ].join('\r\n'),
    );
    // Scroll up three rows with the wheel (shows the scrollbar) and select
    // with the mouse.
    final pointer = TestPointer(1, PointerDeviceKind.mouse)
      ..hover(const Offset(100, 60));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -53)));
    // The scrollbar fades in (300 ms) and stays for 600 ms.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final drag = await tester.startGesture(
      const Offset(20, 30),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(const Offset(150, 50));
    await drag.up();
    await tester.pump();
    expect(controller.selectedText, isNotNull);
    await expectLater(
      find.byKey(const ValueKey('view')),
      matchesGoldenFile('goldens/view_scrolled_selection.png'),
    );
  }, skip: skipWithoutBundledFonts);

  testWidgets('screenshot for pub.dev (doc/screenshot.png)', (tester) async {
    await _pumpView(
      tester,
      logicalSize: const Size(1280, 720),
      dpr: 1,
      padding: const EdgeInsets.all(16),
      style: _screenshotStyle,
      screen: _demoScreen(),
    );
    await expectLater(
      find.byKey(const ValueKey('view')),
      matchesGoldenFile('../../doc/screenshot.png'),
    );
  }, skip: skipWithoutBundledFonts);
}
