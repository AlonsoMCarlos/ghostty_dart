// VtTerminalEffects: every terminal callback, triggered by the real
// sequence that fires it.

import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';
import 'pty_capture.dart';

void main() {
  group('replies', () {
    test('onWritePty receives device attributes and cursor reports', () {
      withTerminal(20, 5, (terminal) {
        final chunks = <List<int>>[];
        terminal.onWritePty = chunks.add;
        writeText(terminal, 'ab\x1b[c\x1b[6n');
        expect(chunks.map(latin1.decode).join(), '\x1b[?62;22c\x1b[1;3R');
      });
    });

    test('without onWritePty the replies are dropped', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.onWritePty, isNull);
        writeText(terminal, '\x1b[c');
        expect(ptyReply(terminal, ''), '');
      });
    });

    test('the getter returns the callback that is set', () {
      withTerminal(20, 5, (terminal) {
        void callback(List<int> _) {}
        terminal.onWritePty = callback;
        expect(terminal.onWritePty, same(callback));
        terminal.onWritePty = null;
        expect(terminal.onWritePty, isNull);
      });
    });

    test('onEnquiry answers ENQ; empty sends nothing', () {
      withTerminal(20, 5, (terminal) {
        expect(ptyReply(terminal, '\x05'), '');
        terminal.onEnquiry = () => 'answerback';
        expect(ptyReply(terminal, '\x05'), 'answerback');
        terminal.onEnquiry = () => '';
        expect(ptyReply(terminal, '\x05'), '');
      });
    });

    test('onEnquiry replies are UTF-8, up to maxEnquiryBytes', () {
      withTerminal(20, 5, (terminal) {
        final longest = 'é' * (VtTerminalEffects.maxEnquiryBytes ~/ 2) + 'a';
        var answer = longest;
        final errors = errorsDuring(() => terminal.onEnquiry = () => answer);
        final out = capturePty(terminal, () => writeText(terminal, '\x05'));
        expect(utf8.decode(out), longest);
        answer = '${longest}b';
        expect(ptyReply(terminal, '\x05'), '');
        expect(errors.single, isA<RangeError>());
      });
    });

    test('onXtversion names over maxXtversionBytes report the default', () {
      withTerminal(20, 5, (terminal) {
        final longest = 'v' * VtTerminalEffects.maxXtversionBytes;
        var name = longest;
        final errors = errorsDuring(() => terminal.onXtversion = () => name);
        expect(ptyReply(terminal, '\x1b[>q'), '\x1bP>|$longest\x1b\\');
        name = '${longest}v';
        expect(ptyReply(terminal, '\x1b[>q'), '\x1bP>|libghostty\x1b\\');
        expect(errors.single, isA<RangeError>());
      });
    });

    test('onXtversion answers CSI > q; empty reports the default', () {
      withTerminal(20, 5, (terminal) {
        final defaultReply = ptyReply(terminal, '\x1b[>q');
        expect(defaultReply, contains('libghostty'));
        terminal.onXtversion = () => 'myterm 1.0';
        expect(ptyReply(terminal, '\x1b[>q'), '\x1bP>|myterm 1.0\x1b\\');
        terminal.onXtversion = () => '';
        expect(ptyReply(terminal, '\x1b[>q'), defaultReply);
      });
    });

    test('onSizeQuery answers XTWINOPS; null suppresses the report', () {
      withTerminal(80, 24, (terminal) {
        expect(ptyReply(terminal, '\x1b[18t'), '');
        terminal.onSizeQuery = () => const SizeReportSize(
          rows: 24,
          columns: 80,
          cellWidth: 9,
          cellHeight: 18,
        );
        expect(ptyReply(terminal, '\x1b[18t'), '\x1b[8;24;80t');
        expect(ptyReply(terminal, '\x1b[16t'), '\x1b[6;18;9t');
        expect(ptyReply(terminal, '\x1b[14t'), '\x1b[4;432;720t');
        terminal.onSizeQuery = () => null;
        expect(ptyReply(terminal, '\x1b[18t'), '');
      });
    });

    test('onSizeQuery also answers mode 2048 enable', () {
      withTerminal(80, 24, (terminal) {
        terminal.onSizeQuery = () => const SizeReportSize(
          rows: 24,
          columns: 80,
          cellWidth: 10,
          cellHeight: 20,
        );
        expect(ptyReply(terminal, '\x1b[?2048h'), '\x1b[48;24;80;480;800t');
      });
    });

    test('onColorSchemeQuery answers CSI ? 996 n', () {
      withTerminal(20, 5, (terminal) {
        expect(ptyReply(terminal, '\x1b[?996n'), '');
        terminal.onColorSchemeQuery = () => VtColorScheme.dark;
        expect(ptyReply(terminal, '\x1b[?996n'), '\x1b[?997;1n');
        terminal.onColorSchemeQuery = () => VtColorScheme.light;
        expect(ptyReply(terminal, '\x1b[?996n'), '\x1b[?997;2n');
        terminal.onColorSchemeQuery = () => null;
        expect(ptyReply(terminal, '\x1b[?996n'), '');
      });
    });

    test('onDeviceAttributesQuery answers DA1, DA2 and DA3', () {
      withTerminal(20, 5, (terminal) {
        terminal.onDeviceAttributesQuery = () => const DeviceAttributes(
          conformanceLevel: DeviceAttributes.conformanceVt420,
          features: [
            DeviceAttributes.featureColumns132,
            DeviceAttributes.featureClipboard,
          ],
          deviceType: DeviceAttributes.deviceTypeVt420,
          firmwareVersion: 0xFFFF,
          romCartridge: 7,
          unitId: 0xAABBCCDD,
        );
        expect(ptyReply(terminal, '\x1b[c'), '\x1b[?64;1;52c');
        expect(ptyReply(terminal, '\x1b[>c'), '\x1b[>41;65535;7c');
        expect(ptyReply(terminal, '\x1b[=c'), '\x1bP!|AABBCCDD\x1b\\');
      });
    });

    test('onDeviceAttributesQuery returning null keeps the defaults', () {
      withTerminal(20, 5, (terminal) {
        terminal.onDeviceAttributesQuery = () => null;
        expect(ptyReply(terminal, '\x1b[c'), '\x1b[?62;22c');
        expect(ptyReply(terminal, '\x1b[>c'), '\x1b[>1;0;0c');
        expect(ptyReply(terminal, '\x1b[=c'), '\x1bP!|00000000\x1b\\');
      });
    });
  });

  group('terminal state', () {
    test('onBell fires once per BEL', () {
      withTerminal(20, 5, (terminal) {
        var bells = 0;
        terminal.onBell = () => bells++;
        writeText(terminal, 'a\x07b\x07');
        expect(bells, 2);
        terminal.onBell = null;
        writeText(terminal, '\x07');
        expect(bells, 2);
      });
    });

    test('onTitleChanged receives the new title (OSC 0 and OSC 2)', () {
      withTerminal(20, 5, (terminal) {
        final titles = <String>[];
        terminal.onTitleChanged = titles.add;
        writeText(terminal, '\x1b]0;first\x07\x1b]2;sécond\x1b\\');
        expect(titles, ['first', 'sécond']);
        terminal.title = 'manual';
        expect(titles, hasLength(2));
      });
    });

    test('onPwdChanged receives the raw OSC 7 value, also when cleared', () {
      withTerminal(20, 5, (terminal) {
        final pwds = <String>[];
        terminal.onPwdChanged = pwds.add;
        writeText(terminal, '\x1b]7;file://host/tmp\x07\x1b]7;\x07');
        expect(pwds, ['file://host/tmp', '']);
      });
    });

    test('onReset fires after RIS, not after DECSTR or reset()', () {
      withTerminal(20, 5, (terminal) {
        var resets = 0;
        String? titleAtReset;
        terminal.onReset = () {
          resets++;
          titleAtReset = terminal.title;
        };
        writeText(terminal, '\x1b]2;t\x07\x1bc');
        expect(resets, 1);
        expect(titleAtReset, '');
        writeText(terminal, '\x1b[!p');
        terminal.reset();
        expect(resets, 1);
      });
    });

    test('onRenderHold pairs mode 2026 set and reset', () {
      withTerminal(20, 5, (terminal) {
        final holds = <bool>[];
        terminal.onRenderHold = holds.add;
        writeText(terminal, '\x1b[?2026h\x1b[?2026h\x1b[?2026l\x1b[?2026l');
        expect(holds, [true, false]);
        writeText(terminal, '\x1b[?2026h');
        terminal.resize(30, 6);
        writeText(terminal, '\x1b[?2026l');
        expect(holds, [true, false, true, false]);
      });
    });

    test('onResizeWindow reports CSI 8 t without resizing', () {
      withTerminal(20, 5, (terminal) {
        final requests = <ResizeWindowRequest>[];
        terminal.onResizeWindow = requests.add;
        writeText(terminal, '\x1b[8;30;100t\x1b[8;0;50t');
        expect(requests, const [
          ResizeWindowRequest(rows: 30, columns: 100),
          ResizeWindowRequest(columns: 50),
        ]);
        expect((terminal.cols, terminal.rows), (20, 5));
      });
    });
  });

  group('clipboard', () {
    test('OSC 52 write delivers decoded contents', () {
      withTerminal(20, 5, (terminal) {
        final requests = <ClipboardWriteRequest>[];
        terminal.onClipboardWrite = (request) {
          requests.add(request);
          return ClipboardWriteReply.success;
        };
        writeText(
          terminal,
          '\x1b]52;c;${base64.encode(utf8.encode('hé'))}\x07',
        );
        expect(requests, hasLength(1));
        final request = requests.single;
        expect(request.location, ClipboardLocation.standard);
        expect(request.isClear, isFalse);
        expect(request.contents.single.mimeType, 'text/plain');
        expect(request.contents.single.text, 'hé');
        expect(request.isGranted, isFalse);
      });
    });

    test('OSC 52 primary selection location is normalized', () {
      withTerminal(20, 5, (terminal) {
        final locations = <ClipboardLocation>[];
        terminal.onClipboardWrite = (request) {
          locations.add(request.location);
          return null;
        };
        writeText(terminal, '\x1b]52;p;YQ==\x07\x1b]52;s;YQ==\x07');
        expect(locations, [
          ClipboardLocation.primary,
          ClipboardLocation.selection,
        ]);
      });
    });

    test('OSC 52 read is answered with the reply text', () {
      withTerminal(20, 5, (terminal) {
        final requests = <ClipboardReadRequest>[];
        terminal.onClipboardRead = (request) {
          requests.add(request);
          return ClipboardReadReply.text('hi');
        };
        final reply = ptyReply(terminal, '\x1b]52;c;?\x07');
        expect(
          reply,
          startsWith('\x1b]52;c;${base64.encode(utf8.encode('hi'))}'),
        );
        expect(requests.single.mimeTypes, ['text/plain']);
        expect(requests.single.location, ClipboardLocation.standard);
      });
    });

    test('a denied or null OSC 52 read answers an empty clipboard', () {
      withTerminal(20, 5, (terminal) {
        terminal.onClipboardRead = (_) => ClipboardReadReply.denied;
        final denied = ptyReply(terminal, '\x1b]52;c;?\x07');
        terminal.onClipboardRead = (_) => null;
        final none = ptyReply(terminal, '\x1b]52;c;?\x07');
        expect(denied, none);
        expect(denied, isNot(contains(base64.encode(utf8.encode('hi')))));
      });
    });
  });

  group('notifications, progress and shell integration', () {
    test('OSC 9 and OSC 777 desktop notifications', () {
      withTerminal(20, 5, (terminal) {
        final notifications = <DesktopNotification>[];
        terminal.onDesktopNotification = notifications.add;
        writeText(
          terminal,
          '\x1b]9;build done\x07\x1b]777;notify;Tí;Bödy text\x07',
        );
        expect(notifications, const [
          DesktopNotification(body: 'build done'),
          DesktopNotification(title: 'Tí', body: 'Bödy text'),
        ]);
      });
    });

    test('OSC 9;4 progress reports: every state, omitted values', () {
      withTerminal(20, 5, (terminal) {
        final reports = <ProgressReport>[];
        terminal.onProgressReport = reports.add;
        writeText(
          terminal,
          '\x1b]9;4;0\x07\x1b]9;4;1;0\x07\x1b]9;4;1;100\x07'
          '\x1b]9;4;2;40\x07\x1b]9;4;3\x07\x1b]9;4;4;7\x07',
        );
        expect(reports, const [
          ProgressReport(ProgressState.remove),
          ProgressReport(ProgressState.set, progress: 0),
          ProgressReport(ProgressState.set, progress: 100),
          ProgressReport(ProgressState.error, progress: 40),
          ProgressReport(ProgressState.indeterminate),
          ProgressReport(ProgressState.pause, progress: 7),
        ]);
      });
    });

    test('OSC 7501 program status reports and the support query', () {
      withTerminal(20, 5, (terminal) {
        final reports = <ProgramStatus>[];
        terminal.onProgramStatus = reports.add;
        writeText(
          terminal,
          '\x1b]7501;state=blocked:kind=permission:app=terraform:'
          'msg=${base64.encode(utf8.encode('Apply?'))}\x1b\\',
        );
        expect(reports, const [
          ProgramStatus(
            state: ProgramStatusState.blocked,
            kind: ProgramStatusKind.permission,
            app: 'terraform',
            message: 'Apply?',
          ),
        ]);
        expect(ptyReply(terminal, '\x1b]7501;?\x1b\\'), contains('states='));
      });
    });

    test('RIS clears program status before calling onReset', () {
      withTerminal(20, 5, (terminal) {
        final events = <String>[];
        terminal
          ..onProgramStatus = ((status) => events.add('status ${status.state}'))
          ..onProgressReport = ((_) => events.add('progress'))
          ..onReset = (() => events.add('reset'));
        writeText(terminal, '\x1bc');
        expect(events.last, 'reset');
        expect(events, contains('status ${ProgramStatusState.clear}'));
      });
    });

    test('OSC 133 semantic prompt events', () {
      withTerminal(20, 5, (terminal) {
        final events = <SemanticPromptEvent>[];
        terminal.onSemanticPrompt = events.add;
        writeText(
          terminal,
          '\x1b]133;A\x07> \x1b]133;B\x07ls\r\n\x1b]133;C\x07\x1b]133;D;3\x07',
        );
        expect(events.map((e) => e.kind), [
          SemanticPromptKind.promptStart,
          SemanticPromptKind.inputStart,
          SemanticPromptKind.outputStart,
          SemanticPromptKind.commandEnd,
        ]);
        expect(events.first.promptKind, PromptKind.primary);
        expect(events.last.exitCode, 3);
        expect(events.first.exitCode, isNull);
      });
    });
  });

  group('unknown sequences', () {
    test('nothing is reported without a byte limit', () {
      withTerminal(20, 5, (terminal) {
        final sequences = <UnknownSequence>[];
        terminal.onUnknownSequence = sequences.add;
        writeText(terminal, '\x1b]7400;status=busy\x07');
        expect(sequences, isEmpty);
      });
    });

    test('unknown OSC and APC sequences are reported', () {
      withTerminal(20, 5, (terminal) {
        final sequences = <UnknownSequence>[];
        terminal
          ..setUnknownSequenceMaxBytes(64)
          ..onUnknownSequence = sequences.add;
        writeText(terminal, '\x1b]7400;status=busy\x07\x1b]7401;x\x1b\\');
        writeText(terminal, '\x1b_zcustom\x1b\\');
        expect(sequences, [
          UnknownOscSequence(
            utf8.encode('7400;status=busy'),
            terminator: OscTerminator.bel,
          ),
          UnknownOscSequence(utf8.encode('7401;x')),
          UnknownApcSequence(utf8.encode('zcustom')),
        ]);
      });
    });

    test('long sequences arrive truncated', () {
      withTerminal(20, 5, (terminal) {
        final sequences = <UnknownSequence>[];
        terminal
          ..setUnknownSequenceMaxBytes(4)
          ..onUnknownSequence = sequences.add;
        writeText(terminal, '\x1b]7400;long payload\x07');
        expect(sequences.single.isTruncated, isTrue);
        expect(sequences.single.text, '7400');
      });
    });
  });

  group('errors', () {
    test('a throwing callback is reported to the zone it was set in', () {
      withTerminal(20, 5, (terminal) {
        final errors = errorsDuring(() {
          terminal.onBell = () => throw const FormatException('bell');
        });
        expect(errors, isEmpty);
        final writeZoneErrors = errorsDuring(
          () => writeText(terminal, '\x07ok\x07'),
        );
        expect(writeZoneErrors, isEmpty);
        expect(errors, [isFormatException, isFormatException]);
        expect(screenText(terminal), 'ok', reason: 'the write went on');
      });
    });

    test('a throwing query callback falls back to the no-answer value', () {
      withTerminal(20, 5, (terminal) {
        final errors = errorsDuring(() {
          terminal
            ..onDeviceAttributesQuery = (() => throw StateError('da'))
            ..onColorSchemeQuery = (() => throw StateError('scheme'))
            ..onEnquiry = (() => throw StateError('enq'));
        });
        expect(ptyReply(terminal, '\x1b[c'), '\x1b[?62;22c');
        expect(ptyReply(terminal, '\x1b[?996n'), '');
        expect(ptyReply(terminal, '\x05'), '');
        expect(errors, hasLength(3));
      });
    });

    test('invalid returned values are reported and ignored', () {
      withTerminal(20, 5, (terminal) {
        final errors = errorsDuring(() {
          terminal
            ..onDeviceAttributesQuery = (() =>
                DeviceAttributes(features: List.filled(65, 1)))
            ..onSizeQuery = (() => const SizeReportSize(
              rows: 0x10000,
              columns: 1,
              cellWidth: 1,
              cellHeight: 1,
            ))
            ..onColorSchemeQuery = (() => VtColorScheme.unknown)
            ..onClipboardWrite = ((_) =>
                const ClipboardWriteReply(ClipboardWriteResult.unknown));
        });
        expect(ptyReply(terminal, '\x1b[c'), '\x1b[?62;22c');
        expect(ptyReply(terminal, '\x1b[18t'), '');
        expect(ptyReply(terminal, '\x1b[?996n'), '');
        writeText(terminal, '\x1b]52;c;YQ==\x07');
        expect(errors, [
          isA<RangeError>(),
          isA<RangeError>(),
          isA<ArgumentError>(),
          isA<ArgumentError>(),
        ]);
      });
    });

    test('write() from a callback throws StateError, reported', () {
      withTerminal(20, 5, (terminal) {
        final errors = errorsDuring(() {
          terminal.onBell = () => writeText(terminal, 'x');
        });
        writeText(terminal, '\x07a');
        expect(errors.single, isA<StateError>());
        expect(screenText(terminal), 'a');
      });
    });
  });

  group('reentrancy and lifecycle', () {
    test('a callback may read state and replace or clear callbacks', () {
      withTerminal(20, 5, (terminal) {
        final seen = <String>[];
        terminal.onBell = () {
          seen.add('first at ${terminal.cursorX}');
          terminal.onBell = () {
            seen.add('second');
            terminal.onBell = null;
          };
        };
        writeText(terminal, 'ab\x07\x07\x07');
        expect(seen, ['first at 2', 'second']);
        expect(terminal.onBell, isNull);
      });
    });

    test('a callback may resize and reset the terminal', () {
      withTerminal(20, 5, (terminal) {
        terminal.onBell = () => terminal
          ..resize(30, 6)
          ..reset();
        writeText(terminal, 'x\x07y');
        expect((terminal.cols, terminal.rows), (30, 6));
        expect(screenText(terminal), 'y');
      });
    });

    test('dispose inside a callback stops further callbacks', () {
      final terminal = VtTerminal(cols: 20, rows: 5);
      var bells = 0;
      terminal.onBell = () {
        bells++;
        terminal.dispose();
      };
      writeText(terminal, '\x07\x07\x07');
      expect(bells, 1);
      expect(terminal.isDisposed, isTrue);
    });

    test('callbacks cannot be read or set after dispose', () {
      final terminal = VtTerminal(cols: 20, rows: 5)..onBell = () {};
      terminal.dispose();
      expect(() => terminal.onBell, throwsStateError);
      expect(() => terminal.onBell = null, throwsStateError);
      expect(() => terminal.onWritePty = (_) {}, throwsStateError);
      expect(() => terminal.onUnknownSequence, throwsStateError);
      terminal.dispose();
    });

    test('clearing a callback that was never set is a no-op', () {
      withTerminal(20, 5, (terminal) {
        terminal.onSemanticPrompt = null;
        expect(terminal.onSemanticPrompt, isNull);
      });
    });

    test('callbacks are per terminal', () {
      withTerminal(20, 5, (a) {
        withTerminal(20, 5, (b) {
          var aBells = 0;
          var bBells = 0;
          a.onBell = () => aBells++;
          b.onBell = () => bBells++;
          writeText(a, '\x07');
          writeText(b, '\x07\x07');
          expect((aBells, bBells), (1, 2));
        });
      });
    });

    test('every callback can be set and cleared', () {
      withTerminal(20, 5, (terminal) {
        terminal
          ..onWritePty = (_) {}
          ..onBell = () {}
          ..onEnquiry = (() => '')
          ..onXtversion = (() => '')
          ..onTitleChanged = (_) {}
          ..onPwdChanged = (_) {}
          ..onSizeQuery = (() => null)
          ..onColorSchemeQuery = (() => null)
          ..onDeviceAttributesQuery = (() => null)
          ..onClipboardWrite = ((_) => null)
          ..onClipboardRead = ((_) => null)
          ..onDesktopNotification = (_) {}
          ..onProgressReport = (_) {}
          ..onProgramStatus = (_) {}
          ..onSemanticPrompt = (_) {}
          ..onReset = () {}
          ..onResizeWindow = (_) {}
          ..onRenderHold = (_) {}
          ..onUnknownSequence = (_) {};
        writeText(terminal, '\x07\x1b]2;t\x07\x1b[c\x1bc');
        terminal
          ..onWritePty = null
          ..onBell = null
          ..onEnquiry = null
          ..onXtversion = null
          ..onTitleChanged = null
          ..onPwdChanged = null
          ..onSizeQuery = null
          ..onColorSchemeQuery = null
          ..onDeviceAttributesQuery = null
          ..onClipboardWrite = null
          ..onClipboardRead = null
          ..onDesktopNotification = null
          ..onProgressReport = null
          ..onProgramStatus = null
          ..onSemanticPrompt = null
          ..onReset = null
          ..onResizeWindow = null
          ..onRenderHold = null
          ..onUnknownSequence = null;
        writeText(terminal, '\x07\x1b]2;u\x07\x1b[c\x1bc');
        expect(terminal.onBell, isNull);
      });
    });
  });
}
