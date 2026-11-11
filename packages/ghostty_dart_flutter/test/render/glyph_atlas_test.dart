// The glyph atlas (ADR 0012): slot keys, pages, flushes, the accounting
// of page images that cached pictures pin, the renderer's budget and
// invalidation, fallback selection, and pixels against the paragraph
// path.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/render/glyph_atlas.dart';
import 'package:ghostty_dart_flutter/src/render/row_recorder.dart';
import 'package:ghostty_dart_flutter/src/render/terminal_render.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_geometry.dart';

import '../support/fonts.dart';
import 'render_harness.dart';

const _white = 0xFFFFFFFF;

/// An atlas for [gridStyle] at [dpr] whose pages hold [slotsPerPage]
/// slots (one page row), counted in [ledger].
GlyphAtlas _atlas(
  AtlasLedger ledger, {
  double dpr = 1,
  int slotsPerPage = 4,
  TextStyle style = gridStyle,
}) {
  final metrics = VtCellMetrics.measure(gridStyle, devicePixelRatio: dpr);
  final probe = GlyphAtlas(
    metrics: metrics,
    styleOf: (_, _) => ui.TextStyle(),
    ledger: ledger,
  );
  final atlas = GlyphAtlas(
    metrics: metrics,
    styleOf: (color, faces) => TextStyle(
      color: Color(color),
      fontFamily: style.fontFamily,
      fontSize: style.fontSize,
      fontWeight: faces & 1 != 0 ? FontWeight.bold : null,
      fontStyle: faces & 2 != 0 ? FontStyle.italic : null,
      letterSpacing: metrics.letterSpacing,
    ).getTextStyle(),
    ledger: ledger,
    maxPageWidth: probe.slotWidth * slotsPerPage,
    maxPageHeight: probe.slotHeight,
  );
  probe.dispose();
  addTearDown(atlas.dispose);
  return atlas;
}

