// Adversarial tests from the correctness review of the Unicode width API.

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

void main() {
  group('firstGraphemeCellWidth (review)', () {
    test('lengths count codepoints, not UTF-16 units', () {
      // 👍🏽 is 2 codepoints (4 UTF-16 units).
      final thumbs = '👍🏽'.runes.toList();
      expect(firstGraphemeCellWidth([0x61, ...thumbs], start: 1), (
        length: 2,
        width: 2,
      ));
    });

    test('emoji sequences', () {
      // Flag: two regional indicators.
      expect(firstGraphemeCellWidth('🇪🇸'.runes.toList()), (
        length: 2,
        width: 2,
      ));
      // ZWJ family.
      final family = '👨‍👩‍👧'.runes.toList();
      expect(firstGraphemeCellWidth(family), (length: family.length, width: 2));
      // VS16 widens a text-default base, VS15 narrows an emoji one.
      expect(firstGraphemeCellWidth([0x2764, 0xFE0F]), (length: 2, width: 2));
      expect(firstGraphemeCellWidth([0x231A, 0xFE0E]), (length: 2, width: 1));
    });

    test('combining marks and lone marks', () {
      expect(firstGraphemeCellWidth([0x65, 0x301]), (length: 2, width: 1));
      expect(firstGraphemeCellWidth([0x301]).length, 1);
    });

    test('arguments at the uint32 and start edges', () {
      expect(firstGraphemeCellWidth([0xFFFFFFFF]), (length: 1, width: 1));
      // An invalid codepoint before start is not validated or read.
      expect(firstGraphemeCellWidth([-1, 0x41], start: 1), (
        length: 1,
        width: 1,
      ));
    });
  });

  group('graphemeClusters / textCellWidth (review)', () {
    test('clusters rebuild the source exactly', () {
      const text = 'a👍🏽é日\u{1F1EA}\u{1F1F8}x\uD800z👨‍👩‍👧';
      final clusters = graphemeClusters(text);
      expect(clusters.map((c) => c.text).join(), text);
      for (final cluster in clusters) {
        expect(
          text.substring(cluster.start, cluster.start + cluster.text.length),
          cluster.text,
        );
      }
      expect(
        textCellWidth(text),
        clusters.fold<int>(0, (sum, c) => sum + c.width),
      );
    });

    test('empty text with mode 2027 off', () {
      expect(textCellWidth('', graphemeClustering: false), 0);
    });

    test('large text', () {
      final text = '日a👍🏽' * 50000;
      expect(textCellWidth(text), 5 * 50000);
      expect(graphemeClusters(text), hasLength(3 * 50000));
    });
  });
}
