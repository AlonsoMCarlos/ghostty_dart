// Adversarial tests from the correctness review of the Kitty graphics
// module (T09).

import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';
import 'kitty_support.dart';

/// Transmits and places a 1×1 RGBA image with [keys].
void _send(VtTerminal terminal, String keys) => writeText(
  terminal,
  '\x1b_Ga=T,f=32,s=1,v=1,q=2,$keys;${base64.encode([1, 2, 3, 4])}\x1b\\',
);

void main() {
  group('layer filter', skip: skipWithoutKitty, () {
    test('z-index boundaries land in the documented layers', () {
      withKittyTerminal((terminal) {
        const zs = {
          1: -2147483648, // int32 min
          2: -1073741825,
          3: -1073741824,
          4: -1,
          5: 0,
          6: 2147483647, // int32 max
        };
        zs.forEach((id, z) => _send(terminal, 'i=$id,z=$z'));
        Set<int> ids(Set<ImageLayer> layers) => {
          for (final p in terminal.kittyPlacements(layers: layers)) p.imageId,
        };
        expect(ids({ImageLayer.belowBackground}), {1, 2});
        expect(ids({ImageLayer.belowText}), {3, 4});
        expect(ids({ImageLayer.aboveText}), {5, 6});
        expect(ids(ImageLayer.values.toSet()..remove(ImageLayer.unknown)), {
          1,
          2,
          3,
          4,
          5,
          6,
        });
        // The z-index round-trips through the int32 slot with its sign.
        expect({
          for (final p in terminal.kittyPlacements()) p.imageId: p.z,
        }, zs);
      });
    });
  });

  group('geometry', skip: skipWithoutKitty, () {
    test('a relative placement has a viewport position but no rectangle', () {
      withKittyTerminal((terminal) {
        writeText(terminal, '\x1b[3;4H');
        _send(terminal, 'i=1,p=1');
        writeText(terminal, '\x1b_Ga=p,i=1,p=2,P=1,Q=1,H=2,V=1,q=2\x1b\\');
        final placements = {
          for (final p in terminal.kittyPlacements()) p.placementId: p,
        };
        expect(placements.keys, unorderedEquals([1, 2]));
        final parent = placements[1]!.geometry!;
        final child = placements[2]!.geometry!;
        expect(parent.screenTopLeft, const GridPoint.screen(3, 2));
        expect(child.isInViewport, isTrue);
        expect(child.viewportCol, parent.viewportCol! + 2);
        expect(child.viewportRow, parent.viewportRow! + 1);
        expect(child.screenTopLeft, isNull);
        expect(child.screenBottomRight, isNull);
      });
    });

    test('a terminal without a cell size does not break the list', () {
      withTerminal(20, 10, (terminal) {
        _send(terminal, 'i=1');
        final placement = terminal.kittyPlacements().single;
        expect(placement.imageId, 1);
        final geometry = placement.geometry!;
        // No pixel geometry: the placement covers no cells, so the storage
        // has no rectangle for it.
        if (geometry.gridCols == 0 || geometry.gridRows == 0) {
          expect(geometry.screenTopLeft, isNull);
        }
      });
    });

    test('the bottom-right corner is clamped to the last column', () {
      withKittyTerminal((terminal) {
        writeText(terminal, '\x1b[1;19H');
        _send(terminal, 'i=1,c=5,r=1');
        final geometry = terminal.kittyPlacements().single.geometry!;
        expect(geometry.screenTopLeft, const GridPoint.screen(18, 0));
        expect(geometry.screenBottomRight, const GridPoint.screen(19, 0));
      });
    });
  });

  group('images', skip: skipWithoutKitty, () {
    test('ids at the ends of the uint32 range are looked up safely', () {
      withKittyTerminal((terminal) {
        _send(terminal, 'i=4294967295');
        expect(terminal.kittyImage(0), isNull);
        expect(terminal.kittyImagePixels(0), isNull);
        expect(terminal.kittyImage(4294967295)?.id, 4294967295);
        expect(terminal.kittyImagePixels(4294967295), [1, 2, 3, 4]);
      });
    });

    test('an image whose pixels are still arriving has none yet', () {
      withKittyTerminal((terminal) {
        // First chunk only (m=1): the image is not complete.
        writeText(
          terminal,
          '\x1b_Ga=t,f=32,s=1,v=2,i=7,m=1,q=2;'
          '${base64.encode([1, 2, 3, 4])}\x1b\\',
        );
        final image = terminal.kittyImage(7);
        if (image != null) {
          expect(image.hasPixels, terminal.kittyImagePixels(7) != null);
        } else {
          expect(terminal.kittyImagePixels(7), isNull);
        }
      });
    });
  });

  group('animation', skip: skipWithoutKitty, () {
    test('a due time beyond the Dart int range saturates', () {
      withKittyTerminal((terminal) {
        _send(terminal, 'i=1');
        writeText(
          terminal,
          '\x1b_Ga=f,i=1,f=32,s=1,v=1,z=100,q=2;'
          '${base64.encode([0, 0, 255, 255])}\x1b\\',
        );
        writeText(terminal, '\x1b_Ga=a,i=1,s=3,v=1,q=2\x1b\\');
        const maxInt = 0x7FFFFFFFFFFFFFFF;
        final next = terminal.tickKittyAnimations(maxInt);
        expect(next, maxInt);
      });
    });
  });
}
