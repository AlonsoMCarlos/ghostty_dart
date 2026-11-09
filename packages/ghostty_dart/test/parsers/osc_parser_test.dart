import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/parsers/osc_command.dart'
    show oscCommandTypeCodec, oscTerminatorCodec;
import 'package:test/test.dart';

import '../support/expect_support.dart';

Uint8List _bytes(String text) => utf8.encode(text);

/// Checks that [codec] maps exactly [expected] (member -> raw constant) and
/// sends every other value to [unknown]. Copied from enum_codec_test.dart.

void main() {
  late OscParser parser;
  setUp(() => parser = OscParser());
  tearDown(() => parser.dispose());

  group('window title', () {
    test('OSC 0 and OSC 2', () {
      expect(
        parser.parse(_bytes('0;hello')),
        const OscWindowTitleCommand('hello'),
      );
      expect(
        parser.parse(_bytes('2;wörld 🌍'), terminator: OscTerminator.bel),
        const OscWindowTitleCommand('wörld 🌍'),
      );
      expect(parser.parse(_bytes('2;')), const OscWindowTitleCommand(''));
    });

    test('malformed UTF-8 becomes U+FFFD', () {
      final command = parser.parse(
        Uint8List.fromList([..._bytes('2;a'), 0xff, ..._bytes('b')]),
      );
      expect(command, const OscWindowTitleCommand('a�b'));
    });

    test('arrives in pieces', () {
      parser
        ..add(_bytes('2;he'))
        ..addByte(0x6c)
        ..add(Uint8List(0))
        ..add(_bytes('lo'));
      expect(parser.end(), const OscWindowTitleCommand('hello'));
    });

    test('end resets for the next sequence', () {
      parser.add(_bytes('2;first'));
      expect(parser.end(), const OscWindowTitleCommand('first'));
      parser.add(_bytes('2;second'));
      expect(parser.end(), const OscWindowTitleCommand('second'));
    });
  });

  test('other recognised commands carry only their type', () {
    final cases = {
      '1;icon': OscCommandType.changeWindowIcon,
      '7;file:///tmp': OscCommandType.reportPwd,
      '8;;https://example.com': OscCommandType.hyperlinkStart,
      '8;;': OscCommandType.hyperlinkEnd,
      '52;c;aGk=': OscCommandType.clipboardContents,
      '4;1;?': OscCommandType.colorOperation,
      '22;pointer': OscCommandType.mouseShape,
      '133;A': OscCommandType.semanticPrompt,
      '9;hi': OscCommandType.showDesktopNotification,
    };
    cases.forEach((input, type) {
      expect(parser.parse(_bytes(input)), OscOtherCommand(type), reason: input);
    });
  });

  group('invalid and cancelled sequences', () {
    test('return null', () {
      expect(parser.parse(Uint8List(0)), isNull);
      expect(parser.parse(_bytes('garbage')), isNull);
      expect(parser.parse(_bytes('7400;status=busy')), isNull);
    });

    test('reset discards a partial sequence', () {
      parser
        ..add(_bytes('2;stale'))
        ..reset()
        ..add(_bytes('2;fresh'));
      expect(parser.end(), const OscWindowTitleCommand('fresh'));
    });

    test('parse discards an earlier partial sequence', () {
      parser.add(_bytes('2;stale'));
      expect(
        parser.parse(_bytes('2;fresh')),
        const OscWindowTitleCommand('fresh'),
      );
    });

    test('the unknown terminator is rejected', () {
      parser.add(_bytes('2;x'));
      expect(
        () => parser.end(terminator: OscTerminator.unknown),
        throwsArgumentError,
      );
    });
  });

  group('unimplemented sequences', () {
    test('are kept when unknownMaxBytes > 0', () {
      final local = OscParser(unknownMaxBytes: 1024);
      addTearDown(local.dispose);
      expect(local.unknownMaxBytes, 1024);
      final command = local.parse(
        _bytes('7400;status=busy'),
        terminator: OscTerminator.bel,
      );
      expect(
        command,
        OscUnimplementedCommand(
          content: _bytes('7400;status=busy'),
          isTruncated: false,
          terminator: OscTerminator.bel,
        ),
      );
      command as OscUnimplementedCommand;
      expect(command.type, OscCommandType.unimplemented);
      expect(command.text, '7400;status=busy');
      expect(
        local.parse(_bytes('7400;x')),
        isA<OscUnimplementedCommand>().having(
          (c) => c.terminator,
          'terminator',
          OscTerminator.st,
        ),
      );
    });

    test('are truncated to the limit', () {
      parser.unknownMaxBytes = 4;
      final command = parser.parse(_bytes('7400;status=busy'));
      expect(command, isA<OscUnimplementedCommand>());
      command as OscUnimplementedCommand;
      expect(command.isTruncated, isTrue);
      expect(command.content, _bytes('7400'));
    });

    test('limits above 2048 work', () {
      parser.unknownMaxBytes = 1 << 16;
      final body = '7400;${'x' * 10000}';
      final command = parser.parse(_bytes(body)) as OscUnimplementedCommand;
      expect(command.text, body);
      expect(command.isTruncated, isFalse);
    });

    test('setting 0 discards them again', () {
      parser.unknownMaxBytes = 16;
      expect(parser.parse(_bytes('7400;a')), isA<OscUnimplementedCommand>());
      parser.unknownMaxBytes = 0;
      expect(parser.unknownMaxBytes, 0);
      expect(parser.parse(_bytes('7400;a')), isNull);
    });

    test('the option survives reset', () {
      parser.unknownMaxBytes = 16;
      parser.reset();
      expect(parser.parse(_bytes('7400;a')), isA<OscUnimplementedCommand>());
    });
  });

  group('arguments', () {
    test('addByte validates the range', () {
      expect(() => parser.addByte(-1), throwsRangeError);
      expect(() => parser.addByte(256), throwsRangeError);
    });

    test('unknownMaxBytes rejects negative values', () {
      expect(() => parser.unknownMaxBytes = -1, throwsRangeError);
      expect(() => OscParser(unknownMaxBytes: -1), throwsRangeError);
    });
  });

  group('value semantics', () {
    test('commands compare by value', () {
      expect(
        const OscWindowTitleCommand('a').hashCode,
        const OscWindowTitleCommand('a').hashCode,
      );
      expect(
        const OscWindowTitleCommand('a'),
        isNot(const OscWindowTitleCommand('b')),
      );
      expect(
        const OscOtherCommand(OscCommandType.reportPwd),
        isNot(const OscOtherCommand(OscCommandType.mouseShape)),
      );
      final a = OscUnimplementedCommand(
        content: _bytes('1'),
        isTruncated: false,
        terminator: OscTerminator.st,
      );
      final b = OscUnimplementedCommand(
        content: _bytes('1'),
        isTruncated: false,
        terminator: OscTerminator.st,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          OscUnimplementedCommand(
            content: _bytes('1'),
            isTruncated: true,
            terminator: OscTerminator.st,
          ),
        ),
      );
    });

    test('unimplemented content is copied from the argument', () {
      final source = _bytes('1');
      final command = OscUnimplementedCommand(
        content: source,
        isTruncated: false,
        terminator: OscTerminator.st,
      );
      source[0] = 0x32;
      expect(command.text, '1');
    });
  });

  group('ownership', () {
    test('dispose is idempotent and blocks use', () {
      final local = OscParser();
      local.dispose();
      local.dispose();
      expect(local.isDisposed, isTrue);
      for (final use in <void Function()>[
        () => local.add(_bytes('x')),
        () => local.addByte(1),
        () => local.end(),
        () => local.reset(),
        () => local.parse(_bytes('2;x')),
        () => local.unknownMaxBytes,
        () => local.unknownMaxBytes = 1,
      ]) {
        expect(
          use,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'OscParser has been disposed',
            ),
          ),
        );
      }
    });
  });

  group('codecs match the C enums', () {
    test('OscCommandType', () {
      expectCodec(
        oscCommandTypeCodec,
        OscCommandType.values,
        OscCommandType.unknown,
        {
          OscCommandType.changeWindowTitle:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE,
          OscCommandType.changeWindowIcon:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_ICON,
          OscCommandType.semanticPrompt:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_SEMANTIC_PROMPT,
          OscCommandType.clipboardContents:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CLIPBOARD_CONTENTS,
          OscCommandType.reportPwd:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_REPORT_PWD,
          OscCommandType.mouseShape:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_MOUSE_SHAPE,
          OscCommandType.colorOperation:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_COLOR_OPERATION,
          OscCommandType.kittyColorProtocol:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_KITTY_COLOR_PROTOCOL,
          OscCommandType.showDesktopNotification: GhosttyOscCommandType
              .GHOSTTY_OSC_COMMAND_SHOW_DESKTOP_NOTIFICATION,
          OscCommandType.hyperlinkStart:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_HYPERLINK_START,
          OscCommandType.hyperlinkEnd:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_HYPERLINK_END,
          OscCommandType.conemuSleep:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_SLEEP,
          OscCommandType.conemuShowMessageBox:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_SHOW_MESSAGE_BOX,
          OscCommandType.conemuChangeTabTitle:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_CHANGE_TAB_TITLE,
          OscCommandType.conemuProgressReport:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_PROGRESS_REPORT,
          OscCommandType.conemuWaitInput:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_WAIT_INPUT,
          OscCommandType.conemuGuimacro:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_GUIMACRO,
          OscCommandType.conemuRunProcess:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_RUN_PROCESS,
          OscCommandType.conemuOutputEnvironmentVariable: GhosttyOscCommandType
              .GHOSTTY_OSC_COMMAND_CONEMU_OUTPUT_ENVIRONMENT_VARIABLE,
          OscCommandType.conemuXtermEmulation:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_XTERM_EMULATION,
          OscCommandType.conemuComment:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_COMMENT,
          OscCommandType.kittyTextSizing:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_KITTY_TEXT_SIZING,
          OscCommandType.kittyClipboardProtocol: GhosttyOscCommandType
              .GHOSTTY_OSC_COMMAND_KITTY_CLIPBOARD_PROTOCOL,
          OscCommandType.kittyDndProtocol:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_KITTY_DND_PROTOCOL,
          OscCommandType.hierarchicalContext:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_HIERARCHICAL_CONTEXT,
          OscCommandType.kittyDesktopNotification: GhosttyOscCommandType
              .GHOSTTY_OSC_COMMAND_KITTY_DESKTOP_NOTIFICATION,
          OscCommandType.unimplemented:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_UNKNOWN,
          OscCommandType.programStatus:
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_PROGRAM_STATUS,
        },
      );
      expect(
        oscCommandTypeCodec.decode(
          GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID,
        ),
        OscCommandType.unknown,
      );
    });

    test('OscTerminator', () {
      expectCodec(
        oscTerminatorCodec,
        OscTerminator.values,
        OscTerminator.unknown,
        {
          OscTerminator.st: GhosttyOscTerminator.GHOSTTY_OSC_TERMINATOR_ST,
          OscTerminator.bel: GhosttyOscTerminator.GHOSTTY_OSC_TERMINATOR_BEL,
        },
      );
    });
  });
}
