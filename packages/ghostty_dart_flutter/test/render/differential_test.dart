// Differential test of the renderer's caches: after every step the
// long-lived renderer (cached row pictures, content keys, paragraphs) must
// paint exactly the pixels a cold renderer paints from the same terminal
// state. Counting recordings proves work is skipped; this proves the
// result is still right.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/render/row_recorder.dart';

import '../support/fonts.dart';
import 'render_harness.dart';

/// Checks that the current pixels equal those after dropping every cache.
/// A held frame is not read, so a cold renderer has nothing to show
/// then: the comparison runs after the hold ends.
Future<void> _expectSameAsCold(RenderHarness h, String step) async {
  if (h.seams.isRenderHeld) return;
  final warm = await h.pixels();
  h.render.debugDropCaches();
  await h.tester.pump();
  final cold = await h.pixels();
  expect(warm.length, cold.length, reason: step);
  var differing = 0;
  for (var i = 0; i < warm.length; i++) {
    if (warm[i] != cold[i]) differing++;
  }
  expect(differing, 0, reason: '$step: $differing bytes differ');
}

/// Deterministic random output: text, SGR, cursor moves, erases, newlines.
String _randomOutput(math.Random random, int length) {
  const pieces = [
    'hello ',
    'wörld ',
    '中文',
    'x́',
    '─┼─',
    '\x1b[1m',
    '\x1b[3m',
    '\x1b[4:3m',
    '\x1b[7m',
    '\x1b[2m',
    '\x1b[9m',
    '\x1b[0m',
    '\x1b[31m',
    '\x1b[44m',
    '\x1b[38;5;208m',
    '\x1b[48;2;10;80;30m',
    '\r\n',
    '\r\n',
    '\x1b[K',
    '\x1b[2;5H',
    '\x1b[A',
    '\x1b[3C',
    '\t',
    '\x1b[1;1H\x1b[L',
  ];
  final b = StringBuffer();
  for (var i = 0; i < length; i++) {
    b.write(pieces[random.nextInt(pieces.length)]);
  }
  return b.toString();
}

/// One row of words in random faces and colours, with gaps, a wide
/// character and decorations now and then.
String _mixedRow(math.Random random) {
  const sgrs = ['0', '1', '3', '1;3', '31', '1;32', '3;94', '4', '9', '7'];
  final b = StringBuffer();
  var cols = 0;
  while (cols < 34) {
    final word = String.fromCharCodes([
      for (var i = 0; i < 1 + random.nextInt(5); i++) 0x41 + random.nextInt(58),
    ]).replaceAll(RegExp(r'[\[\\\]^_`]'), 'x');
    b.write('\x1b[${sgrs[random.nextInt(sgrs.length)]}m$word\x1b[0m');
    cols += word.length;
    if (random.nextInt(6) == 0) {
      b.write('中');
      cols += 2;
    }
    final gap = 1 + random.nextInt(2);
    b.write(' ' * gap);
    cols += gap;
  }
  return b.toString();
}

