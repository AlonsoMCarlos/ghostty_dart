// Adversarial tests from the correctness review of the standalone OSC and
// SGR parsers. Each group targets a header or upstream-source detail the
// implementation tests did not pin down.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

Uint8List _bytes(String text) => utf8.encode(text);

/// The pen style a real terminal ends up with after `ESC[0m ESC[<sgr>m`.
CellStyle _terminalPen(String sgr) => withTerminal(10, 2, (terminal) {
  writeText(terminal, '\x1b[0m\x1b[${sgr}m');
  return using((arena) {
    final style = arena<GhosttyStyle>();
    checkResult(
      ghostty_terminal_get(
        handleOf<GhosttyTerminalImpl>(terminal).pointer,
        GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_CURSOR_SGR_STYLE,
        style.cast(),
      ),
      'ghostty_terminal_get',
    );
    return cellStyleFromNative(style.ref);
  });
});

void main() {
  group('SgrParser (review)', () {
    late SgrParser parser;
    setUp(() => parser = SgrParser());
    tearDown(() => parser.dispose());

    // Regression: parseString('1;') used to give [bold, reset]; the
    // terminal's CSI parser drops an empty last parameter, so it is bold.
    test('parseString drops an empty last parameter, like the terminal', () {
      expect(parser.parseString('1;'), const [SgrFlag(SgrFlagKind.bold)]);
      expect(_terminalPen('1;').bold, isTrue);
      expect(parser.parseString(';'), const [SgrReset()]);
    });

    // Regression: a trailing colon used to become an extra 0 parameter.
    // The terminal keeps it as the separator after the last parameter.
    test('a trailing colon is the separator after the last parameter', () {
      expect(parser.parseString('4:'), [isA<SgrUnrecognized>()]);
      expect(
        _terminalPen('4:').underline,
        UnderlineStyle.none,
        reason: 'the terminal ignores ESC[4:m too',
      );
      final attributes = parser.parseString('4:3:');
      expect(attributes, hasLength(1));
      expect((attributes.single as SgrUnrecognized).allParameters, const [
        4,
        3,
      ]);
    });

    test('the last separator is not ignored', () {
      expect(parser.parse([4], separators: const [SgrSeparator.colon]), [
        isA<SgrUnrecognized>(),
      ]);
      expect(parser.parse([4], separators: const [SgrSeparator.semicolon]), [
        const SgrUnderline(UnderlineStyle.single),
      ]);
    });

    test('unknown semicolon parameters report the rest of the list', () {
      final attributes = parser.parse([99, 1]);
      expect(attributes, hasLength(2));
      final unknown = attributes.first as SgrUnrecognized;
      expect(unknown.parameters, const [99, 1]);
      expect(unknown.allParameters, const [99, 1]);
      expect(attributes.last, const SgrFlag(SgrFlagKind.bold));
    });

    test('SGR 0 anywhere in the list is a reset', () {
      expect(parser.parse([1, 0, 3]), const [
        SgrFlag(SgrFlagKind.bold),
        SgrReset(),
        SgrFlag(SgrFlagKind.italic),
      ]);
    });

    test('standard and bright colours use palette indices 0-15', () {
      expect(parser.parse([30, 37, 40, 47, 90, 97, 100, 107]), const [
        SgrForeground(PaletteColor(0), SgrColorForm.standard),
        SgrForeground(PaletteColor(7), SgrColorForm.standard),
        SgrBackground(PaletteColor(0), SgrColorForm.standard),
        SgrBackground(PaletteColor(7), SgrColorForm.standard),
        SgrForeground(PaletteColor(8), SgrColorForm.bright),
        SgrForeground(PaletteColor(15), SgrColorForm.bright),
        SgrBackground(PaletteColor(8), SgrColorForm.bright),
        SgrBackground(PaletteColor(15), SgrColorForm.bright),
      ]);
    });

    test('colour edge cases', () {
      // Colon form with the colour-space field present.
      expect(parser.parseString('48:2:0:1:2:3'), const [
        SgrBackground(RgbColor(1, 2, 3), SgrColorForm.direct),
      ]);
      // Too short for a direct colour.
      expect(parser.parse([38, 2, 1, 2]).first, isA<SgrUnrecognized>());
      // Index truncated to 8 bits by the library.
      expect(parser.parse([38, 5, 256 + 7]), const [
        SgrForeground(PaletteColor(7), SgrColorForm.indexed),
      ]);
      expect(parser.parse([59, 39, 49]), const [
        SgrUnderlineColor(DefaultColor(), SgrColorForm.reset),
        SgrForeground(DefaultColor(), SgrColorForm.reset),
        SgrBackground(DefaultColor(), SgrColorForm.reset),
      ]);
      // Unknown underline style falls back to single.
      expect(parser.parseString('4:9'), const [
        SgrUnderline(UnderlineStyle.single),
      ]);
    });

    test('the colon limit is exactly 24 parameters', () {
      final params = List.filled(24, 1);
      final separators = [
        SgrSeparator.colon,
        ...List.filled(23, SgrSeparator.semicolon),
      ];
      expect(
        () => parser.parse(params, separators: separators),
        returnsNormally,
      );
      expect(
        () => parser.parse(
          [...params, 1],
          separators: [...separators, SgrSeparator.semicolon],
        ),
        throwsArgumentError,
      );
    });

    test('long and empty inputs', () {
      final many = List.filled(10000, 1);
      expect(parser.parse(many), hasLength(10000));
      expect(parser.parse(const []), const [SgrReset()]);
      expect(parser.parse(const [], separators: const []), const [SgrReset()]);
    });

    test('invalid parameters', () {
      expect(
        () => parser.parse([1], separators: const []),
        throwsArgumentError,
      );
      expect(() => parser.parseString('١'), throwsFormatException);
    });
  });

  group('OscParser (review)', () {
    late OscParser parser;
    setUp(() => parser = OscParser());
    tearDown(() => parser.dispose());

    OscCommandType? typeOf(String text) => parser.parse(_bytes(text))?.type;

    // The plain OSC numbers are in osc_parser_test; these are the forms
    // that osc.zig and osc9.zig route to the same or a ConEmu type.
    test('command types match osc.zig and osc9.zig', () {
      expect(typeOf('777;notify;T;B'), OscCommandType.showDesktopNotification);
      // ConEmu OSC 9;n forms.
      expect(typeOf('9;1;100'), OscCommandType.conemuSleep);
      expect(typeOf('9;2;msg'), OscCommandType.conemuShowMessageBox);
      expect(typeOf('9;3;tab'), OscCommandType.conemuChangeTabTitle);
      expect(typeOf('9;4;1;50'), OscCommandType.conemuProgressReport);
      expect(typeOf('9;5'), OscCommandType.conemuWaitInput);
      expect(typeOf('9;6;m'), OscCommandType.conemuGuimacro);
      expect(typeOf('9;7;p'), OscCommandType.conemuRunProcess);
      expect(typeOf('9;8;v'), OscCommandType.conemuOutputEnvironmentVariable);
      expect(typeOf('9;9;/tmp'), OscCommandType.reportPwd);
      expect(typeOf('9;10'), OscCommandType.conemuXtermEmulation);
      expect(typeOf('9;11;c'), OscCommandType.conemuComment);
      expect(typeOf('9;12'), OscCommandType.semanticPrompt);
    });

    test('unimplemented content is copied before the parser resets', () {
      parser.unknownMaxBytes = 64;
      final first =
          parser.parse(_bytes('7400;first')) as OscUnimplementedCommand;
      // Reuse the parser so its capture buffer is overwritten.
      parser.parse(_bytes('7400;XXXXXXXXXXXXXXXX'));
      parser.add(_bytes('7400;partial'));
      expect(first.text, '7400;first');
      expect(first.isTruncated, isFalse);
      parser.dispose();
      expect(first.text, '7400;first');
    });

    test('titles edge cases', () {
      expect(
        parser.parse(_bytes('2;日本語 👍🏽')),
        const OscWindowTitleCommand('日本語 👍🏽'),
      );
      // A long title must not crash; if accepted, it is the full title.
      final long = 'x' * 100000;
      final command = parser.parse(_bytes('2;$long'));
      if (command != null) {
        expect((command as OscWindowTitleCommand).title, long);
      }
    });

    test('empty and garbage input', () {
      expect(parser.end(), isNull);
      expect(parser.parse(_bytes(';;;')), isNull);
      expect(parser.parse(Uint8List.fromList([0xFF, 0x00, 0x1B])), isNull);
      // Still usable afterwards.
      expect(parser.parse(_bytes('0;ok')), const OscWindowTitleCommand('ok'));
    });
  });
}
