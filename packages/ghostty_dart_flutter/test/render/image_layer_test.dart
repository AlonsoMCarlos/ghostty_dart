// Kitty graphics images in the renderer and the controller (ADR 0014):
// placement geometry, layer order, texture lifetime and animation ticking.
// Images are transmitted as raw RGB/RGBA through a real controller, so no
// PNG decoder is needed.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/controller/controller_internals.dart';
import 'package:ghostty_dart_flutter/src/render/image_layer.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_seams.dart';

import '../support/fonts.dart';
import 'render_harness.dart';

final _skip = libghosttyVtBuildInfo.supports(VtFeature.kittyGraphics)
    ? null
    : 'the loaded libghostty-vt lacks Kitty graphics';

/// Transmits and places an RGBA image (`a=T,f=32`), not moving the cursor.
String _rgba(int width, int height, List<int> pixels, [String keys = '']) =>
    '\x1b_Ga=T,f=32,s=$width,v=$height,C=1,q=2'
    '${keys.isEmpty ? '' : ',$keys'};${base64.encode(pixels)}\x1b\\';

/// Transmits and places an RGB image (`a=T,f=24`), not moving the cursor.
String _rgb(int width, int height, List<int> pixels, [String keys = '']) =>
    '\x1b_Ga=T,f=24,s=$width,v=$height,C=1,q=2'
    '${keys.isEmpty ? '' : ',$keys'};${base64.encode(pixels)}\x1b\\';

/// [count] opaque pixels of one colour, RGBA.
List<int> _solid(int count, int r, int g, int b) => [
  for (var i = 0; i < count; i++) ...[r, g, b, 255],
];

/// Pumps a renderer whose terminal knows its cell size in device pixels
/// (the view does this on layout), so placements get pixel sizes.
Future<RenderHarness> _pump(
  WidgetTester tester, {
  int cols = 20,
  int rows = 5,
  double devicePixelRatio = 1,
}) async {
  final h = await pumpRenderer(
    tester,
    cols: cols,
    rows: rows,
    devicePixelRatio: devicePixelRatio,
  );
  final metrics = h.geometry.metrics;
  h.controller.resize(
    cols,
    rows,
    cellWidthPx: metrics.widthPx,
    cellHeightPx: metrics.heightPx,
  );
  await tester.pump();
  return h;
}

extension on RenderHarness {
  KittyImageLayer get images => render.debugImages;

