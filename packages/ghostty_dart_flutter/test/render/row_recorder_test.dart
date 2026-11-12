// How rows are scanned into draw operations: style runs of grid-safe cells
// share one letter-spaced paragraph; wide characters, graphemes and symbols
// that may come from a fallback font get one paragraph each; colours,
// selection and decorations are resolved here. Runs on every OS (no
// pixels).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/render/paragraph_cache.dart';
import 'package:ghostty_dart_flutter/src/render/row_recorder.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';

import '../support/fonts.dart';
import 'render_harness.dart';

const _fg = '#ffcccccc'; // default theme foreground
const _bg = '#ff1e1e1e'; // default theme background
const _red = '#ffcd3131'; // default theme ANSI red
const _selection = Color(0x80FFFFFF);

RowRecorder _recorder() => RowRecorder(
  metrics: VtCellMetrics.measure(gridStyle, devicePixelRatio: 1),
  textStyle: gridStyle,
  paragraphs: ParagraphCache(),
);

/// The operations of row 0 of a 20 × 2 terminal showing [data].
List<String> _ops(String data, {void Function(ControllerSeams)? before}) {
  final controller = VtTerminalController(cols: 20, rows: 2);
  addTearDown(controller.dispose);
  controller.write(data);
  final seams = ControllerSeams(controller);
  before?.call(seams);
  final recorder = _recorder();
  final state = seams.updateFrame();
  for (final row in state.allRows) {
    if (row.viewportY == 0) recorder.scan(row, state.colors, _selection);
  }
  seams.endFrame();
  return recorder.takeScan().debugDescribe();
}

