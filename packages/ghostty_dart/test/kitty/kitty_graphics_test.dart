import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/kitty/kitty_types.dart';
import 'package:test/test.dart';

import '../support/expect_support.dart';
import '../support/terminal_support.dart';
import 'kitty_support.dart';

/// Transmits and places an RGBA image (APC `a=T`) with [keys].
void _sendRgba(VtTerminal terminal, String keys, List<int> pixels) => writeText(
  terminal,
  '\x1b_Ga=T,f=32,q=2,$keys;${base64.encode(pixels)}\x1b\\',
);

void main() {
  group('enums', () {
    test('KittyImageFormat matches GhosttyKittyImageFormat', () {
      expectCodec(
        kittyImageFormatCodec,
        KittyImageFormat.values,
        KittyImageFormat.unknown,
        {
          KittyImageFormat.rgb:
              GhosttyKittyImageFormat.GHOSTTY_KITTY_IMAGE_FORMAT_RGB,
          KittyImageFormat.rgba:
              GhosttyKittyImageFormat.GHOSTTY_KITTY_IMAGE_FORMAT_RGBA,
          KittyImageFormat.png:
              GhosttyKittyImageFormat.GHOSTTY_KITTY_IMAGE_FORMAT_PNG,
          KittyImageFormat.grayAlpha:
              GhosttyKittyImageFormat.GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA,
          KittyImageFormat.gray:
              GhosttyKittyImageFormat.GHOSTTY_KITTY_IMAGE_FORMAT_GRAY,
        },
      );
    });

    test('KittyImageCompression matches GhosttyKittyImageCompression', () {
      expectCodec(
        kittyImageCompressionCodec,
        KittyImageCompression.values,
        KittyImageCompression.unknown,
        {
          KittyImageCompression.none:
              GhosttyKittyImageCompression.GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE,
          KittyImageCompression.zlibDeflate: GhosttyKittyImageCompression
              .GHOSTTY_KITTY_IMAGE_COMPRESSION_ZLIB_DEFLATE,
        },
      );
    });

    test('bytesPerPixel', () {
      expect(KittyImageFormat.rgb.bytesPerPixel, 3);
      expect(KittyImageFormat.rgba.bytesPerPixel, 4);
      expect(KittyImageFormat.grayAlpha.bytesPerPixel, 2);
      expect(KittyImageFormat.gray.bytesPerPixel, 1);
      expect(KittyImageFormat.png.bytesPerPixel, isNull);
      expect(KittyImageFormat.unknown.bytesPerPixel, isNull);
    });
  });

  group('images', skip: skipWithoutKitty, () {
    test('an empty storage has generation 0 and no images', () {
      withKittyTerminal((terminal) {
        expect(terminal.kittyGraphicsGeneration, 0);
        expect(terminal.kittyImage(1), isNull);
        expect(terminal.kittyImagePixels(1), isNull);
        expect(terminal.kittyPlacements(), isEmpty);
      });
    });

    test('a transmitted image is described and its pixels copied', () {
      withKittyTerminal((terminal) {
        final pixels = [for (var i = 0; i < 2 * 3 * 4; i++) i];
        _sendRgba(terminal, 's=2,v=3,i=9', pixels);

        expect(terminal.kittyGraphicsGeneration, isNot(0));
        final image = terminal.kittyImage(9)!;
        expect(image.id, 9);
        expect(image.number, 0);
        expect(image.width, 2);
        expect(image.height, 3);
        expect(image.format, KittyImageFormat.rgba);
        expect(image.compression, KittyImageCompression.none);
        expect(image.pixelByteLength, pixels.length);
        expect(image.generation, isNot(0));
        expect(image.hasPixels, isTrue);
        expect(terminal.kittyImagePixels(9), pixels);
      });
    });

    test('RGB and gray images keep their format', () {
      withKittyTerminal((terminal) {
        writeText(terminal, '\x1b_Ga=t,f=24,s=1,v=1,i=1,q=2;AAAA\x1b\\');
        final image = terminal.kittyImage(1)!;
        expect(image.format, KittyImageFormat.rgb);
        expect(image.pixelByteLength, 3);
        expect(terminal.kittyImagePixels(1), [0, 0, 0]);
      });
    });

    test('the copy and the description survive later writes', () {
      withKittyTerminal((terminal) {
        _sendRgba(terminal, 's=1,v=1,i=3', [1, 2, 3, 4]);
        final image = terminal.kittyImage(3)!;
        final pixels = terminal.kittyImagePixels(3)!;
        _sendRgba(terminal, 's=1,v=1,i=3', [5, 6, 7, 8]);
        expect(pixels, [1, 2, 3, 4]);
        expect(terminal.kittyImagePixels(3), [5, 6, 7, 8]);
        final replaced = terminal.kittyImage(3)!;
        expect(replaced.generation, isNot(image.generation));
        expect(replaced, isNot(image));
        expect(terminal.kittyImage(3), replaced);
      });
    });

    test('deleted images are gone', () {
      withKittyTerminal((terminal) {
        _sendRgba(terminal, 's=1,v=1,i=4', [1, 2, 3, 4]);
        final before = terminal.kittyGraphicsGeneration;
        writeText(terminal, '\x1b_Ga=d,d=I,i=4,q=2\x1b\\');
        expect(terminal.kittyImage(4), isNull);
        expect(terminal.kittyGraphicsGeneration, isNot(before));
      });
    });

    test('PNG images are rejected without a decoder', () {
      withKittyTerminal((terminal) {
        writeText(
          terminal,
          '\x1b_Ga=t,f=100,i=5,q=2;${base64.encode(utf8.encode('png'))}\x1b\\',
        );
        expect(terminal.kittyImage(5), isNull);
      });
    });

    test('image ids outside uint32 throw RangeError', () {
      withKittyTerminal((terminal) {
        expect(() => terminal.kittyImage(-1), throwsRangeError);
        expect(() => terminal.kittyImage(0x100000000), throwsRangeError);
        expect(() => terminal.kittyImagePixels(-1), throwsRangeError);
        expect(terminal.kittyImage(0xFFFFFFFF), isNull);
      });
    });

    test('each screen has its own storage', () {
      withKittyTerminal((terminal) {
        _sendRgba(terminal, 's=1,v=1,i=1', [1, 2, 3, 4]);
        writeText(terminal, '\x1b[?1049h');
        expect(terminal.kittyImage(1), isNull);
        writeText(terminal, '\x1b[?1049l');
        expect(terminal.kittyImage(1), isNotNull);
      });
    });
  });

  group('placements', skip: skipWithoutKitty, () {
    test('a placement reports its request and resolved geometry', () {
      withKittyTerminal((terminal) {
        writeText(terminal, '\x1b[3;4H');
        _sendRgba(
          terminal,
          's=2,v=2,i=9,p=4,c=3,r=2,X=3,Y=5,z=-5',
          List.filled(16, 0x7f),
        );
        final placements = terminal.kittyPlacements();
        expect(placements, hasLength(1));
        final placement = placements.single;
        expect(placement.imageId, 9);
        expect(placement.placementId, 4);
        expect(placement.isVirtual, isFalse);
        expect(placement.cellOffsetX, 3);
        expect(placement.cellOffsetY, 5);
        expect(placement.sourceWidth, 0);
        expect(placement.sourceHeight, 0);
        expect(placement.columns, 3);
        expect(placement.rows, 2);
        expect(placement.z, -5);

        final geometry = placement.geometry!;
        expect(geometry.gridCols, 3);
        expect(geometry.gridRows, 2);
        expect(geometry.isInViewport, isTrue);
        expect(geometry.viewportCol, 3);
        expect(geometry.viewportRow, 2);
        expect((geometry.sourceWidth, geometry.sourceHeight), (2, 2));
        expect(geometry.pixelWidth, greaterThan(0));
        expect(geometry.screenTopLeft, const GridPoint.screen(3, 2));
        expect(geometry.screenBottomRight, const GridPoint.screen(5, 3));
      });
    });

    test('geometry matches the render state', () {
      withKittyTerminal((terminal) {
        writeText(terminal, '\x1b[2;2H');
        _sendRgba(terminal, 's=2,v=1,i=2,x=1,w=1', List.filled(8, 1));
        final geometry = terminal.kittyPlacements().single.geometry!;
        final state = RenderState()..update(terminal);
        addTearDown(state.dispose);
        final rendered = state.imagePlacements().single;
        expect(rendered.imageId, 2);
        expect(geometry.viewportCol, rendered.viewportCol);
        expect(geometry.viewportRow, rendered.viewportRow);
        expect(geometry.gridCols, rendered.gridCols);
        expect(geometry.pixelWidth, rendered.pixelWidth);
        expect(geometry.sourceX, rendered.sourceX);
        expect(geometry.sourceWidth, rendered.sourceWidth);
      });
    });

    test(
      'a placement scrolled out of the viewport has no viewport position',
      () {
        withKittyTerminal((terminal) {
          _sendRgba(terminal, 's=1,v=1,i=1', [1, 2, 3, 4]);
          writeText(terminal, '\n' * 30);
          final geometry = terminal.kittyPlacements().single.geometry!;
          expect(geometry.isInViewport, isFalse);
          expect(geometry.viewportCol, isNull);
          expect(geometry.viewportRow, isNull);
          expect(geometry.screenTopLeft, const GridPoint.screen(0, 0));
        });
      },
    );

    test('virtual placements have no position', () {
      withKittyTerminal((terminal) {
        _sendRgba(terminal, 's=1,v=1,i=6,U=1,c=2,r=1', [1, 2, 3, 4]);
        final placement = terminal.kittyPlacements().single;
        expect(placement.isVirtual, isTrue);
        expect(placement.geometry!.isInViewport, isFalse);
        expect(placement.geometry!.screenTopLeft, isNull);
        expect(placement.geometry!.screenBottomRight, isNull);
      });
    });

    test('layer filters select by z-index', () {
      withKittyTerminal((terminal) {
        _sendRgba(terminal, 's=1,v=1,i=1,z=5', [1, 2, 3, 4]);
        _sendRgba(terminal, 's=1,v=1,i=2,z=-5', [1, 2, 3, 4]);
        _sendRgba(terminal, 's=1,v=1,i=3,z=-1073741825', [1, 2, 3, 4]);
        Set<int> ids(Set<ImageLayer>? layers) => {
          for (final p in terminal.kittyPlacements(layers: layers)) p.imageId,
        };
        expect(ids(null), {1, 2, 3});
        expect(ids({ImageLayer.aboveText}), {1});
        expect(ids({ImageLayer.belowText}), {2});
        expect(ids({ImageLayer.belowBackground}), {3});
        expect(ids({ImageLayer.aboveText, ImageLayer.belowBackground}), {1, 3});
        expect(ids({}), isEmpty);
        expect(
          () => terminal.kittyPlacements(layers: {ImageLayer.unknown}),
          throwsArgumentError,
        );
      });
    });

    test('the list is an unmodifiable copy', () {
      withKittyTerminal((terminal) {
        _sendRgba(terminal, 's=1,v=1,i=1', [1, 2, 3, 4]);
        final placements = terminal.kittyPlacements();
        expect(() => placements.add(placements.first), throwsUnsupportedError);
        writeText(terminal, '\x1b_Ga=d,d=A,q=2\x1b\\');
        expect(placements, hasLength(1));
        expect(terminal.kittyPlacements(), isEmpty);
      });
    });
  });

  group('animation', skip: skipWithoutKitty, () {
    test('nothing playing returns null', () {
      withKittyTerminal((terminal) {
        expect(terminal.tickKittyAnimations(0), isNull);
        _sendRgba(terminal, 's=1,v=1,i=1', [1, 2, 3, 4]);
        expect(terminal.tickKittyAnimations(10), isNull);
      });
    });

    test('a playing animation changes frame and schedules the next', () {
      withKittyTerminal((terminal) {
        _sendRgba(terminal, 's=1,v=1,i=1', [255, 0, 0, 255]);
        writeText(
          terminal,
          '\x1b_Ga=f,i=1,f=32,s=1,v=1,z=100,q=2;'
          '${base64.encode([0, 0, 255, 255])}\x1b\\',
        );
        writeText(terminal, '\x1b_Ga=a,i=1,s=3,v=1,q=2\x1b\\');
        final before = terminal.kittyImage(1)!.generation;

        final next = terminal.tickKittyAnimations(0);
        expect(next, isNotNull);
        expect(next, greaterThan(0));
        expect(terminal.kittyImage(1)!.generation, isNot(before));
        expect(terminal.tickKittyAnimations(next!), greaterThan(next));
      });
    });

    test('ticking invalidates borrowed views', () {
      withKittyTerminal((terminal) {
        final ref = terminal.gridRef(const GridPoint.active(0, 0))!;
        terminal.tickKittyAnimations(0);
        expect(ref.isValid, isFalse);
      });
    });

    test('a negative time throws RangeError', () {
      withKittyTerminal((terminal) {
        expect(() => terminal.tickKittyAnimations(-1), throwsRangeError);
      });
    });
  });

  group('lifecycle', skip: skipWithoutKitty, () {
    test('members throw StateError after dispose', () {
      final terminal = VtTerminal(cols: 10, rows: 5)..dispose();
      expect(() => terminal.kittyGraphicsGeneration, throwsStateError);
      expect(() => terminal.kittyImage(1), throwsStateError);
      expect(() => terminal.kittyImagePixels(1), throwsStateError);
      expect(() => terminal.kittyPlacements(), throwsStateError);
      expect(
        () => terminal.kittyPlacements(layers: const {}),
        throwsStateError,
      );
      expect(() => terminal.tickKittyAnimations(0), throwsStateError);
    });

    test('members throw StateError inside a callback of the terminal', () {
      withKittyTerminal((terminal) {
        final errors = <Object>[];
        terminal.onBell = () {
          for (final read in <void Function()>[
            () => terminal.kittyGraphicsGeneration,
            () => terminal.kittyImage(1),
            () => terminal.kittyImagePixels(1),
            () => terminal.kittyPlacements(),
            () => terminal.tickKittyAnimations(0),
          ]) {
            try {
              read();
            } catch (error) {
              errors.add(error);
            }
          }
        };
        writeText(terminal, '\x07');
        expect(errors, hasLength(5));
        expect(errors, everyElement(isA<StateError>()));
      });
    });
  });

  test(
    'without the build feature every member is unsupported',
    skip: hasKittyGraphics ? 'built with Kitty graphics' : null,
    () {
      withTerminal(10, 5, (terminal) {
        expect(() => terminal.kittyGraphicsGeneration, throwsUnsupportedError);
        expect(() => terminal.kittyPlacements(), throwsUnsupportedError);
      });
    },
  );

  group('value types', () {
    test('KittyImage equality and toString', () {
      KittyImage image({int generation = 1, bool hasPixels = true}) =>
          KittyImage(
            id: 1,
            number: 0,
            width: 2,
            height: 2,
            format: KittyImageFormat.rgba,
            compression: KittyImageCompression.none,
            pixelByteLength: 16,
            generation: generation,
            hasPixels: hasPixels,
          );
      expect(image(), image());
      expect(image().hashCode, image().hashCode);
      expect(image(generation: 2), isNot(image()));
      expect(image(hasPixels: false).toString(), contains('pending'));
    });

    test('KittyPlacementGeometry equality', () {
      KittyPlacementGeometry geometry({int? col = 1}) => KittyPlacementGeometry(
        pixelWidth: 10,
        pixelHeight: 20,
        gridCols: 1,
        gridRows: 1,
        viewportCol: col,
        viewportRow: col,
        sourceX: 0,
        sourceY: 0,
        sourceWidth: 1,
        sourceHeight: 1,
        screenTopLeft: const GridPoint.screen(1, 1),
        screenBottomRight: const GridPoint.screen(1, 1),
      );
      expect(geometry(), geometry());
      expect(geometry().hashCode, geometry().hashCode);
      expect(geometry(col: null), isNot(geometry()));
      expect(geometry(col: null).isInViewport, isFalse);
    });
  });
}
