import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/expect_support.dart';

/// The encoded bytes as a readable string (`ESC` for 0x1b).

void main() {
  group('focus', () {
    test('gained is CSI I and lost is CSI O', () {
      expect(showEscapes(encodeFocusEvent(VtFocusEvent.gained)), 'ESC[I');
      expect(showEscapes(encodeFocusEvent(VtFocusEvent.lost)), 'ESC[O');
    });

    test('unknown is rejected', () {
      expect(() => encodeFocusEvent(VtFocusEvent.unknown), throwsArgumentError);
    });
  });

  group('paste safety', () {
    test('plain and empty text is safe', () {
      expect(isPasteSafe(''), isTrue);
      expect(isPasteSafe('ls -la'), isTrue);
      expect(isPasteSafe('héllo 🌍\t'), isTrue);
    });

    test('line terminators and the bracketed end marker are unsafe', () {
      expect(isPasteSafe('rm -rf ~\n'), isFalse);
      expect(isPasteSafe('a\rb'), isFalse);
      expect(isPasteSafe('x\x1b[201~y'), isFalse);
    });
  });

  group('paste encoding', () {
    test('bracketed paste wraps the text', () {
      expect(
        showEscapes(encodePaste('echo hi', bracketed: true)),
        'ESC[200~echo hiESC[201~',
      );
    });

    test('unbracketed paste turns newlines into carriage returns', () {
      expect(encodePaste('a\nb', bracketed: false), utf8.encode('a\rb'));
    });

    test('unsafe control bytes become spaces', () {
      expect(
        showEscapes(encodePaste('a\x1bb\x00c', bracketed: false)),
        'a b c',
      );
      expect(
        showEscapes(encodePaste('x\x1b[201~y', bracketed: true)),
        'ESC[200~x [201~yESC[201~',
      );
    });

    test('empty input', () {
      expect(encodePaste('', bracketed: false), isEmpty);
      expect(showEscapes(encodePaste('', bracketed: true)), 'ESC[200~ESC[201~');
    });

    test('non-ASCII text survives unchanged', () {
      expect(
        encodePaste('ñandú 🌍', bracketed: false),
        utf8.encode('ñandú 🌍'),
      );
    });

    test('large input', () {
      final text = 'abcdefghij' * 10000;
      final bytes = encodePaste(text, bracketed: true);
      expect(bytes.length, text.length + 12);
      expect(utf8.decode(bytes.sublist(6, bytes.length - 6)), text);
    });
  });

  group('size reports', () {
    const size = SizeReportSize(
      rows: 24,
      columns: 80,
      cellWidth: 9,
      cellHeight: 18,
    );

    test('every style', () {
      expect(
        showEscapes(encodeSizeReport(SizeReportStyle.mode2048, size)),
        'ESC[48;24;80;432;720t',
      );
      expect(
        showEscapes(encodeSizeReport(SizeReportStyle.csi14t, size)),
        'ESC[4;432;720t',
      );
      expect(
        showEscapes(encodeSizeReport(SizeReportStyle.csi16t, size)),
        'ESC[6;18;9t',
      );
      expect(
        showEscapes(encodeSizeReport(SizeReportStyle.csi18t, size)),
        'ESC[8;24;80t',
      );
      expect(
        showEscapes(encodeSizeReport(SizeReportStyle.csi19t, size)),
        'ESC[9;24;80t',
      );
    });

    test('limits', () {
      const max = SizeReportSize(
        rows: 0xFFFF,
        columns: 0xFFFF,
        cellWidth: 0xFFFFFFFF,
        cellHeight: 0xFFFFFFFF,
      );
      expect(
        showEscapes(encodeSizeReport(SizeReportStyle.csi16t, max)),
        'ESC[6;4294967295;4294967295t',
      );
      expect(
        () => encodeSizeReport(
          SizeReportStyle.csi18t,
          const SizeReportSize(
            rows: 0x10000,
            columns: 1,
            cellWidth: 1,
            cellHeight: 1,
          ),
        ),
        throwsRangeError,
      );
      expect(
        () => encodeSizeReport(
          SizeReportStyle.csi18t,
          const SizeReportSize(
            rows: 1,
            columns: 1,
            cellWidth: -1,
            cellHeight: 1,
          ),
        ),
        throwsRangeError,
      );
      expect(
        () => encodeSizeReport(SizeReportStyle.unknown, size),
        throwsArgumentError,
      );
    });
  });

  group('mode reports', () {
    test('DEC and ANSI modes', () {
      expect(
        showEscapes(
          encodeModeReport(TerminalMode.cursorKeys, ModeReportState.set),
        ),
        r'ESC[?1;1$y',
      );
      expect(
        showEscapes(
          encodeModeReport(TerminalMode.insert, ModeReportState.reset),
        ),
        r'ESC[4;2$y',
      );
      expect(
        showEscapes(
          encodeModeReport(
            TerminalMode.bracketedPaste,
            ModeReportState.permanentlyReset,
          ),
        ),
        r'ESC[?2004;4$y',
      );
      expect(
        showEscapes(
          encodeModeReport(
            const TerminalMode.dec(9999),
            ModeReportState.notRecognized,
          ),
        ),
        r'ESC[?9999;0$y',
      );
    });

    test('unknown state is rejected', () {
      expect(
        () => encodeModeReport(TerminalMode.insert, ModeReportState.unknown),
        throwsArgumentError,
      );
    });
  });

  group('colour scheme reports', () {
    test('dark and light', () {
      expect(
        showEscapes(encodeColorSchemeReport(VtColorScheme.dark)),
        'ESC[?997;1n',
      );
      expect(
        showEscapes(encodeColorSchemeReport(VtColorScheme.light)),
        'ESC[?997;2n',
      );
    });

    test('unknown is rejected', () {
      expect(
        () => encodeColorSchemeReport(VtColorScheme.unknown),
        throwsArgumentError,
      );
    });
  });
}