void main() {
  setUpAll(loadJetBrainsMono);

  testWidgets('a full picture cache evicts only what is off screen', (
    tester,
  ) async {
    // A budget of about 40 short rows, then 100 frames of 5 new rows: the
    // cache stays within its budget and the screen still paints what a
    // cold renderer paints.
    const budget = 160 << 10;
    const pictureBudget = budget - budget ~/ 4;
    final h = await pumpRenderer(
      tester,
      cols: 20,
      rows: 5,
      cacheBudget: budget,
    );
    for (var frame = 0; frame < 100; frame++) {
      await h.write(
        [
          for (var row = 0; row < 5; row++)
            '\x1b[${row + 1};1H\x1b[3${row % 8}mframe $frame\x1b[1m row $row',
        ].join(),
      );
      expect(h.render.debugPictureBytes, lessThanOrEqualTo(pictureBudget));
    }
    expect(h.render.debugCachedPictures, lessThan(100 * 5));
    expect(h.render.debugCachedPictures, greaterThan(5));
    await _expectSameAsCold(h, 'after eviction');
  });

  testWidgets('row paragraphs paint what per-run paragraphs paint', (
    tester,
  ) async {
    // The same screens through both text paths: one paragraph per row
    // (the default), and every run on its own (the fallback). Mixed faces,
    // colours, gaps, clusters and decorations.
    addTearDown(() => RowRecorder.debugForcePerRun = false);
    final h = await pumpRenderer(
      tester,
      cols: 40,
      rows: 8,
      devicePixelRatio: 2,
      initial: '\x1b[2 q',
    );
    final random = math.Random(7);
    for (var step = 0; step < 8; step++) {
      await h.write(
        '\x1b[H\x1b[2J'
        '${List.generate(8, (row) => '\x1b[${row + 1};1H'
            '${_mixedRow(random)}').join()}',
      );
      RowRecorder.debugForcePerRun = false;
      h.render.debugDropCaches();
      await tester.pump();
      final rowPath = await h.pixels();
      final rowParagraphs = h.render.debugRowParagraphs;
      RowRecorder.debugForcePerRun = true;
      h.render.debugDropCaches();
      await tester.pump();
      final runPath = await h.pixels();
      expect(rowParagraphs, greaterThan(0), reason: 'step $step');
      var differing = 0;
      for (var i = 0; i < rowPath.length; i++) {
        if (rowPath[i] != runPath[i]) differing++;
      }
      expect(differing, 0, reason: 'step $step: $differing bytes differ');
    }
  });

  testWidgets('warm caches paint what a cold renderer paints', (tester) async {
    final h = await pumpRenderer(
      tester,
      cols: 24,
      rows: 8,
      devicePixelRatio: 1.5,
      initial:
          '\x1b[2 q' // steady cursor: the blink phase cannot differ
          '${List.generate(20, (i) => '\x1b[3${i % 8}mline $i\x1b[0m').join('\r\n')}',
    );
    await _expectSameAsCold(h, 'initial');

    final steps = <String, Future<void> Function()>{
      'newline scroll': () => h.write('\r\nnew line'),
      'viewport scroll up': () async {
        h.controller.scrollViewport(const ViewportScroll.delta(-3));
        await tester.pump();
      },
      'viewport scroll down': () async {
        h.controller.scrollViewport(const ViewportScroll.delta(2));
        await tester.pump();
      },
      'scroll to bottom': () async {
        h.controller.scrollViewport(const ViewportScroll.bottom());
        await tester.pump();
      },
      'ED 2': () => h.write('\x1b[2J\x1b[Hafter clear'),
      'resize narrower': () => h.resize(16, 8),
      'resize taller and wider': () => h.resize(30, 10),
      'alternate screen on': () => h.write('\x1b[?1049h\x1b[42malt screen'),
      'alternate screen off': () => h.write('\x1b[?1049l'),
      'render hold start': () =>
          h.write('\x1b[?2026h\x1b[5;1Hheld text\x1b[31m red'),
      'render hold end': () => h.write('\x1b[?2026l'),
      'palette (OSC 4)': () => h.write('\x1b]4;1;rgb:00/ff/80\x07'),
      'default foreground (OSC 10)': () => h.write('\x1b]10;rgb:ff/ff/00\x07'),
      'default background (OSC 11)': () => h.write('\x1b]11;rgb:20/00/40\x07'),
      'cursor colour (OSC 12)': () => h.write('\x1b]12;rgb:00/ff/00\x07'),
      'reverse video': () => h.write('\x1b[?5h'),
      'reverse video off': () => h.write('\x1b[?5l'),
      'selection': () async {
        h.seams.selection = h.seams.terminal.selectRange(
          const GridPoint.viewport(2, 1),
          const GridPoint.viewport(6, 3),
        );
        await tester.pump();
      },
      'selection moved': () async {
        h.seams.selection = h.seams.terminal.selectRange(
          const GridPoint.viewport(0, 2),
          const GridPoint.viewport(3, 2),
        );
        await tester.pump();
      },
      'theme': () async {
        h.controller.theme = VtTerminalTheme.whiteOnBlack;
        await tester.pump();
      },
    };
    for (final MapEntry(key: step, value: run) in steps.entries) {
      await run();
      await _expectSameAsCold(h, step);
    }

    final random = math.Random(2026);
    for (var i = 0; i < 12; i++) {
      await h.write(_randomOutput(random, 40));
      if (i.isEven) {
        h.controller.scrollViewport(
          ViewportScroll.delta(random.nextInt(5) - 3),
        );
        await tester.pump();
      }
      await _expectSameAsCold(h, 'random step $i');
    }
  });
}
