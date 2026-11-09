import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

void main() {
  late SgrParser parser;
  setUp(() => parser = SgrParser());
  tearDown(() => parser.dispose());

  group('parse', () {
    test('flags', () {
      expect(parser.parse([1, 2, 3, 5, 6, 7, 8, 9, 53]), const [
        SgrFlag(SgrFlagKind.bold),
        SgrFlag(SgrFlagKind.faint),
        SgrFlag(SgrFlagKind.italic),
        SgrFlag(SgrFlagKind.blink),
        SgrFlag(SgrFlagKind.blink),
        SgrFlag(SgrFlagKind.inverse),
        SgrFlag(SgrFlagKind.invisible),
        SgrFlag(SgrFlagKind.strikethrough),
        SgrFlag(SgrFlagKind.overline),
      ]);
      expect(parser.parse([22, 23, 25, 27, 28, 29, 55]), const [
        SgrFlag(SgrFlagKind.resetBold),
        SgrFlag(SgrFlagKind.resetItalic),
        SgrFlag(SgrFlagKind.resetBlink),
        SgrFlag(SgrFlagKind.resetInverse),
        SgrFlag(SgrFlagKind.resetInvisible),
        SgrFlag(SgrFlagKind.resetStrikethrough),
        SgrFlag(SgrFlagKind.resetOverline),
      ]);
    });

    test('reset: SGR 0 and the empty list', () {
      expect(parser.parse([0]), const [SgrReset()]);
      expect(parser.parse(const []), const [SgrReset()]);
    });

    test('8, bright, 256 and direct colours', () {
      expect(parser.parse([31, 42, 97, 107, 39, 49]), const [
        SgrForeground(PaletteColor.red, SgrColorForm.standard),
        SgrBackground(PaletteColor.green, SgrColorForm.standard),
        SgrForeground(PaletteColor.brightWhite, SgrColorForm.bright),
        SgrBackground(PaletteColor.brightWhite, SgrColorForm.bright),
        SgrForeground(DefaultColor(), SgrColorForm.reset),
        SgrBackground(DefaultColor(), SgrColorForm.reset),
      ]);
      expect(parser.parse([38, 5, 196, 48, 2, 1, 2, 3]), const [
        SgrForeground(PaletteColor(196), SgrColorForm.indexed),
        SgrBackground(RgbColor(1, 2, 3), SgrColorForm.direct),
      ]);
    });

    test('underline styles and colours', () {
      expect(parser.parse([4, 21, 24, 58, 5, 9, 58, 2, 4, 5, 6, 59]), const [
        SgrUnderline(UnderlineStyle.single),
        SgrUnderline(UnderlineStyle.double),
        SgrUnderline(UnderlineStyle.none),
        SgrUnderlineColor(PaletteColor(9), SgrColorForm.indexed),
        SgrUnderlineColor(RgbColor(4, 5, 6), SgrColorForm.direct),
        SgrUnderlineColor(DefaultColor(), SgrColorForm.reset),
      ]);
    });

    test('a separator is the one after its parameter', () {
      const colon = SgrSeparator.colon;
      const semi = SgrSeparator.semicolon;
      expect(parser.parse([4, 3], separators: const [colon, semi]), const [
        SgrUnderline(UnderlineStyle.curly),
      ]);
      // Without the colon, 4;3 is underline then italic.
      expect(parser.parse([4, 3], separators: const [semi, semi]), const [
        SgrUnderline(UnderlineStyle.single),
        SgrFlag(SgrFlagKind.italic),
      ]);
    });

    test('unknown attributes are reported and parsing continues', () {
      final attributes = parser.parse([1, 99, 3]);
      expect(attributes, [
        const SgrFlag(SgrFlagKind.bold),
        SgrUnrecognized(
          parameters: const [99, 3],
          allParameters: const [1, 99, 3],
        ),
        const SgrFlag(SgrFlagKind.italic),
      ]);
    });

    test('unknown colon sub-parameters are grouped', () {
      final attributes = parser.parse(
        [1, 7, 2, 3],
        separators: const [
          SgrSeparator.semicolon,
          SgrSeparator.colon,
          SgrSeparator.colon,
          SgrSeparator.semicolon,
        ],
      );
      expect(attributes.first, const SgrFlag(SgrFlagKind.bold));
      final unknown = attributes[1] as SgrUnrecognized;
      expect(unknown.parameters, [7, 2, 3]);
      expect(unknown.allParameters, [1, 7, 2, 3]);
      expect(attributes, hasLength(2));
    });

    test('results are copies that outlive the parser', () {
      final attributes = parser.parse([99]);
      parser.parse([1, 2, 3]);
      parser.dispose();
      expect((attributes.single as SgrUnrecognized).allParameters, [99]);
      expect(
        () => (attributes.single as SgrUnrecognized).parameters.add(1),
        throwsUnsupportedError,
      );
    });

    test('a parser is reusable', () {
      for (var i = 0; i < 100; i++) {
        expect(parser.parse([1]), const [SgrFlag(SgrFlagKind.bold)]);
      }
    });

    test('validates arguments', () {
      expect(() => parser.parse([-1]), throwsRangeError);
      expect(() => parser.parse([0x10000]), throwsRangeError);
      expect(
        () => parser.parse([1, 2], separators: const [SgrSeparator.colon]),
        throwsArgumentError,
      );
      final params = List.filled(SgrParser.maxParametersWithColons + 1, 1);
      expect(
        () => parser.parse(
          params,
          separators: List.filled(params.length, SgrSeparator.colon),
        ),
        throwsArgumentError,
      );
      // Only semicolons: the limit does not apply.
      expect(
        parser.parse(
          params,
          separators: List.filled(params.length, SgrSeparator.semicolon),
        ),
        hasLength(params.length),
      );
    });
  });

  group('parseString', () {
    test('reads the text form', () {
      expect(parser.parseString('1;38:2::255:0:0'), const [
        SgrFlag(SgrFlagKind.bold),
        SgrForeground(RgbColor(255, 0, 0), SgrColorForm.direct),
      ]);
      expect(parser.parseString('4:3;58:5:200'), const [
        SgrUnderline(UnderlineStyle.curly),
        SgrUnderlineColor(PaletteColor(200), SgrColorForm.indexed),
      ]);
      expect(parser.parseString('38;2;1;2;3'), const [
        SgrForeground(RgbColor(1, 2, 3), SgrColorForm.direct),
      ]);
    });

    test('empty parameters are 0', () {
      expect(parser.parseString(''), const [SgrReset()]);
      expect(parser.parseString(';1'), const [
        SgrReset(),
        SgrFlag(SgrFlagKind.bold),
      ]);
      expect(parser.parseString('1;;2'), const [
        SgrFlag(SgrFlagKind.bold),
        SgrReset(),
        SgrFlag(SgrFlagKind.faint),
      ]);
    });

    test('rejects other characters and overflow', () {
      expect(() => parser.parseString('1m'), throwsFormatException);
      expect(() => parser.parseString('1 ;2'), throwsFormatException);
      expect(() => parser.parseString('65536'), throwsFormatException);
      expect(parser.parseString('65535'), hasLength(1));
    });
  });

  group('value semantics', () {
    test('colour attributes differ by slot and form', () {
      expect(
        const SgrForeground(PaletteColor.red, SgrColorForm.standard),
        isNot(const SgrBackground(PaletteColor.red, SgrColorForm.standard)),
      );
      expect(
        const SgrForeground(PaletteColor.red, SgrColorForm.standard),
        isNot(const SgrForeground(PaletteColor.red, SgrColorForm.indexed)),
      );
      expect(
        const SgrForeground(PaletteColor.red, SgrColorForm.standard).hashCode,
        const SgrForeground(PaletteColor(1), SgrColorForm.standard).hashCode,
      );
      expect(
        '${const SgrUnderlineColor(DefaultColor(), SgrColorForm.reset)}',
        'SgrUnderlineColor(DefaultColor(), reset)',
      );
    });

    test('unrecognized compares its lists', () {
      final a = SgrUnrecognized(parameters: [1], allParameters: [1, 2]);
      final b = SgrUnrecognized(parameters: [1], allParameters: [1, 2]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(SgrUnrecognized(parameters: [1], allParameters: [1])));
    });
  });

  group('ownership', () {
    test('dispose is idempotent and blocks use', () {
      final local = SgrParser();
      expect(local.isDisposed, isFalse);
      local.dispose();
      local.dispose();
      expect(local.isDisposed, isTrue);
      expect(
        () => local.parse([1]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'SgrParser has been disposed',
          ),
        ),
      );
      expect(() => local.parseString('1'), throwsStateError);
    });
  });
}
