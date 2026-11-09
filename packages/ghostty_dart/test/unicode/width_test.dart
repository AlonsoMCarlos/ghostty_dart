import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

/// The cursor column after printing [text] on a fresh terminal.
int _printedWidth(String text, {required bool graphemeClustering}) =>
    withTerminal(80, 4, (terminal) {
      writeText(terminal, '\x1b[?2027${graphemeClustering ? 'h' : 'l'}$text');
      return terminalDataUint16(
        terminal,
        GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_CURSOR_X,
      );
    });

void main() {
  group('codepointCellWidth', () {
    test('follows the width table', () {
      expect(codepointCellWidth(0x41), 1); // A
      expect(codepointCellWidth(0x1F600), 2); // 😀
      expect(codepointCellWidth(0x65E5), 2); // 日
      expect(codepointCellWidth(0x0301), 0); // combining acute
      expect(codepointCellWidth(0x200D), 0); // ZWJ
      expect(codepointCellWidth(0x07), 0); // BEL
      expect(codepointCellWidth(0xD800), 0); // surrogate
      expect(codepointCellWidth(0x1F1E6), 2); // regional indicator
      expect(codepointCellWidth(0x2E3B), 2); // three-em dash, clamped
    });

    test('is total beyond U+10FFFF', () {
      expect(codepointCellWidth(0x110000), 1);
      expect(codepointCellWidth(0xFFFFFFFF), 1);
    });

    test('rejects values that do not fit uint32_t', () {
      expect(() => codepointCellWidth(-1), throwsRangeError);
      expect(() => codepointCellWidth(0x100000000), throwsRangeError);
    });
  });

  group('textCellWidth', () {
    test('sums grapheme clusters by default (mode 2027)', () {
      expect(textCellWidth(''), 0);
      expect(textCellWidth('hello'), 5);
      expect(textCellWidth('日本語'), 6);
      expect(textCellWidth('é'), 1);
      expect(textCellWidth('👍🏽'), 2);
      expect(textCellWidth('👨‍👩‍👧'), 2);
      expect(textCellWidth('❤️'), 2); // ❤️ VS16 widens
    });

    test('sums codepoints without grapheme clustering', () {
      expect(textCellWidth('👍🏽', graphemeClustering: false), 4);
      expect(textCellWidth('❤️', graphemeClustering: false), 1);
      expect(textCellWidth('日本', graphemeClustering: false), 4);
    });

    test('handles long text in one pass', () {
      expect(textCellWidth('a' * 100000), 100000);
      expect(textCellWidth('日' * 300000), 600000);
    });
  });

  group('graphemeClusters', () {
    test('covers the text in order with UTF-16 offsets', () {
      const text = 'a👍🏽é日';
      final clusters = graphemeClusters(text);
      expect(clusters, const [
        GraphemeCluster(text: 'a', start: 0, width: 1),
        GraphemeCluster(text: '👍🏽', start: 1, width: 2),
        GraphemeCluster(text: 'é', start: 5, width: 1),
        GraphemeCluster(text: '日', start: 7, width: 2),
      ]);
      expect(clusters.map((c) => c.text).join(), text);
      for (final cluster in clusters) {
        expect(
          text.substring(cluster.start, cluster.start + cluster.text.length),
          cluster.text,
        );
      }
    });

    test('empty text has no clusters', () {
      expect(graphemeClusters(''), isEmpty);
    });

    test('keeps lone surrogates as one unit', () {
      final clusters = graphemeClusters('a\uD800b');
      expect(clusters.map((c) => c.text).join(), 'a\uD800b');
      expect(clusters.last.start + clusters.last.text.length, 3);
    });

    test('value semantics', () {
      const a = GraphemeCluster(text: 'x', start: 0, width: 1);
      expect(a, const GraphemeCluster(text: 'x', start: 0, width: 1));
      expect(
        a.hashCode,
        const GraphemeCluster(text: 'x', start: 0, width: 1).hashCode,
      );
      expect(a, isNot(const GraphemeCluster(text: 'x', start: 1, width: 1)));
      expect('$a', contains('width: 1'));
    });
  });

  group('firstGraphemeCellWidth', () {
    test('measures the first cluster', () {
      expect(firstGraphemeCellWidth('👍🏽a'.runes.toList()), (
        length: 2,
        width: 2,
      ));
      expect(firstGraphemeCellWidth([0x41, 0x42]), (length: 1, width: 1));
    });

    test('starts at an offset', () {
      final cps = 'aé'.runes.toList();
      expect(firstGraphemeCellWidth(cps, start: 1), (length: 2, width: 1));
    });

    test('returns zero length at the end', () {
      expect(firstGraphemeCellWidth(const []), (length: 0, width: 0));
      expect(firstGraphemeCellWidth([0x41], start: 1), (length: 0, width: 0));
    });

    test('beyond U+10FFFF is a one-codepoint cluster of width 1', () {
      expect(firstGraphemeCellWidth([0x110000, 0x0301]), (length: 1, width: 1));
    });

    test('validates arguments', () {
      expect(() => firstGraphemeCellWidth([0x41], start: 2), throwsRangeError);
      expect(() => firstGraphemeCellWidth([0x41], start: -1), throwsRangeError);
      expect(() => firstGraphemeCellWidth([-1]), throwsRangeError);
      expect(() => firstGraphemeCellWidth([0x100000000]), throwsRangeError);
    });
  });

  test('predicts where the terminal puts the cursor', () {
    for (final text in [
      'abc',
      '日本語',
      'e\u0301x',
      '👍🏽',
      '👨‍👩‍👧',
      '\u2764\uFE0F',
    ]) {
      for (final clustering in [true, false]) {
        expect(
          textCellWidth(text, graphemeClustering: clustering),
          _printedWidth(text, graphemeClustering: clustering),
          reason: '$text, mode 2027 ${clustering ? 'on' : 'off'}',
        );
      }
    }
  });
}