  /// Lets the texture uploads in flight complete, then pumps a frame.
  Future<void> settleImages() async {
    for (var i = 0; i < 200 && images.debugPendingUploads > 0; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    expect(images.debugPendingUploads, 0, reason: 'uploads never completed');
    await tester.pump();
  }

  /// [cells] in logical pixels, from the grid's top-left.
  Rect cellRect(double col, double row, double cols, double rows) {
    final m = geometry.metrics;
    final dpr = m.devicePixelRatio;
    return Rect.fromLTWH(
      col * m.widthPx / dpr,
      row * m.heightPx / dpr,
      cols * m.widthPx / dpr,
      rows * m.heightPx / dpr,
    );
  }
}

void main() {
  setUpAll(loadJetBrainsMono);

  group('premultipliedRgba', () {
    ImagePixels pixels(KittyImageFormat format, List<int> bytes, int count) => (
      width: count,
      height: 1,
      format: format,
      generation: 1,
      pixels: Uint8List.fromList(bytes),
    );

    test('expands RGB, grey and grey+alpha and premultiplies alpha', () {
      expect(
        KittyImageLayer.premultipliedRgba(
          pixels(KittyImageFormat.rgb, [1, 2, 3], 1),
        ),
        [1, 2, 3, 255],
      );
      expect(
        KittyImageLayer.premultipliedRgba(
          pixels(KittyImageFormat.gray, [7], 1),
        ),
        [7, 7, 7, 255],
      );
      expect(
        KittyImageLayer.premultipliedRgba(
          pixels(KittyImageFormat.grayAlpha, [200, 128], 1),
        ),
        [100, 100, 100, 128],
      );
      expect(
        KittyImageLayer.premultipliedRgba(
          pixels(KittyImageFormat.rgba, [255, 100, 0, 0, 10, 20, 30, 255], 2),
        ),
        [0, 0, 0, 0, 10, 20, 30, 255],
      );
    });

    test('rejects short data and formats without a pixel size', () {
      expect(
        KittyImageLayer.premultipliedRgba(
          pixels(KittyImageFormat.rgb, [1, 2], 1),
        ),
        isNull,
      );
      expect(
        KittyImageLayer.premultipliedRgba(
          pixels(KittyImageFormat.png, [1, 2, 3], 1),
        ),
        isNull,
      );
    });
  });

  group('drawing', skip: _skip, () {
    testWidgets('a placement is drawn from its source rect into its cells', (
      tester,
    ) async {
      final h = await _pump(tester);
      // A 4 x 2 image, columns 1-2 of row 0 only, stretched over 3 x 2
      // cells at row 1, column 2.
      await h.write(
        '\x1b[2;3H${_rgba(4, 2, _solid(8, 255, 0, 0), 'i=1,x=1,y=0,w=2,h=1,c=3,r=2')}',
      );
      expect(h.images.debugPlacements, hasLength(1));
      await h.settleImages();
      final texture = h.images.debugTexture(1)!;
      expect((texture.width, texture.height), (4, 2));
      expect(
        h.render,
        paints..drawImageRect(
          image: texture,
          source: const Rect.fromLTWH(1, 0, 2, 1),
          destination: h.cellRect(2, 1, 3, 2),
        ),
      );
    });

    testWidgets('device pixels are divided by the device pixel ratio', (
      tester,
    ) async {
      final h = await _pump(tester, devicePixelRatio: 2);
      // An 8 x 6 RGB image at its own size, offset by (3, 1) device
      // pixels inside its first cell.
      await h.write(
        '\x1b[1;2H${_rgb(8, 6, [
          for (var i = 0; i < 48; i++) ...[0, 128, 255],
        ], 'i=2,X=3,Y=1')}',
      );
      await h.settleImages();
      final m = h.geometry.metrics;
      expect(
        h.render,
        paints..drawImageRect(
          source: const Rect.fromLTWH(0, 0, 8, 6),
          destination: Rect.fromLTWH((m.widthPx + 3) / 2, 1 / 2, 8 / 2, 6 / 2),
        ),
      );
    });