void main() {
  setUpAll(loadJetBrainsMono);

  group('runs', () {
    test('one style run is one paragraph, inner spaces included', () {
      expect(_ops('hello world'), ['run 0 "hello world" $_fg f0']);
    });

    test('leading and trailing blanks are not drawn', () {
      expect(_ops('   x  \x1b[41m   '), ['bg 6+3 $_red', 'run 3 "x" $_fg f0']);
    });

    test('a style change starts a new run', () {
      expect(_ops('a\x1b[1mb\x1b[3mc'), [
        'run 0 "a" $_fg f0',
        'run 1 "b" $_fg f1',
        'run 2 "c" $_fg f3',
      ]);
    });

    test('Latin, Greek and Cyrillic stay in the run', () {
      expect(_ops('é ß Ω ж'), ['run 0 "é ß Ω ж" $_fg f0']);
    });

    test('a soft hyphen is its own cell, so the run after it stays put', () {
      // libghostty-vt gives U+00AD a cell; text layout gives it no advance.
      expect(_ops('a­bc'), [
        'run 0 "a" $_fg f0',
        'cluster 1 "­" $_fg f4 span 1',
        'run 2 "bc" $_fg f0',
      ]);
    });

    test('wide characters are placed on their own', () {
      expect(_ops('ab中cd'), [
        'run 0 "ab" $_fg f0',
        'cluster 2 "中" $_fg f4 span 2',
        'run 4 "cd" $_fg f0',
      ]);
    });

    test('symbols that may need a fallback font are placed on their own', () {
      expect(_ops('a→b─c'), [
        'run 0 "a" $_fg f0',
        'cluster 1 "→" $_fg f4 span 1',
        'run 2 "b" $_fg f0',
        'cluster 3 "─" $_fg f4 span 1',
        'run 4 "c" $_fg f0',
      ]);
    });

    test('grapheme clusters are one paragraph', () {
      // e + combining acute accent: one narrow cell with two codepoints.
      expect(_ops('xéy'), [
        'run 0 "x" $_fg f0',
        'cluster 1 "é" $_fg f4 span 1',
        'run 2 "y" $_fg f0',
      ]);
      // With grapheme clustering (mode 2027) a ZWJ emoji sequence is one
      // wide cell: woman technologist, U+1F469 ZWJ U+1F4BB.
      expect(_ops('\x1b[?2027hx\u{1F469}‍\u{1F4BB}y'), [
        'run 0 "x" $_fg f0',
        'cluster 1 "\u{1F469}‍\u{1F4BB}" $_fg f4 span 2',
        'run 3 "y" $_fg f0',
      ]);
    });

    test('isGridSafe excludes format and combining characters', () {
      expect(RowRecorder.isGridSafe(0x41), isTrue);
      expect(RowRecorder.isGridSafe(0xE9), isTrue);
      expect(RowRecorder.isGridSafe(0xAD), isFalse);
      expect(RowRecorder.isGridSafe(0x483), isFalse);
      expect(RowRecorder.isGridSafe(0x416), isTrue);
      expect(RowRecorder.isGridSafe(0x2500), isFalse);
    });
  });

  group('colours', () {
    test('invisible text keeps its background only', () {
      expect(_ops('\x1b[41;8msecret'), ['bg 0+6 $_red']);
    });

    test('faint text is drawn at half alpha', () {
      expect(_ops('\x1b[2mdim'), ['run 0 "dim" #80cccccc f0']);
    });

    test('inverse swaps the resolved default colours', () {
      expect(_ops('\x1b[7minv'), ['bg 0+3 $_fg', 'run 0 "inv" $_bg f0']);
    });

    test('inverse swaps explicit colours', () {
      expect(_ops('\x1b[31;44;7mx'), [
        'bg 0+1 $_red',
        'run 0 "x" #ff2472c8 f0',
      ]);
    });

    test('palette and truecolor backgrounds merge equal neighbours', () {
      expect(_ops('\x1b[41mab\x1b[48;2;1;2;3mcd\x1b[41me'), [
        'bg 0+2 $_red',
        'bg 2+2 #ff010203',
        'bg 4+1 $_red',
        'run 0 "ab" $_fg f0',
        'run 2 "cd" $_fg f0',
        'run 4 "e" $_fg f0',
      ]);
    });

    test('erased cells keep their own background inside a style run', () {
      // EL with a red pen leaves text-less cells that carry the colour
      // themselves; the text after them has the default style again.
      expect(_ops('ab\x1b[41m\x1b[K\x1b[0m\x1b[5Gcd\x1b[7mi'), [
        'bg 2+2 $_red',
        'bg 6+1 $_fg',
        'bg 7+13 $_red',
        'run 0 "ab  cd" $_fg f0',
        'run 6 "i" $_bg f0',
      ]);
    });

    test('the underline colour defaults to the text colour', () {
      expect(_ops('\x1b[4;31mu'), [
        'run 0 "u" $_red f0',
        'deco 0-1 underline:single $_red $_red',
      ]);
    });

    test('an explicit underline colour (SGR 58) is used, faint applies', () {
      expect(_ops('\x1b[4:3;2;58;2;0;255;0mu'), [
        'run 0 "u" #80cccccc f0',
        'deco 0-1 underline:curly #8000ff00 #80cccccc',
      ]);
    });

    test('strikethrough and overline use the text colour', () {
      expect(_ops('\x1b[9;53mso'), [
        'run 0 "so" $_fg f0',
        'deco 0-2 strike overline $_fg $_fg',
      ]);
    });

    test('the selection uses the given colour over the backgrounds', () {
      expect(
        _ops(
          '\x1b[41mone\x1b[0m two',
          before: (seams) => seams.selection = seams.terminal.selectRange(
            const GridPoint.viewport(1, 0),
            const GridPoint.viewport(5, 0),
          ),
        ),
        [
          'bg 0+3 $_red',
          'sel 1+5 #80ffffff',
          'run 0 "one" $_fg f0',
          'run 4 "two" $_fg f0',
        ],
      );
    });
  });

  group('content keys', () {
    test('equal rows match; any visible change does not', () {
      final controller = VtTerminalController(cols: 10, rows: 3);
      addTearDown(controller.dispose);
      controller.write('same\r\nsame\r\nsamE');
      final seams = ControllerSeams(controller);
      final recorder = _recorder();
      final state = seams.updateFrame();
      final contents = <RowContent>[];
      for (final row in state.allRows) {
        recorder.scan(row, state.colors, _selection);
        contents.add(recorder.takeScan());
      }
      seams.endFrame();
      final state2 = seams.updateFrame();
      for (final row in state2.allRows) {
        if (row.viewportY == 1) {
          recorder.scan(row, state2.colors, _selection);
          expect(recorder.scanMatches(contents[0]), isTrue);
          expect(recorder.scanMatches(contents[2]), isFalse);
          recorder.scan(row, state2.colors, const Color(0xFF00FF00));
          expect(recorder.scanMatches(contents[0]), isTrue);
          // The same rule as a map key (the renderer's picture cache).
          final copy = recorder.takeScan();
          expect(copy, contents[0]);
          expect(copy.hashCode, contents[0].hashCode);
          expect(copy, isNot(contents[2]));
        }
      }
      seams.endFrame();
    });
  });

  group('row paragraph', () {
    /// Records row 0 of a 20 × 1 terminal showing [data] with [recorder].
    void record(RowRecorder recorder, String data) {
      final controller = VtTerminalController(cols: 20, rows: 1);
      addTearDown(controller.dispose);
      controller.write(data);
      final seams = ControllerSeams(controller);
      final state = seams.updateFrame();
      recorder.scan(state.allRows.first, state.colors, _selection);
      seams.endFrame();
      recorder.record(recorder.takeScan()).dispose();
    }

    test('a row of several runs is laid out as one paragraph', () {
      final recorder = _recorder();
      addTearDown(recorder.paragraphs.clear);
      record(recorder, 'ab \x1b[1mcd\x1b[0;31m ef  \x1b[3mgh');
      expect(recorder.debugRowParagraphs, 1);
      expect(recorder.debugRowParagraphFallbacks, 0);
      // No run went through the run cache.
      expect(recorder.paragraphs.misses, 0);
    });

    test('a single run uses the run cache', () {
      final recorder = _recorder();
      addTearDown(recorder.paragraphs.clear);
      record(recorder, 'hello world');
      expect(recorder.debugRowParagraphs, 0);
      expect(recorder.paragraphs.misses, 1);
    });

    testWidgets('runs shifted by faces whose errors cancel out fall back', (
      tester,
    ) async {
      // JetBrains Mono's faces all advance 600 units, so a family whose
      // bold face is Roboto Bold (proportional, from the pinned Flutter
      // SDK) provides the wider and narrower glyphs: one bold run of
      // wide letters, one of narrow letters, sized so the row's total
      // width is within tolerance while every run between them is off.
      final root = Platform.environment['FLUTTER_ROOT'];
      final roboto = File(
        '$root/bin/cache/artifacts/material_fonts/Roboto-Bold.ttf',
      );
      final jbm = File('test/fonts/JetBrainsMono-Regular.ttf');
      if (root == null || !roboto.existsSync() || !jbm.existsSync()) {
        fail('Roboto Bold or JetBrains Mono is missing');
      }
      const family = 'T6 Mixed';
      await tester.runAsync(() async {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(jbm.readAsBytesSync())))
          ..addFont(
            Future.value(ByteData.sublistView(roboto.readAsBytesSync())),
          );
        await loader.load();
      });
      final style = gridStyle.copyWith(fontFamily: family);
      final metrics = VtCellMetrics.measure(style, devicePixelRatio: 1);
      double error(String char) {
        final paragraph =
            (ui.ParagraphBuilder(
                    ui.ParagraphStyle(textDirection: TextDirection.ltr),
                  )
                  ..pushStyle(
                    style
                        .copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: metrics.letterSpacing,
                        )
                        .getTextStyle(),
                  )
                  ..addText(char))
                .build()
              ..layout(const ui.ParagraphConstraints(width: 1e6));
        final width = paragraph.maxIntrinsicWidth;
        paragraph.dispose();
        return width - metrics.width;
      }

      // Find n1 × c1 (wider) and n2 × c2 (narrower) that cancel.
      const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
      final errors = {for (final c in letters.split('')) c: error(c)};
      (String, int, String, int)? pick;
      search:
      for (final MapEntry(key: wide, value: up) in errors.entries) {
        if (up < 1) continue;
        for (final MapEntry(key: narrow, value: down) in errors.entries) {
          if (down > -1) continue;
          for (var n1 = 1; n1 <= 6; n1++) {
            for (var n2 = 1; n2 <= 6; n2++) {
              if ((n1 * up + n2 * down).abs() < 0.2) {
                pick = (wide, n1, narrow, n2);
                break search;
              }
            }
          }
        }
      }
      expect(pick, isNotNull, reason: 'no cancelling pair in $errors');
      final (wide, n1, narrow, n2) = pick!;
      final recorder = RowRecorder(
        metrics: metrics,
        textStyle: style,
        paragraphs: ParagraphCache(),
      );
      addTearDown(recorder.paragraphs.clear);
      record(
        recorder,
        'a\x1b[1m${wide * n1}\x1b[0mb\x1b[1m${narrow * n2}\x1b[0mc',
      );
      expect(recorder.debugRowParagraphs, 0);
      expect(recorder.debugRowParagraphFallbacks, 1);
    }, skip: skipWithoutBundledFonts);

    test('an off-grid row falls back to its runs', () {
      // Cells measured with JetBrains Mono, text drawn in FlutterTest
      // (one em per glyph): the row paragraph is too wide.
      final recorder = RowRecorder(
        metrics: VtCellMetrics.measure(gridStyle, devicePixelRatio: 1),
        textStyle: gridStyle.copyWith(fontFamily: 'FlutterTest'),
        paragraphs: ParagraphCache(),
      );
      addTearDown(recorder.paragraphs.clear);
      record(recorder, 'ab \x1b[1mcd');
      expect(recorder.debugRowParagraphs, 0);
      expect(recorder.debugRowParagraphFallbacks, 1);
      expect(recorder.paragraphs.misses, greaterThan(0));
    }, skip: skipWithoutBundledFonts);
  });

  test('readCell copies the cell under the cursor', () {
    final controller = VtTerminalController(cols: 10, rows: 1);
    addTearDown(controller.dispose);
    controller.write('a\x1b[7m中');
    final seams = ControllerSeams(controller);
    final recorder = _recorder();
    final state = seams.updateFrame();
    final row = state.allRows.first;
    final plain = recorder.readCell(row, 0, state.colors);
    expect(plain.text, 'a');
    expect(plain.span, 1);
    expect(plain.faces, 0);
    expect(plain.background, colorOfRgb(state.colors.background));
    final wide = recorder.readCell(row, 1, state.colors);
    expect(wide.text, '中');
    expect(wide.span, 2);
    expect(wide.faces, TextFace.cluster);
    // Inverse: the cell's background is the foreground colour.
    expect(wide.background, colorOfRgb(state.colors.foreground));
    seams.endFrame();
  });
}
