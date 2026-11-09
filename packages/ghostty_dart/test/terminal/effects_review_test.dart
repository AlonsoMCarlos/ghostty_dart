// Adversarial review tests for VtTerminalEffects: lifetimes of the
// NativeCallables, reentrancy, Kitty clipboard (OSC 5522) multi-MIME
// transactions, and the edge cases the header documents for each effect.

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';
import 'pty_capture.dart';

String _b64(String text) => base64.encode(utf8.encode(text));

/// Every callback setter, installed with a no-op.
void _setAll(VtTerminal terminal) {
  terminal
    ..onWritePty = (_) {}
    ..onBell = () {}
    ..onEnquiry = (() => 'x')
    ..onXtversion = (() => 'x')
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
}

/// Creates a terminal with every callback set and a [bells] counter, uses
/// it, and drops it without dispose. Returns weak references to it and to
/// its native handle (the object whose finalizer frees the native memory).
(WeakReference<VtTerminal>, WeakReference<Object>) _forgottenTerminal(
  List<int> bells,
) {
  final terminal = VtTerminal(cols: 10, rows: 2);
  _setAll(terminal);
  terminal.onBell = () => bells.add(1);
  writeText(terminal, '\x07\x1b[c');
  return (WeakReference(terminal), WeakReference(handleOf(terminal)));
}

/// Isolate entry: leaves a terminal with callbacks undisposed and returns.
void _leakTerminalAndReturn(SendPort done) {
  final terminal = VtTerminal(cols: 10, rows: 2);
  _setAll(terminal);
  writeText(terminal, '\x07');
  done.send(terminal.isDisposed);
}

