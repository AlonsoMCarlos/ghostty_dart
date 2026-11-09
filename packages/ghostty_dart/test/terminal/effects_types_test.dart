// Effect enum codecs against the bindings constants, and the effect value
// types.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/terminal/effects_types.dart';
import 'package:test/test.dart';

import '../support/expect_support.dart';

typedef _Write = GhosttyClipboardWriteResult;
typedef _Read = GhosttyClipboardReadResult;
typedef _Progress = GhosttyTerminalProgressState;
typedef _State = GhosttyProgramStatusState;
typedef _Kind = GhosttyProgramStatusKind;
typedef _Prompt = GhosttySemanticPromptKind;
typedef _PromptKind = GhosttySemanticPromptPromptKind;

/// Checks that [codec] maps exactly [expected] (member -> raw constant) and
/// sends every other value to [unknown]. Copied from
/// test/core/enum_codec_test.dart, as contratos.md §3 asks.

void main() {
  group('codecs match the bindings', () {
    test('ClipboardWriteResult', () {
      expectCodec(
        clipboardWriteResultCodec,
        ClipboardWriteResult.values,
        ClipboardWriteResult.unknown,
        {
          ClipboardWriteResult.success:
              _Write.GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS,
          ClipboardWriteResult.denied:
              _Write.GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED,
          ClipboardWriteResult.unsupported:
              _Write.GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED,
          ClipboardWriteResult.busy: _Write.GHOSTTY_CLIPBOARD_WRITE_RESULT_BUSY,
          ClipboardWriteResult.invalidData:
              _Write.GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA,
          ClipboardWriteResult.ioError:
              _Write.GHOSTTY_CLIPBOARD_WRITE_RESULT_IO_ERROR,
        },
      );
    });

    test('ClipboardReadResult', () {
      expectCodec(
        clipboardReadResultCodec,
        ClipboardReadResult.values,
        ClipboardReadResult.unknown,
        {
          ClipboardReadResult.success:
              _Read.GHOSTTY_CLIPBOARD_READ_RESULT_SUCCESS,
          ClipboardReadResult.denied:
              _Read.GHOSTTY_CLIPBOARD_READ_RESULT_DENIED,
          ClipboardReadResult.unsupported:
              _Read.GHOSTTY_CLIPBOARD_READ_RESULT_UNSUPPORTED,
          ClipboardReadResult.busy: _Read.GHOSTTY_CLIPBOARD_READ_RESULT_BUSY,
          ClipboardReadResult.ioError:
              _Read.GHOSTTY_CLIPBOARD_READ_RESULT_IO_ERROR,
        },
      );
    });

    test('ProgressState', () {
      expectCodec(
        progressStateCodec,
        ProgressState.values,
        ProgressState.unknown,
        {
          ProgressState.remove:
              _Progress.GHOSTTY_TERMINAL_PROGRESS_STATE_REMOVE,
          ProgressState.set: _Progress.GHOSTTY_TERMINAL_PROGRESS_STATE_SET,
          ProgressState.error: _Progress.GHOSTTY_TERMINAL_PROGRESS_STATE_ERROR,
          ProgressState.indeterminate:
              _Progress.GHOSTTY_TERMINAL_PROGRESS_STATE_INDETERMINATE,
          ProgressState.pause: _Progress.GHOSTTY_TERMINAL_PROGRESS_STATE_PAUSE,
        },
      );
    });

    test('ProgramStatusState', () {
      expectCodec(
        programStatusStateCodec,
        ProgramStatusState.values,
        ProgramStatusState.unknown,
        {
          ProgramStatusState.idle: _State.GHOSTTY_PROGRAM_STATUS_STATE_IDLE,
          ProgramStatusState.working:
              _State.GHOSTTY_PROGRAM_STATUS_STATE_WORKING,
          ProgramStatusState.done: _State.GHOSTTY_PROGRAM_STATUS_STATE_DONE,
          ProgramStatusState.blocked:
              _State.GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED,
          ProgramStatusState.error: _State.GHOSTTY_PROGRAM_STATUS_STATE_ERROR,
          ProgramStatusState.clear: _State.GHOSTTY_PROGRAM_STATUS_STATE_CLEAR,
        },
      );
    });

    test('ProgramStatusKind', () {
      expectCodec(
        programStatusKindCodec,
        ProgramStatusKind.values,
        ProgramStatusKind.unknown,
        {
          ProgramStatusKind.none: _Kind.GHOSTTY_PROGRAM_STATUS_KIND_NONE,
          ProgramStatusKind.permission:
              _Kind.GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION,
          ProgramStatusKind.question:
              _Kind.GHOSTTY_PROGRAM_STATUS_KIND_QUESTION,
          ProgramStatusKind.auth: _Kind.GHOSTTY_PROGRAM_STATUS_KIND_AUTH,
        },
      );
    });

    test('SemanticPromptKind (INVALID decodes to unknown)', () {
      expectCodec(
        semanticPromptKindCodec,
        SemanticPromptKind.values,
        SemanticPromptKind.unknown,
        {
          SemanticPromptKind.promptStart:
              _Prompt.GHOSTTY_SEMANTIC_PROMPT_PROMPT_START,
          SemanticPromptKind.inputStart:
              _Prompt.GHOSTTY_SEMANTIC_PROMPT_INPUT_START,
          SemanticPromptKind.outputStart:
              _Prompt.GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START,
          SemanticPromptKind.commandEnd:
              _Prompt.GHOSTTY_SEMANTIC_PROMPT_COMMAND_END,
        },
      );
      expect(
        semanticPromptKindCodec.decode(_Prompt.GHOSTTY_SEMANTIC_PROMPT_INVALID),
        SemanticPromptKind.unknown,
      );
    });

    test('PromptKind', () {
      expectCodec(promptKindCodec, PromptKind.values, PromptKind.unknown, {
        PromptKind.primary: _PromptKind.GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY,
        PromptKind.right: _PromptKind.GHOSTTY_SEMANTIC_PROMPT_PROMPT_RIGHT,
        PromptKind.continuation:
            _PromptKind.GHOSTTY_SEMANTIC_PROMPT_PROMPT_CONTINUATION,
        PromptKind.secondary:
            _PromptKind.GHOSTTY_SEMANTIC_PROMPT_PROMPT_SECONDARY,
      });
    });
  });

  group('value types', () {
    test('ClipboardContent compares bytes and decodes text', () {
      final a = ClipboardContent.text('héllo');
      final b = ClipboardContent('text/plain', utf8.encode('héllo'));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.text, 'héllo');
      expect(a, isNot(ClipboardContent('text/html', utf8.encode('héllo'))));
      expect(
        ClipboardContent('x', Uint8List.fromList([0xff])).text,
        '\u{FFFD}',
      );
    });

    test('requests and replies have value equality', () {
      const request = ClipboardWriteRequest(
        location: ClipboardLocation.standard,
        contents: [],
      );
      expect(request.isClear, isTrue);
      expect(
        request,
        const ClipboardWriteRequest(
          location: ClipboardLocation.standard,
          contents: [],
        ),
      );
      expect(
        ClipboardReadReply.text('a'),
        ClipboardReadReply(contents: [ClipboardContent.text('a')]),
      );
      expect(ClipboardReadReply.denied.result, ClipboardReadResult.denied);
      expect(
        ClipboardWriteReply.success,
        const ClipboardWriteReply(ClipboardWriteResult.success),
      );
      expect(
        const ClipboardWriteReply(ClipboardWriteResult.success, remember: true),
        isNot(ClipboardWriteReply.success),
      );
    });

    test('DeviceAttributes defaults are the library defaults', () {
      const attributes = DeviceAttributes();
      expect(attributes.conformanceLevel, 62);
      expect(attributes.features, [22]);
      expect(attributes.deviceType, 1);
      expect(
        attributes,
        const DeviceAttributes(features: [DeviceAttributes.featureAnsiColor]),
      );
      expect(attributes, isNot(const DeviceAttributes(features: [22, 52])));
    });

    test('unknown sequences compare by kind and content', () {
      final osc = UnknownOscSequence(utf8.encode('7400;x'));
      expect(osc, UnknownOscSequence(utf8.encode('7400;x')));
      expect(osc, isNot(UnknownApcSequence(utf8.encode('7400;x'))));
      expect(
        osc,
        isNot(
          UnknownOscSequence(
            utf8.encode('7400;x'),
            terminator: OscTerminator.bel,
          ),
        ),
      );
      expect(osc.text, '7400;x');
    });
  });
}