/// One row of words in random faces and colours, with gaps, a wide
/// character and decorations now and then.
String _mixedRow(math.Random random) {
  const sgrs = [
    '0',
    '1',
    '3',
    '1;3',
    '31',
    '1;32',
    '3;94',
    '4',
    '9',
    '7',
    '2',
    '38;2;255;121;198',
  ];
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

  group('keys', () {
    test('fit 22 bits and are distinct', () {
      expect(GlyphAtlas.keyOf(0xFFFF, 3, 15), lessThan(1 << 22));
      final keys = <int>{
        for (var bucket = 0; bucket < GlyphAtlas.lumaBuckets; bucket++)
          for (var faces = 0; faces < 4; faces++)
            for (final unit in const [0x21, 0x7E, 0xE9, 0x416, 0xFFFF])
              GlyphAtlas.keyOf(unit, faces, bucket),
      };
      expect(keys, hasLength(16 * 4 * 5));
      // No bit above 2^22, so dart2js (53-bit doubles, 32-bit bitwise
      // operators) computes the same keys.
      expect(keys.every((k) => k >= 0 && k < 1 << 22), isTrue);
    });

    test('luminance buckets ignore alpha and span 0 to 15', () {
      expect(GlyphAtlas.lumaBucket(0xFF000000), 0);
      expect(GlyphAtlas.lumaBucket(_white), 15);
      expect(
        GlyphAtlas.lumaBucket(0x80CCCCCC),
        GlyphAtlas.lumaBucket(0xFFCCCCCC),
      );
      expect(GlyphAtlas.rasterColor(0), 0xFF000000);
      expect(GlyphAtlas.rasterColor(15), _white);
      // Colours of equal luminance share a slot.
      expect(
        GlyphAtlas.lumaBucket(0xFFFF0000),
        GlyphAtlas.lumaBucket(0xFFFF0101),
      );
    });
  });

  group('pages', () {
    testWidgets('slots fill pages in order; a flush draws each page once', (
      tester,
    ) async {
      final ledger = AtlasLedger();
      final atlas = _atlas(ledger);
      expect(atlas.slotsPerPage, 4);
      final slots = [
        for (final unit in 'abcdefghij'.codeUnits)
          atlas.slotOf(unit, 0, _white),
      ];
      expect(slots, List.generate(10, (i) => i));
      expect(atlas.isRasterised(0), isFalse);
      expect(atlas.slotOf(0x61, 0, _white), 0, reason: 'known glyph');
      expect(atlas.flush(), isTrue);
      expect(atlas.flush(), isFalse, reason: 'nothing queued');
      expect(atlas.pageCount, 3);
      expect(atlas.debugImages, 3);
      expect(atlas.isRasterised(9), isTrue);
      expect(
        [for (final s in slots) atlas.pageOf(s)],
        [
          0, 0, 0, 0, 1, 1, 1, 1, 2, 2, //
        ],
      );
      expect(ledger.images, 3);
      expect(ledger.bytes, 3 * atlas.pageBytes);
      expect(atlas.liveBytes, 3 * atlas.pageBytes);
    });

    testWidgets('new glyphs re-draw only the open page', (tester) async {
      final ledger = AtlasLedger();
      final atlas = _atlas(ledger);
      for (final unit in 'abcdef'.codeUnits) {
        atlas.slotOf(unit, 0, _white);
      }
      atlas.flush();
      final page0 = atlas.page(0);
      final page1 = atlas.page(1);
      atlas
        ..slotOf(0x67, 0, _white)
        ..flush();
      expect(atlas.page(0), same(page0), reason: 'a full page never changes');
      expect(atlas.page(1), isNot(same(page1)));
      // Nothing drew the old image of page 1: it was freed at once.
      expect(page1.isFreed, isTrue);
      expect(ledger.images, 2);
    });

    testWidgets('a cached picture pins a superseded page image', (
      tester,
    ) async {
      final ledger = AtlasLedger();
      final atlas = _atlas(ledger);
      atlas
        ..slotOf(0x61, 0, _white)
        ..flush();
      final old = atlas.page(0)..retain();
      atlas
        ..slotOf(0x62, 0, _white)
        ..flush();
      expect(old.isRetired, isTrue);
      expect(old.isFreed, isFalse);
      expect(ledger.images, 2);
      expect(ledger.bytes, 2 * atlas.pageBytes);
      old.release();
      expect(old.isFreed, isTrue);
      expect(ledger.bytes, atlas.pageBytes);
    });

    testWidgets('dispose frees unused pages and keeps pinned ones counted', (
      tester,
    ) async {
      final ledger = AtlasLedger();
      final atlas = _atlas(ledger);
      for (final unit in 'abcde'.codeUnits) {
        atlas.slotOf(unit, 0, _white);
      }
      atlas.flush();
      final pinned = atlas.page(1)..retain();
      atlas
        ..slotOf(0x7A, 0, _white) // queued, never drawn
        ..dispose();
      expect(ledger.images, 1);
      pinned.release();
      expect(ledger.images, 0);
      expect(ledger.bytes, 0);
    });

    testWidgets('prefill queues printable ASCII once per bucket', (
      tester,
    ) async {
      final atlas = _atlas(AtlasLedger(), slotsPerPage: 200);
      atlas.prefill(0xFFCCCCCC);
      expect(atlas.slotCount, 94);
      atlas.prefill(0xFFCDCDCD); // same bucket
      expect(atlas.slotCount, 94);
      atlas.prefill(0xFF000000);
      expect(atlas.slotCount, 188);
      atlas.flush();
      expect(atlas.pageCount, 1);
    });

    testWidgets('faces and buckets get their own slots', (tester) async {
      final atlas = _atlas(AtlasLedger(), slotsPerPage: 64);
      final slots = {
        for (var faces = 0; faces < 4; faces++)
          for (final color in const [0xFF000000, _white, 0xFFCD3131])
            atlas.slotOf(0x41, faces, color),
      };
      expect(slots, hasLength(12));
      expect(atlas.slotOf(0x41, 1, 0xFFCD3131), isIn(slots));
    });

    testWidgets('a glyph that does not advance one cell is a fallback', (
      tester,
    ) async {
      // Rasterised at 20 px for 13 px cells: no glyph fits the grid.
      final atlas = _atlas(
        AtlasLedger(),
        style: gridStyle.copyWith(fontSize: 20),
      );
      expect(atlas.slotOf(0x41, 0, _white), -1);
      expect(atlas.slotOf(0x41, 0, _white), -1, reason: 'remembered');
      expect(atlas.slotOf(0x416, 0, _white), -1);
      expect(atlas.slotCount, 0);
      expect(atlas.hasPending, isFalse);
    });
  });

  group('slot margins', () {
    for (final (dpr, size) in const [(1.0, 12.0), (2.0, 13.0), (3.0, 20.0)]) {
      testWidgets('hold the ink of every grid-safe glyph in every face '
          '(DPR $dpr, $size px)', (tester) async {
        final style = gridStyle.copyWith(fontSize: size);
        final metrics = VtCellMetrics.measure(style, devicePixelRatio: dpr);
        final atlas = GlyphAtlas(
          metrics: metrics,
          styleOf: (color, faces) => TextStyle(
            color: Color(color),
            fontFamily: style.fontFamily,
            fontSize: size,
            fontWeight: faces & 1 != 0 ? FontWeight.bold : null,
            fontStyle: faces & 2 != 0 ? FontStyle.italic : null,
            letterSpacing: metrics.letterSpacing,
          ).getTextStyle(),
          ledger: AtlasLedger(),
          maxPageWidth: 1 << 14,
          maxPageHeight: 1 << 14,
          maxPageBytes: 1 << 30,
        );
        addTearDown(atlas.dispose);
        final slots = <int>[
          for (var faces = 0; faces < 4; faces++)
            for (var unit = 0x21; unit < 0x530; unit++)
              if (RowRecorder.isGridSafe(unit))
                atlas.slotOf(unit, faces, _white),
        ]..removeWhere((slot) => slot < 0);
        expect(slots.length, greaterThan(1000));
        atlas.flush();
        expect(atlas.pageCount, 1);
        final rgba = (await tester.runAsync<ByteData?>(
          () => atlas
              .page(0)
              .image
              .toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        // A lit pixel on the slot's outermost row or column could be a
        // clipped glyph.
        final clipped = <int>{};
        for (final slot in slots) {
          final x0 = (slot % atlas.columns) * atlas.slotWidth;
          final y0 = (slot ~/ atlas.columns) * atlas.slotHeight;
          bool lit(int x, int y) =>
              rgba.getUint8(((y0 + y) * atlas.pageWidth + x0 + x) * 4 + 3) > 0;
          for (var x = 0; x < atlas.slotWidth; x++) {
            if (lit(x, 0) || lit(x, atlas.slotHeight - 1)) clipped.add(slot);
          }
          for (var y = 0; y < atlas.slotHeight; y++) {
            if (lit(0, y) || lit(atlas.slotWidth - 1, y)) clipped.add(slot);
          }
        }
        expect(clipped, isEmpty);
      });
    }
  });

  group('renderer', () {
    testWidgets('the atlas is the default; paragraphs opt out', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      final atlas = h.render.debugAtlas!;
      // Printable ASCII in the default foreground, prefilled in page 0.
      expect(atlas.slotCount, 94);
      expect(atlas.pageCount, 1);
      expect(h.render.debugAtlasImages, 1);
      await h.rebuild(textRendering: VtTextRendering.paragraphs);
      expect(h.render.debugAtlas, isNull);
      expect(h.render.debugAtlasImages, 0);
      expect(h.render.debugRowParagraphs, 0); // one run per row: per run
      await h.rebuild(textRendering: VtTextRendering.atlas);
      expect(h.render.debugAtlas, isNot(same(atlas)));
    });

    testWidgets('wide characters, clusters and emoji stay paragraphs; '
        'faces use the atlas', (tester) async {
      final h = await pumpRenderer(tester, initial: 'ab中é🙂x́─');
      final atlas = h.render.debugAtlas!;
      // "é" (Latin-1) is the only new slot: the rest is ASCII (prefilled)
      // or not grid-safe.
      expect(atlas.slotCount, 95);
      await h.write('\r\n\x1b[1mA\x1b[3mB\x1b[22mC');
      expect(atlas.slotCount, 98);
    });

    testWidgets('misses are rasterised once per frame', (tester) async {
      final h = await pumpRenderer(tester, cols: 40, rows: 6);
      final atlas = h.render.debugAtlas!;
      final images = atlas.debugImages;
      final recorded = h.render.debugRowRecordings;
      await h.write(
        [
          for (var i = 0; i < 6; i++)
            '\x1b[${i + 1};1H\x1b[1;3${i + 1}mbold colour $i',
        ].join(),
      );
      // One new image of the open page for six rows of new glyphs, and
      // every row recorded (and counted) once.
      expect(atlas.debugImages, images + 1);
      expect(h.render.debugRowRecordings, recorded + 6);
    });

    testWidgets('superseded pages pinned by cached pictures are counted', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, rows: 3);
      expect(h.render.debugAtlasImages, 1);
      await h.write('\x1b[1mbold');
      // The row with "bold" pins the new page 0; the blank rows draw no
      // glyph, so the prefill-only image was freed.
      expect(h.render.debugAtlasImages, 1);
      await h.write('\r\n\x1b[3mitalic');
      // Row 0's picture pins the previous image of page 0.
      expect(h.render.debugAtlasImages, 2);
      expect(h.render.debugAtlasBytes, 2 * h.render.debugAtlas!.pageBytes);
      await h.write('\x1b[1;1H\x1b[2K');
      h.render.didHaveMemoryPressure();
      expect(h.render.debugAtlasImages, 1);
    });

    testWidgets('pictures and atlas images share the budget', (tester) async {
      const budget = 4 << 20;
      final h = await pumpRenderer(
        tester,
        cols: 20,
        rows: 5,
        cacheBudget: budget,
      );
      for (var frame = 0; frame < 200; frame++) {
        await h.write(
          [
            for (var row = 0; row < 5; row++)
              '\x1b[${row + 1};1H\x1b[3${row % 8}mframe $frame\x1b[1m '
                  'row $row',
          ].join(),
        );
        expect(
          h.render.debugPictureBytes + h.render.debugAtlasBytes,
          lessThanOrEqualTo(budget - budget ~/ 4),
        );
      }
      expect(h.render.debugCachedPictures, greaterThan(5));
      expect(h.render.debugCachedPictures, lessThan(200 * 5));
    });

    testWidgets('an atlas over half the budget is rebuilt from the screen', (
      tester,
    ) async {
      // Pages of 64 KiB; every frame brings new glyphs in a new colour.
      const budget = 512 << 10;
      final h = await pumpRenderer(
        tester,
        cols: 40,
        rows: 3,
        cacheBudget: budget,
      );
      final first = h.render.debugAtlas!;
      var rebuilt = false;
      for (var i = 0; i < 11 && !rebuilt; i++) {
        await h.write(
          '\x1b[1;1H\x1b[2K\x1b[38;2;${i * 16};${255 - i * 16};0;${i.isEven ? 1 : 3}m'
          '${String.fromCharCodes(List.generate(30, (c) => 0x100 + i * 30 + c))}',
        );
        rebuilt = !identical(h.render.debugAtlas, first);
      }
      expect(rebuilt, isTrue);
      expect(h.render.debugAtlas!.liveBytes, lessThanOrEqualTo(budget ~/ 2));
    });

    testWidgets('the atlas is dropped with the caches', (tester) async {
      // As IndexedStack and Navigator hide a child: offstage, tickers off.
      Widget Function(Widget) visibility(bool visible) =>
          (view) =>
              Visibility(visible: visible, maintainState: true, child: view);
      final h = await pumpRenderer(tester, initial: 'hello');
      await h.rebuild(wrap: visibility(true));
      final render = h.render;
      final atlas = render.debugAtlas!;
      // Font change.
      final style = gridStyle.copyWith(fontSize: 14);
      await h.rebuild(
        textStyle: style,
        geometry: TerminalGeometry(
          metrics: VtCellMetrics.measure(style, devicePixelRatio: 1),
          cols: 20,
          rows: 5,
        ),
        wrap: visibility(true),
      );
      expect(h.render, same(render));
      expect(render.debugAtlas, isNot(same(atlas)));
      expect(render.debugAtlasImages, 1);
      // A theme change keeps it (keys are luminance buckets, not colours).
      final afterFont = render.debugAtlas;
      h.controller.theme = VtTerminalTheme.whiteOnBlack;
      await tester.pump();
      expect(render.debugAtlas, same(afterFont));
      // System fonts.
      await tester.binding.handleSystemMessage(<String, Object?>{
        'type': 'fontsChange',
      });
      await tester.pump();
      expect(render.debugAtlas, isNot(same(afterFont)));
      // Hidden for hiddenReleaseDelay.
      await h.rebuild(textStyle: style, wrap: visibility(false));
      await tester.pump(RenderTerminal.hiddenReleaseDelay);
      expect(render.debugAtlas, isNull);
      expect(render.debugAtlasImages, 0);
      await h.rebuild(textStyle: style, wrap: visibility(true));
      expect(h.render, same(render));
      expect(render.debugAtlasImages, 1);
      // Detach.
      await tester.pumpWidget(const SizedBox());
      expect(render.debugAtlasImages, 0);
    });

    testWidgets('a device pixel ratio change makes a new atlas', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      final atlas = h.render.debugAtlas!;
      final metrics = VtCellMetrics.measure(gridStyle, devicePixelRatio: 2);
      tester.view.devicePixelRatio = 2;
      await h.rebuild(
        geometry: TerminalGeometry(metrics: metrics, cols: 20, rows: 5),
      );
      expect(h.render.debugAtlas, isNot(same(atlas)));
      expect(h.render.debugAtlas!.metrics, metrics);
      expect(h.render.debugAtlasImages, 1);
    });

    testWidgets('memory pressure drops an atlas the screen does not need', (
      tester,
    ) async {
      // 256 KiB pages: 128 slots, so the prefill leaves 34 in page 0.
      final h = await pumpRenderer(tester, rows: 2, cacheBudget: 2 << 20);
      final atlas = h.render.debugAtlas!;
      // Enough new glyphs for a second page, then a screen of ASCII only.
      await h.write(String.fromCharCodes(List.generate(40, (c) => 0x100 + c)));
      expect(atlas.pageCount, greaterThan(1));
      await h.write('\x1b[2J\x1b[Hplain');
      h.render.didHaveMemoryPressure();
      expect(h.render.debugAtlas, isNull);
      expect(h.render.debugAtlasImages, 0);
      await tester.pump();
      expect(h.render.debugAtlas!.pageCount, 1);
    });
  });

  for (final dpr in const [1.0, 1.5, 2.0]) {
    testWidgets('the atlas paints the cells and colours that paragraphs '
        'paint (DPR $dpr)', (tester) async {
      final h = await pumpRenderer(
        tester,
        cols: 40,
        rows: 8,
        devicePixelRatio: dpr,
        initial: '\x1b[2 q\x1b[?25l',
      );
      final random = math.Random(7);
      var pixels = 0;
      var total = 0;
      var maxDelta = 0;
      for (var step = 0; step < 8; step++) {
        await h.write(
          '\x1b[H\x1b[2J'
          '${List.generate(8, (row) => '\x1b[${row + 1};1H'
              '${_mixedRow(random)}').join()}',
        );
        await h.rebuild(textRendering: VtTextRendering.paragraphs);
        final paragraphs = await h.pixels();
        await h.rebuild(textRendering: VtTextRendering.atlas);
        final atlas = await h.pixels();
        expect(atlas.length, paragraphs.length);
        for (var i = 0; i < paragraphs.length; i += 4) {
          var differs = false;
          for (var c = 0; c < 4; c++) {
            final d = (paragraphs[i + c] - atlas[i + c]).abs();
            // ±1 is premultiplied rounding (untinted against blended).
            if (d > 1) differs = true;
            if (d > maxDelta) maxDelta = d;
          }
          if (differs) pixels++;
          total++;
        }
      }
      // Same positions; coverage within one luminance bucket of the text
      // colour's (measured 2026-11-10 on flutter_tester: 0.4-0.7 % of
      // pixels differ by more than 1, max delta 12).
      expect(pixels / total, lessThan(0.02), reason: '$pixels of $total');
      expect(maxDelta, lessThanOrEqualTo(16));
    }, tags: ['golden']);
  }
}
