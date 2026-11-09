// Stoppable writes (vt_write_until) and replay-safe continuations.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

Uint8List _bytes(String text) => utf8.encode(text);

void main() {
  group('writeUntil', () {
    test('stops after the OSC introducer and after its terminator', () {
      withTerminal(20, 3, (terminal) {
        final input = _bytes('ab\x1b]0;hi\x07cd');
        final start = terminal.writeUntil(input, WriteBoundaries.oscStart);
        expect(start.consumed, 4); // a b ESC ]
        expect(start.reached, WriteBoundaries.oscStart);
        expect(start.kind, ControlStringKind.osc);
        expect(start.introducer, ControlStringIntroducer.esc);
        expect(start.end, isNull);
        expect(start.byte, 0x5D);
        expect(screenText(terminal), 'ab');

        final end = terminal.writeUntil(
          input,
          WriteBoundaries.oscEnd,
          start: start.consumed,
        );
        expect(end.consumed, 5); // 0 ; h i BEL
        expect(end.reached, WriteBoundaries.oscEnd);
        expect(end.end, ControlStringEnd.bel);
        expect(end.introducer, isNull);
        expect(end.byte, 0x07);
        expect(terminal.title, 'hi');

        final rest = terminal.writeUntil(
          input,
          WriteBoundaries.all - WriteBoundaries.ground,
          start: start.consumed + end.consumed,
        );
        expect(rest.reachedBoundary, isFalse);
        expect(rest.consumed, 2);
        expect(rest.kind, isNull);
        expect(screenText(terminal), 'abcd');
      });
    });

    test('ST terminator leaves the backslash for the next write', () {
      withTerminal(20, 3, (terminal) {
        final input = _bytes('\x1b]2;t\x1b\\x');
        final stop = terminal.writeUntil(input, WriteBoundaries.oscEnd);
        expect(stop.end, ControlStringEnd.stEsc);
        expect(stop.byte, 0x1B);
        expect(input[stop.consumed], 0x5C);
        terminal.write(Uint8List.sublistView(input, stop.consumed));
        expect(terminal.title, 't');
        expect(screenText(terminal), 'x');
      });
    });

    test('ground: stops at once at ground, else when ground is reached', () {
      withTerminal(20, 3, (terminal) {
        final atGround = terminal.writeUntil(
          _bytes('abc'),
          WriteBoundaries.ground,
        );
        expect(atGround.consumed, 0);
        expect(atGround.reached, WriteBoundaries.ground);
        expect(atGround.kind, isNull);

        terminal.write(_bytes('\x1b[1'));
        final reached = terminal.writeUntil(
          _bytes(';31mtext'),
          WriteBoundaries.ground,
        );
        expect(reached.consumed, 4);
        expect(reached.reached, WriteBoundaries.ground);
        expect(terminal.isVtGround, isTrue);
        expect(terminal.cursorSgrStyle.bold, isTrue);
      });
    });

    test('one byte can end a string and return to ground', () {
      withTerminal(20, 3, (terminal) {
        terminal.write(_bytes('\x1b'));
        final stop = terminal.writeUntil(
          _bytes(']0;x\x07'),
          WriteBoundaries.oscEnd | WriteBoundaries.ground,
        );
        expect(stop.consumed, 5);
        expect(stop.reached, WriteBoundaries.oscEnd | WriteBoundaries.ground);
        expect(stop.end, ControlStringEnd.bel);
      });
    });

    test('APC and DCS boundaries with C1 introducers inside a sequence', () {
      withTerminal(20, 3, (terminal) {
        final apc = terminal.writeUntil(
          _bytes('\x1b_Gabc\x1b\\'),
          WriteBoundaries.apcStart | WriteBoundaries.apcEnd,
        );
        expect(apc.kind, ControlStringKind.apc);
        expect(apc.byte, 0x5F);
        final dcs = terminal.writeUntil(
          _bytes('\\\x1bP+q544e\x1b\\'),
          WriteBoundaries.dcsStart,
        );
        expect(dcs.reached, WriteBoundaries.dcsStart);
        expect(dcs.kind, ControlStringKind.dcs);
        expect(dcs.byte, 0x50);
      });
    });

    test('CAN cancels a string', () {
      withTerminal(20, 3, (terminal) {
        final stop = terminal.writeUntil(
          _bytes('\x1b]0;nope\x18after'),
          WriteBoundaries.oscEnd,
        );
        expect(stop.end, ControlStringEnd.cancelled);
        expect(terminal.title, '');
      });
    });

    test('empty input without ground consumes nothing and reaches nothing', () {
      withTerminal(20, 3, (terminal) {
        final stop = terminal.writeUntil(
          Uint8List(0),
          WriteBoundaries.oscStart,
        );
        expect(
          stop,
          const WriteStop(consumed: 0, reached: WriteBoundaries.none),
        );
      });
    });

    test('argument validation', () {
      withTerminal(20, 3, (terminal) {
        final input = _bytes('abc');
        expect(
          () => terminal.writeUntil(input, WriteBoundaries.none),
          throwsArgumentError,
        );
        expect(
          () => terminal.writeUntil(input, WriteBoundaries.oscEnd, start: 4),
          throwsRangeError,
        );
        expect(
          () => terminal.writeUntil(
            input,
            WriteBoundaries.oscEnd,
            start: 2,
            end: 1,
          ),
          throwsRangeError,
        );
        expect(screenText(terminal), '', reason: 'nothing was written');
      });
    });

    test('each native call bumps the epoch', () {
      withTerminal(20, 3, (terminal) {
        final handle = handleOf<GhosttyTerminalImpl>(terminal);
        final before = handle.epoch;
        terminal.writeUntil(_bytes('x'), WriteBoundaries.oscStart);
        expect(handle.epoch, before + 1);
      });
    });
  });

  group('writeWithStops', () {
    test('reports every boundary with its offset and writes everything', () {
      withTerminal(30, 3, (terminal) {
        final input = _bytes('a\x1b]0;one\x07b\x1b]2;two\x1b\\c');
        final stops = <(WriteBoundaries, int)>[];
        final written = terminal.writeWithStops(
          input,
          WriteBoundaries.oscStart | WriteBoundaries.oscEnd,
          (stop, offset) {
            stops.add((stop.reached, offset));
            return true;
          },
        );
        expect(written, input.length);
        expect(stops, [
          (WriteBoundaries.oscStart, 3),
          (WriteBoundaries.oscEnd, 9),
          (WriteBoundaries.oscStart, 12),
          (WriteBoundaries.oscEnd, 18),
        ]);
        expect(terminal.title, 'two');
        expect(screenText(terminal), 'abc');
      });
    });

    test('returning false stops early, leaving the rest unwritten', () {
      withTerminal(30, 3, (terminal) {
        final input = _bytes('a\x1b]0;one\x07rest');
        final offset = terminal.writeWithStops(
          input,
          WriteBoundaries.oscEnd,
          (_, _) => false,
        );
        expect(offset, 9);
        expect(terminal.title, 'one');
        expect(screenText(terminal), 'a');
      });
    });

    test('onStop may write and may dispose the terminal', () {
      withTerminal(30, 3, (terminal) {
        terminal.writeWithStops(
          _bytes('x\x1b]0;t\x07y'),
          WriteBoundaries.oscEnd,
          (_, _) {
            writeText(terminal, '[osc]');
            return true;
          },
        );
        expect(screenText(terminal), 'x[osc]y');
      });
      final terminal = VtTerminal(cols: 10, rows: 2);
      final offset = terminal.writeWithStops(
        _bytes('\x1b]0;t\x07after'),
        WriteBoundaries.oscEnd,
        (_, _) {
          terminal.dispose();
          return true;
        },
      );
      expect(offset, 6);
      expect(terminal.isDisposed, isTrue);
    });

    test('no boundary: one call writes everything; empty input is a no-op', () {
      withTerminal(30, 3, (terminal) {
        var calls = 0;
        expect(
          terminal.writeWithStops(_bytes('plain'), WriteBoundaries.anyStart, (
            _,
            _,
          ) {
            calls++;
            return true;
          }),
          5,
        );
        expect(calls, 0);
        expect(
          terminal.writeWithStops(Uint8List(0), WriteBoundaries.anyStart, (
            _,
            _,
          ) {
            calls++;
            return true;
          }),
          0,
        );
        expect(screenText(terminal), 'plain');
      });
    });

    test('rejects ground and empty boundaries', () {
      withTerminal(30, 3, (terminal) {
        bool onStop(WriteStop _, int _) => true;
        expect(
          () => terminal.writeWithStops(
            _bytes('x'),
            WriteBoundaries.ground | WriteBoundaries.oscEnd,
            onStop,
          ),
          throwsArgumentError,
        );
        expect(
          () => terminal.writeWithStops(
            _bytes('x'),
            WriteBoundaries.none,
            onStop,
          ),
          throwsArgumentError,
        );
      });
    });

    test('a large stream with many strings is consumed in order', () {
      withTerminal(80, 5, (terminal) {
        final input = _bytes(
          List.generate(500, (i) => 'x\x1b]0;$i\x07').join(),
        );
        var ends = 0;
        terminal.writeWithStops(input, WriteBoundaries.oscEnd, (_, _) {
          ends++;
          return true;
        });
        expect(ends, 500);
        expect(terminal.title, '499');
      });
    });
  });

  group('continuation', () {
    test('null while tracking is disabled', () {
      withTerminal(20, 3, (terminal) {
        writeText(terminal, '\x1b[3');
        expect(terminal.continuation, isNull);
      });
    });

    test('empty at ground; holds the unfinished sequence otherwise', () {
      withTerminal(20, 3, (terminal) {
        terminal.continuationMaxBytes = 256;
        expect(terminal.continuation, isEmpty);
        writeText(terminal, 'ok\x1b]0;partial ti');
        final continuation = terminal.continuation!;
        expect(utf8.decode(continuation), endsWith('partial ti'));

        // Replaying it into a fresh terminal continues the same stream.
        withTerminal(20, 3, (other) {
          other.write(continuation);
          writeText(other, 'tle\x07');
          expect(other.title, 'partial title');
        });
        writeText(terminal, 'tle\x07');
        expect(terminal.continuation, isEmpty);
      });
    });

    test('partial UTF-8 is kept byte-exact', () {
      withTerminal(20, 3, (terminal) {
        terminal.continuationMaxBytes = 16;
        terminal.write(Uint8List.fromList([0xF0, 0x9F]));
        expect(terminal.continuation, [0xF0, 0x9F]);
      });
    });

    test('unavailable when tracking starts mid-sequence, then recovers', () {
      withTerminal(20, 3, (terminal) {
        writeText(terminal, '\x1b]0;abc');
        terminal.continuationMaxBytes = 64;
        expect(terminal.continuation, isNull);
        writeText(terminal, '\x07');
        expect(terminal.continuation, isEmpty);
      });
    });
  });
}