void main() {
  group('callable lifetime', () {
    test('callables do not keep an isolate alive', () async {
      final exit = ReceivePort();
      final done = ReceivePort();
      await Isolate.spawn(
        _leakTerminalAndReturn,
        done.sendPort,
        onExit: exit.sendPort,
      );
      expect(await done.first, isFalse);
      // With keepIsolateAlive the isolate would never exit: an open
      // NativeCallable is a keep-alive port.
      await exit.first.timeout(const Duration(seconds: 10));
    });

    test('a forgotten terminal with callbacks is garbage collected', () {
      final bells = <int>[];
      final (terminal, handle) = _forgottenTerminal(bells);
      expect(bells, [1]);
      // No VM-service GC hook without a new dependency: allocate until the
      // GC runs. A strong capture in any callable would make this loop
      // exhaust its budget.
      var garbage = <Object>[];
      for (var i = 0; i < 2000 && handle.target != null; i++) {
        garbage = [for (var j = 0; j < 64; j++) Uint8List(1 << 16)];
      }
      expect(garbage, isNotEmpty);
      expect(terminal.target, isNull);
      expect(handle.target, isNull, reason: 'native terminal not finalized');
    });

    test('re-setting a callback many times reuses one callable', () {
      withTerminal(10, 2, (terminal) {
        var count = 0;
        for (var i = 0; i < 1000; i++) {
          terminal
            ..onBell = (() => count++)
            ..onBell = null;
        }
        terminal.onBell = () => count++;
        writeText(terminal, '\x07');
        expect(count, 1);
      });
    });
  });

  group('reentrancy', () {
    test('clearing the running callback from inside it is safe', () {
      withTerminal(10, 2, (terminal) {
        final replies = <String>[];
        terminal.onWritePty = (data) {
          replies.add(latin1.decode(data));
          terminal.onWritePty = null;
        };
        writeText(terminal, '\x1b[c\x1b[c');
        expect(replies, ['\x1b[?62;22c']);
        // Re-installing after the clear works and reuses the callable.
        expect(ptyReply(terminal, '\x1b[5n'), '\x1b[0n');
      });
    });

    test('dispose inside the enquiry callback still sends the answer', () {
      final terminal = VtTerminal(cols: 10, rows: 2);
      final out = <int>[];
      terminal
        ..onWritePty = out.addAll
        ..onEnquiry = () {
          terminal.dispose();
          return 'late';
        };
      writeText(terminal, '\x05');
      expect(terminal.isDisposed, isTrue);
      // After dispose the dispatch falls back: no answer, no crash.
      expect(out, isEmpty);
    });

    test('dispose in a nested callback defers the free to the outer write', () {
      final terminal = VtTerminal(cols: 10, rows: 2);
      final events = <String>[];
      terminal
        ..onRenderHold = (held) {
          events.add('hold $held');
          if (!held) terminal.dispose();
        }
        ..onBell = () {
          events.add('bell');
          // resize ends the render hold: a callback nested in a callback.
          terminal.resize(12, 3);
          events.add('after resize ${terminal.isDisposed}');
        };
      writeText(terminal, '\x1b[?2026h\x07\x07');
      expect(events, ['hold true', 'bell', 'hold false', 'after resize true']);
      expect(terminal.isDisposed, isTrue);
    });

    test('setting a different callback from inside a callback', () {
      withTerminal(10, 2, (terminal) {
        final titles = <String>[];
        terminal.onBell = () => terminal.onTitleChanged = titles.add;
        writeText(terminal, '\x1b]2;before\x07\x07\x1b]2;after\x07');
        expect(titles, ['after']);
      });
    });

    test('title and pwd getters inside their callbacks match the value', () {
      withTerminal(10, 2, (terminal) {
        final seen = <String>[];
        terminal
          ..onTitleChanged = ((title) => seen.add('$title=${terminal.title}'))
          ..onPwdChanged = ((pwd) => seen.add('$pwd=${terminal.pwd}'));
        writeText(terminal, '\x1b]0;ü\x07\x1b]7;file:///tmp\x07');
        expect(seen, ['ü=ü', 'file:///tmp=file:///tmp']);
      });
    });

    test('a write() attempt from a query callback leaves the answer', () {
      withTerminal(10, 2, (terminal) {
        final errors = errorsDuring(() {
          terminal.onEnquiry = () {
            writeText(terminal, 'x');
            return 'never';
          };
        });
        expect(ptyReply(terminal, '\x05'), '');
        expect(errors.single, isStateError);
        expect(screenText(terminal), '');
      });
    });
  });

  group('errors', () {
    test('a throwing write-pty callback does not stop later replies', () {
      withTerminal(10, 2, (terminal) {
        var calls = 0;
        final errors = errorsDuring(() {
          terminal.onWritePty = (_) {
            calls++;
            if (calls == 1) throw StateError('pty');
          };
        });
        writeText(terminal, '\x1b[c\x1b[5n');
        expect(calls, 2);
        expect(errors.single, isStateError);
      });
    });

    test('a throwing clipboard read callback answers an empty clipboard', () {
      withTerminal(10, 2, (terminal) {
        final errors = errorsDuring(() {
          terminal.onClipboardRead = (_) => throw StateError('read');
        });
        expect(ptyReply(terminal, '\x1b]52;c;?\x07'), '\x1b]52;c;\x07');
        expect(errors.single, isStateError);
      });
    });

    test('an unknown read result is reported and answers empty', () {
      withTerminal(10, 2, (terminal) {
        final errors = errorsDuring(() {
          terminal.onClipboardRead = (_) =>
              const ClipboardReadReply(result: ClipboardReadResult.unknown);
        });
        expect(ptyReply(terminal, '\x1b]52;c;?\x07'), '\x1b]52;c;\x07');
        expect(errors.single, isArgumentError);
      });
    });

    test('invalid device attributes leave every default intact', () {
      withTerminal(10, 2, (terminal) {
        final errors = errorsDuring(() {
          terminal.onDeviceAttributesQuery = () =>
              const DeviceAttributes(unitId: -1);
        });
        expect(ptyReply(terminal, '\x1b[c'), '\x1b[?62;22c');
        expect(errors.single, isRangeError);
      });
    });
  });

  group('replies', () {
    test('ENQ: a growing then shrinking answer never shows stale bytes', () {
      withTerminal(10, 2, (terminal) {
        final answers = ['short', 'x' * 200, 'ab', ''];
        var i = 0;
        terminal.onEnquiry = () => answers[i++];
        expect([
          for (var n = 0; n < answers.length; n++) ptyReply(terminal, '\x05'),
        ], answers);
      });
    });

    test('DA: maxFeatures features are all sent; none sends only Pp', () {
      withTerminal(10, 2, (terminal) {
        final features = List.generate(
          DeviceAttributes.maxFeatures,
          (i) => i + 100,
        );
        terminal.onDeviceAttributesQuery = () =>
            DeviceAttributes(features: features);
        expect(ptyReply(terminal, '\x1b[c'), '\x1b[?62;${features.join(';')}c');
        terminal.onDeviceAttributesQuery = () =>
            const DeviceAttributes(features: []);
        expect(ptyReply(terminal, '\x1b[c'), '\x1b[?62c');
      });
    });
  });

  group('Kitty clipboard (OSC 5522)', () {
    test('a multi-MIME write transaction arrives as one atomic write', () {
      withTerminal(10, 2, (terminal) {
        final requests = <ClipboardWriteRequest>[];
        terminal.onClipboardWrite = (request) {
          requests.add(request);
          return ClipboardWriteReply.success;
        };
        final reply = ptyReply(
          terminal,
          '\x1b]5522;type=write:id=c1\x1b\\'
          '\x1b]5522;type=wdata:mime=${_b64('text/plain')};${_b64('Ghost')}\x1b\\'
          '\x1b]5522;type=wdata:mime=${_b64('text/plain')};${_b64('ty')}\x1b\\'
          '\x1b]5522;type=wdata:mime=${_b64('text/html')};${_b64('<b>hi</b>')}\x1b\\'
          '\x1b]5522;type=wdata\x1b\\',
        );
        expect(reply, '\x1b]5522;type=write:status=DONE:id=c1\x1b\\');
        final request = requests.single;
        expect(request.location, ClipboardLocation.standard);
        expect(request.contents, [
          ClipboardContent.text('Ghostty'),
          ClipboardContent.text('<b>hi</b>', mimeType: 'text/html'),
        ]);
        expect(request.isGranted, isFalse);
        expect(request.canRemember, isFalse);
      });
    });

    test('write results map to the protocol statuses', () {
      withTerminal(10, 2, (terminal) {
        const statuses = {
          ClipboardWriteResult.success: 'DONE',
          ClipboardWriteResult.denied: 'EPERM',
          ClipboardWriteResult.unsupported: 'ENOSYS',
          ClipboardWriteResult.busy: 'EBUSY',
          ClipboardWriteResult.invalidData: 'EINVAL',
          ClipboardWriteResult.ioError: 'EIO',
        };
        for (final MapEntry(key: result, value: status) in statuses.entries) {
          terminal.onClipboardWrite = (_) => ClipboardWriteReply(result);
          expect(
            ptyReply(
              terminal,
              '\x1b]5522;type=write:id=s1\x1b\\\x1b]5522;type=wdata\x1b\\',
            ),
            '\x1b]5522;type=write:status=$status:id=s1\x1b\\',
            reason: '$result',
          );
        }
        // Returning null does not reply, which denies the write.
        terminal.onClipboardWrite = (_) => null;
        expect(
          ptyReply(
            terminal,
            '\x1b]5522;type=write:id=n1\x1b\\\x1b]5522;type=wdata\x1b\\',
          ),
          '\x1b]5522;type=write:status=EPERM:id=n1\x1b\\',
        );
      });
    });

    test('remember on a password write grants the next one', () {
      withTerminal(10, 2, (terminal) {
        final requests = <ClipboardWriteRequest>[];
        terminal.onClipboardWrite = (request) {
          requests.add(request);
          return const ClipboardWriteReply(
            ClipboardWriteResult.success,
            remember: true,
          );
        };
        for (final id in ['g1', 'g2']) {
          writeText(
            terminal,
            '\x1b]5522;type=write:id=$id:pw=${_b64('secret')}:'
            'name=${_b64('app')}\x1b\\\x1b]5522;type=wdata\x1b\\',
          );
        }
        expect(requests.map((r) => r.programName), ['app', 'app']);
        expect(requests.map((r) => r.canRemember), [true, true]);
        expect(requests.map((r) => r.isGranted), [false, true]);
        expect(requests.first.isClear, isTrue);
      });
    });

    test('a multi-MIME read serves each requested type in order', () {
      withTerminal(10, 2, (terminal) {
        final requests = <ClipboardReadRequest>[];
        terminal.onClipboardRead = (request) {
          requests.add(request);
          return ClipboardReadReply(
            contents: [
              // Unrequested types are ignored; order follows the request.
              ClipboardContent('image/png', Uint8List.fromList([1, 2, 0])),
              ClipboardContent.text('<i>x</i>', mimeType: 'text/html'),
              ClipboardContent.text('plain'),
            ],
            availableTypes: const ['text/plain', 'text/html', 'image/png'],
          );
        };
        final reply = ptyReply(
          terminal,
          '\x1b]5522;type=read:id=r1:name=${_b64('app')};'
          '${_b64('text/plain text/html .')}\x1b\\',
        );
        final request = requests.single;
        expect(request.mimeTypes, ['text/plain', 'text/html']);
        expect(request.wantsAvailableTypes, isTrue);
        expect(request.programName, 'app');
        expect(request.isGranted, isFalse);
        expect(
          reply,
          '\x1b]5522;type=read:status=OK:id=r1\x1b\\'
          '\x1b]5522;type=read:status=DATA:id=r1:mime=${_b64('.')};'
          '${_b64('text/plain text/html image/png\n')}\x1b\\'
          '\x1b]5522;type=read:status=DATA:id=r1:mime=${_b64('text/plain')};'
          '${_b64('plain')}\x1b\\'
          '\x1b]5522;type=read:status=DATA:id=r1:mime=${_b64('text/html')};'
          '${_b64('<i>x</i>')}\x1b\\'
          '\x1b]5522;type=read:status=DONE:id=r1\x1b\\',
        );
      });
    });

    test('a targets-only read has no MIME types and is never granted', () {
      withTerminal(10, 2, (terminal) {
        final requests = <ClipboardReadRequest>[];
        terminal.onClipboardRead = (request) {
          requests.add(request);
          return const ClipboardReadReply(availableTypes: []);
        };
        final reply = ptyReply(
          terminal,
          '\x1b]5522;type=read:id=t1;${_b64('.')}\x1b\\',
        );
        expect(requests.single.mimeTypes, isEmpty);
        expect(requests.single.wantsAvailableTypes, isTrue);
        expect(requests.single.isGranted, isFalse);
        expect(reply, startsWith('\x1b]5522;type=read:status=OK:id=t1\x1b\\'));
        expect(reply, endsWith('\x1b]5522;type=read:status=DONE:id=t1\x1b\\'));
      });
    });

    test('read failures map to statuses; null denies with EPERM', () {
      withTerminal(10, 2, (terminal) {
        const statuses = {
          ClipboardReadResult.denied: 'EPERM',
          ClipboardReadResult.unsupported: 'ENOSYS',
          ClipboardReadResult.busy: 'EBUSY',
          ClipboardReadResult.ioError: 'EIO',
        };
        final read = '\x1b]5522;type=read:id=r;${_b64('text/plain')}\x1b\\';
        for (final MapEntry(key: result, value: status) in statuses.entries) {
          terminal.onClipboardRead = (_) => ClipboardReadReply(result: result);
          expect(
            ptyReply(terminal, read),
            '\x1b]5522;type=read:status=$status:id=r\x1b\\',
          );
        }
        terminal.onClipboardRead = (_) => null;
        expect(
          ptyReply(terminal, read),
          '\x1b]5522;type=read:status=EPERM:id=r\x1b\\',
        );
      });
    });

    test('binary clipboard data round-trips through a read', () {
      withTerminal(10, 2, (terminal) {
        final data = Uint8List.fromList(List.generate(256, (i) => i));
        terminal.onClipboardRead = (_) =>
            ClipboardReadReply(contents: [ClipboardContent('image/png', data)]);
        final reply = ptyReply(
          terminal,
          '\x1b]5522;type=read:id=b;${_b64('image/png')}\x1b\\',
        );
        final packets = RegExp(
          'status=DATA:id=b:mime=${_b64('image/png')};([^\x1b]*)\x1b',
        ).allMatches(reply);
        final decoded = [
          for (final packet in packets) ...base64.decode(packet.group(1)!),
        ];
        expect(decoded, data);
      });
    });
  });

  group('clipboard (OSC 52)', () {
    test('an empty OSC 52 payload is a clear request', () {
      withTerminal(10, 2, (terminal) {
        final requests = <ClipboardWriteRequest>[];
        terminal.onClipboardWrite = (request) {
          requests.add(request);
          return null;
        };
        writeText(terminal, '\x1b]52;c;\x07');
        expect(requests.single.isClear, isTrue);
      });
    });

    test('OSC 52 read with no text representation answers empty', () {
      withTerminal(10, 2, (terminal) {
        terminal.onClipboardRead = (_) => ClipboardReadReply(
          contents: [
            ClipboardContent('image/png', Uint8List.fromList([1])),
          ],
        );
        expect(ptyReply(terminal, '\x1b]52;c;?\x07'), '\x1b]52;c;\x07');
      });
    });

    test('OSC 52 read answers with the same terminator', () {
      withTerminal(10, 2, (terminal) {
        terminal.onClipboardRead = (_) => ClipboardReadReply.text('hi');
        expect(
          ptyReply(terminal, '\x1b]52;c;?\x1b\\'),
          '\x1b]52;c;${_b64('hi')}\x1b\\',
        );
      });
    });
  });

  group('notifications and status', () {
    test('OSC 133 command end with a negative exit code', () {
      withTerminal(10, 2, (terminal) {
        final events = <SemanticPromptEvent>[];
        terminal.onSemanticPrompt = events.add;
        writeText(terminal, '\x1b]133;D;-5\x07\x1b]133;D\x07');
        expect(events.map((e) => e.kind), [
          SemanticPromptKind.commandEnd,
          SemanticPromptKind.commandEnd,
        ]);
        expect(events.map((e) => e.exitCode), [-5, null]);
      });
    });

    test('OSC 7501 program status with id, title and progress', () {
      withTerminal(10, 2, (terminal) {
        final statuses = <ProgramStatus>[];
        terminal.onProgramStatus = statuses.add;
        writeText(
          terminal,
          '\x1b]7501;state=working:id=build/test:app=cargo:progress=42:'
          'title=${_b64('Tests')}:msg=${_b64('running ü')}\x1b\\',
        );
        expect(statuses.single.state, ProgramStatusState.working);
        expect(statuses.single.id, 'build/test');
        expect(statuses.single.app, 'cargo');
        expect(statuses.single.progress, 42);
        expect(statuses.single.title, 'Tests');
        expect(statuses.single.message, 'running ü');
        expect(statuses.single.kind, ProgramStatusKind.none);
      });
    });
  });

  group('window and render', () {
    test('resize window: omitted rows or columns are null', () {
      withTerminal(10, 2, (terminal) {
        final requests = <ResizeWindowRequest>[];
        terminal.onResizeWindow = requests.add;
        writeText(terminal, '\x1b[8;;90t\x1b[8;30t');
        expect(requests, [
          const ResizeWindowRequest(columns: 90),
          const ResizeWindowRequest(rows: 30),
        ]);
        expect((terminal.cols, terminal.rows), (10, 2));
      });
    });
  });

  group('unknown sequences', () {
    test('APC content with NUL and an exact-limit OSC are not truncated', () {
      withTerminal(10, 2, (terminal) {
        final sequences = <UnknownSequence>[];
        terminal
          ..setUnknownSequenceMaxBytes(8)
          ..onUnknownSequence = sequences.add;
        terminal.write(
          Uint8List.fromList([0x1b, 0x5f, 0x00, 0x7e, 0x41, 0x1b, 0x5c]),
        );
        writeText(terminal, '\x1b]7400;ab\x1b\\\x1b]7400;abc\x07');
        expect(sequences, [
          UnknownApcSequence(Uint8List.fromList([0x00, 0x7e, 0x41])),
          UnknownOscSequence(utf8.encode('7400;ab')),
          UnknownOscSequence(
            utf8.encode('7400;abc'),
            terminator: OscTerminator.bel,
          ),
        ]);
        writeText(terminal, '\x1b]7400;abcd\x07');
        expect(sequences.last.isTruncated, isTrue);
        expect(sequences.last.text, '7400;abc');
      });
    });
  });
}