    testWidgets('layers: below the rows, above them, by z within a layer', (
      tester,
    ) async {
      final h = await _pump(tester);
      final px = _solid(1, 9, 9, 9);
      await h.write(
        'text'
        '\x1b[1;1H${_rgba(1, 1, px, 'i=1,c=1,r=1,z=5')}'
        '\x1b[1;2H${_rgba(1, 1, px, 'i=2,c=1,r=1,z=-1')}'
        '\x1b[1;3H${_rgba(1, 1, px, 'i=3,c=1,r=1,z=-1073741825')}'
        '\x1b[1;4H${_rgba(1, 1, px, 'i=4,c=1,r=1,z=1')}',
      );
      await h.settleImages();
      expect(h.images.debugPlacements.map((p) => p.imageId), [3, 2, 4, 1]);
      expect(
        h.render,
        paints
          ..rect() // default background
          ..drawImageRect(destination: h.cellRect(2, 0, 1, 1))
          ..drawImageRect(destination: h.cellRect(1, 0, 1, 1))
          ..something((method, _) => method == #drawPicture) // rows
          ..drawImageRect(destination: h.cellRect(3, 0, 1, 1))
          ..drawImageRect(destination: h.cellRect(0, 0, 1, 1)),
      );
    });

    testWidgets('images are clipped to the grid', (tester) async {
      final h = await _pump(tester, cols: 4, rows: 2);
      await h.write('\x1b[2;3H${_rgba(1, 1, _solid(1, 1, 2, 3), 'c=6,r=4')}');
      await h.settleImages();
      expect(
        h.render,
        paints
          ..clipRect(rect: h.cellRect(0, 0, 4, 2))
          ..drawImageRect(destination: h.cellRect(2, 1, 6, 4)),
      );
    });
  });

  group('textures', skip: _skip, () {
    testWidgets('are reused across repaints and disposed on delete', (
      tester,
    ) async {
      final h = await _pump(tester);
      await h.write(_rgba(2, 2, _solid(4, 0, 255, 0), 'i=7,c=2,r=1'));
      expect(h.images.debugPendingUploads, 1);
      // Nothing is drawn before the texture is ready.
      expect(h.render, isNot(paints..drawImageRect()));
      await h.settleImages();
      final texture = h.images.debugTexture(7)!;
      final recordings = h.render.debugRowRecordings;

      await h.write('\x1b[3;1Hmore output');
      await h.write('\x1b[4;1Hand more');
      expect(h.images.debugTexture(7), same(texture));
      expect(h.images.debugPendingUploads, 0);
      expect(h.render.debugRowRecordings, greaterThan(recordings));

      await h.write('\x1b_Ga=d,d=I,i=7,q=2\x1b\\');
      expect(h.images.debugTextureCount, 0);
      expect(texture.debugDisposed, isTrue);
      expect(h.render, isNot(paints..drawImageRect()));
    });

    testWidgets('a replaced image keeps its old texture until the new one '
        'is ready', (tester) async {
      final h = await _pump(tester);
      await h.write(_rgba(1, 1, _solid(1, 255, 0, 0), 'i=1,c=2,r=1'));
      await h.settleImages();
      final old = h.images.debugTexture(1)!;

      await h.write(_rgba(2, 1, _solid(2, 0, 0, 255), 'i=1,c=2,r=1'));
      expect(h.images.debugPendingUploads, 1);
      expect(h.images.debugTexture(1), same(old));
      expect(h.render, paints..drawImageRect(image: old));

      await h.settleImages();
      final replacement = h.images.debugTexture(1)!;
      expect(replacement, isNot(same(old)));
      expect(replacement.width, 2);
      expect(old.debugDisposed, isTrue);
      expect(h.render, paints..drawImageRect(image: replacement));
    });

    testWidgets('scrolling moves the image with its text', (tester) async {
      final h = await _pump(tester);
      await h.write('\x1b[4;1H${_rgba(1, 1, _solid(1, 1, 1, 1), 'c=1,r=1')}');
      await h.settleImages();
      expect(h.images.debugPlacements.single.viewportRow, 3);

      await h.write('\x1b[5;1H\n\n');
      expect(h.images.debugPlacements.single.viewportRow, 1);
      expect(
        h.render,
        paints..drawImageRect(destination: h.cellRect(0, 1, 1, 1)),
      );
    });

    testWidgets('the alternate screen has its own images', (tester) async {
      final h = await _pump(tester);
      await h.write(_rgba(1, 1, _solid(1, 1, 1, 1), 'i=1,c=1,r=1'));
      await h.settleImages();
      final primary = h.images.debugTexture(1)!;

      await h.write('\x1b[?1049h');
      expect(h.images.debugPlacements, isEmpty);
      expect(primary.debugDisposed, isTrue);
      expect(h.render, isNot(paints..drawImageRect()));

      await h.write(
        '\x1b[2;2H${_rgba(1, 1, _solid(1, 2, 2, 2), 'i=1,c=1,r=1')}',
      );
      await h.settleImages();
      expect(
        h.render,
        paints..drawImageRect(destination: h.cellRect(1, 1, 1, 1)),
      );

      await h.write('\x1b[?1049l');
      await h.settleImages();
      expect(
        h.render,
        paints..drawImageRect(destination: h.cellRect(0, 0, 1, 1)),
      );
    });

    testWidgets('released caches drop the textures and rebuild them', (
      tester,
    ) async {
      final h = await _pump(tester);
      await h.write(_rgba(1, 1, _solid(1, 1, 1, 1), 'i=1,c=1,r=1'));
      await h.settleImages();
      final texture = h.images.debugTexture(1)!;
      h.render.debugDropCaches();
      expect(texture.debugDisposed, isTrue);
      await tester.pump();
      await h.settleImages();
      expect(h.images.debugTexture(1), isNotNull);
    });

    testWidgets('an upload completing after dispose disposes its image', (
      tester,
    ) async {
      final h = await _pump(tester);
      await h.write(_rgba(1, 1, _solid(1, 1, 1, 1), 'i=1,c=1,r=1'));
      final images = h.images;
      expect(images.debugPendingUploads, 1);
      await tester.pumpWidget(const SizedBox());
      h.controller.dispose();
      expect(images.debugTextureCount, 0);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(images.debugTextureCount, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('animation', skip: _skip, () {
    bool animating(VtTerminalController c) => internalsOf(c).isAnimating;

    testWidgets('no timer while nothing animates', (tester) async {
      final controller = VtTerminalController(cols: 10, rows: 3);
      addTearDown(controller.dispose);
      controller.write('text');
      expect(animating(controller), isFalse);
      controller.write(_rgba(1, 1, _solid(1, 1, 1, 1), 'i=1'));
      expect(animating(controller), isFalse);
    });

    testWidgets('frames advance on the fake clock and notify listeners', (
      tester,
    ) async {
      final h = await _pump(tester);
      var notifications = 0;
      h.controller.addListener(() => notifications++);
      await h.write(_rgba(1, 1, _solid(1, 255, 0, 0), 'i=1,c=1,r=1'));
      await h.write(
        '\x1b_Ga=f,i=1,f=32,s=1,v=1,z=100,q=2;'
        '${base64.encode(_solid(1, 0, 0, 255))}\x1b\\',
      );
      await h.write('\x1b_Ga=a,i=1,s=3,v=1,q=2\x1b\\');
      expect(animating(h.controller), isTrue);
      await h.settleImages();
      final generation = h.images.debugPlacements.single.imageGeneration;
      final first = h.images.debugTexture(1)!;

      notifications = 0;
      await tester.pump(const Duration(milliseconds: 150));
      expect(notifications, greaterThan(0));
      await tester.pump();
      expect(
        h.images.debugPlacements.single.imageGeneration,
        isNot(generation),
      );
      await h.settleImages();
      expect(h.images.debugTexture(1), isNot(same(first)));
      expect(first.debugDisposed, isTrue);

      // Stopping the animation stops the timer.
      await h.write('\x1b_Ga=a,i=1,s=1,q=2\x1b\\');
      expect(animating(h.controller), isFalse);
    });

    testWidgets('dispose cancels the animation timer', (tester) async {
      final controller = VtTerminalController(cols: 10, rows: 3);
      controller
        ..write(_rgba(1, 1, _solid(1, 255, 0, 0), 'i=1'))
        ..write(
          '\x1b_Ga=f,i=1,f=32,s=1,v=1,z=40,q=2;'
          '${base64.encode(_solid(1, 0, 0, 255))}\x1b\\',
        )
        ..write('\x1b_Ga=a,i=1,s=3,v=1,q=2\x1b\\');
      expect(animating(controller), isTrue);
      controller.dispose();
      // A pending timer would fail the test at its end.
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('imageStorageLimit', skip: _skip, () {
    test('is applied to the terminal', () {
      final controller = VtTerminalController(imageStorageLimit: 123456);
      addTearDown(controller.dispose);
      expect(controller.terminal.kittyImageStorageLimit, 123456);
    });

    test('null keeps the library default', () {
      final controller = VtTerminalController();
      addTearDown(controller.dispose);
      expect(controller.terminal.kittyImageStorageLimit, 10 * 1000 * 1000);
    });

    test('0 disables Kitty graphics', () {
      final controller = VtTerminalController(imageStorageLimit: 0);
      addTearDown(controller.dispose);
      controller.write(_rgba(1, 1, _solid(1, 1, 1, 1), 'i=1'));
      expect(controller.terminal.kittyImage(1), isNull);
    });

    test('a negative limit throws RangeError', () {
      expect(
        () => VtTerminalController(imageStorageLimit: -1),
        throwsRangeError,
      );
    });
  });
}
