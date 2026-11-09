import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

final _skip = libghosttyVtBuildInfo.supports(VtFeature.snapshot)
    ? null
    : 'built without snapshots';

/// Decodes [snapshot] with the raw decoder and returns the restored
/// terminal's (cols, rows, cursor x), proving the bytes are a valid
/// snapshot independently of the code under test.
(int, int, int) _decodeRaw(Uint8List snapshot) => using((arena) {
  final data = arena<Uint8>(snapshot.length)
    ..asTypedList(snapshot.length).setAll(0, snapshot);
  final decoderOut = arena<GhosttySnapshotDecoder>();
  expect(
    ghostty_snapshot_decoder_new_buf(
      nullptr,
      decoderOut,
      data,
      snapshot.length,
    ),
    GhosttyResult.GHOSTTY_SUCCESS,
  );
  final decoder = decoderOut.value;
  final terminalOut = arena<GhosttyTerminal>();
  try {
    expect(
      ghostty_snapshot_decoder_decode(decoder, terminalOut),
      GhosttyResult.GHOSTTY_SUCCESS,
    );
  } finally {
    ghostty_snapshot_decoder_free(decoder);
  }
  final terminal = terminalOut.value;
  try {
    int read(int key) {
      final out = arena<Uint16>();
      expect(
        ghostty_terminal_get(terminal, key, out.cast()),
        GhosttyResult.GHOSTTY_SUCCESS,
      );
      return out.value;
    }

    return (
      read(GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLS),
      read(GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_ROWS),
      read(GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_CURSOR_X),
    );
  } finally {
    ghostty_terminal_free(terminal);
  }
});

void main() {
  group('encodeSnapshot', skip: _skip, () {
    test('encodes a terminal that decodes back', () {
      withTerminal(30, 7, (terminal) {
        writeText(terminal, 'hello, snapshot');
        final snapshot = terminal.encodeSnapshot();
        expect(snapshot, isNotEmpty);
        expect(_decodeRaw(snapshot), (30, 7, 15));
      });
    });

    test('encoding does not change the terminal', () {
      withTerminal(10, 3, (terminal) {
        writeText(terminal, 'abc');
        final ref = terminal.gridRef(const GridPoint.active(0, 0))!;
        final first = terminal.encodeSnapshot();
        expect(ref.isValid, isTrue);
        expect(terminal.encodeSnapshot(), first);
        expect(screenText(terminal), 'abc');
      });
    });

    test('a terminal mid-sequence needs continuation tracking', () {
      withTerminal(10, 3, (terminal) {
        writeText(terminal, '\x1b[3');
        expect(
          terminal.encodeSnapshot,
          throwsA(
            isA<GhosttyException>().having(
              (e) => e.code,
              'code',
              GhosttyResultCode.invalidValue,
            ),
          ),
        );
      });
      withTerminal(10, 3, (terminal) {
        terminal.continuationMaxBytes = 64;
        writeText(terminal, '\x1b[3');
        expect(terminal.encodeSnapshot(), isNotEmpty);
      });
    });
  });

  group('encodeSnapshotTo', skip: _skip, () {
    test('streams the same bytes as encodeSnapshot', () {
      withTerminal(80, 24, (terminal) {
        terminal.scrollbackMaxBytes = null;
        writeText(terminal, List.generate(5000, (i) => 'line $i\r\n').join());
        final builder = BytesBuilder();
        var chunks = 0;
        terminal.encodeSnapshotTo((chunk) {
          chunks++;
          builder.add(chunk);
        });
        expect(chunks, greaterThan(0));
        expect(builder.takeBytes(), terminal.encodeSnapshot());
      });
    });

    test('chunks are copies that may be kept', () {
      withTerminal(10, 3, (terminal) {
        final kept = <Uint8List>[];
        terminal.encodeSnapshotTo(kept.add);
        final again = <Uint8List>[];
        terminal.encodeSnapshotTo(again.add);
        expect(kept, again);
      });
    });

    test('an error thrown by the sink stops encoding and is rethrown', () {
      withTerminal(10, 3, (terminal) {
        var calls = 0;
        expect(
          () => terminal.encodeSnapshotTo((_) {
            calls++;
            throw const FormatException('disk full');
          }),
          throwsA(isA<FormatException>()),
        );
        expect(calls, 1);
        expect(terminal.encodeSnapshot(), isNotEmpty);
      });
    });

    test('the sink cannot write to the terminal', () {
      withTerminal(10, 3, (terminal) {
        expect(
          () => terminal.encodeSnapshotTo((_) => writeText(terminal, 'x')),
          throwsStateError,
        );
        expect(screenText(terminal), '');
      });
    });

    test('disposing from the sink is deferred until encoding ends', () {
      final terminal = VtTerminal(cols: 10, rows: 3);
      terminal.encodeSnapshotTo((_) => terminal.dispose());
      expect(terminal.isDisposed, isTrue);
    });

    test('a terminal mid-sequence without tracking throws', () {
      withTerminal(10, 3, (terminal) {
        writeText(terminal, '\x1b]0;unfinished');
        expect(
          () => terminal.encodeSnapshotTo((_) {}),
          throwsA(isA<GhosttyException>()),
        );
      });
    });
  });

  group('lifecycle', skip: _skip, () {
    test('members throw StateError after dispose', () {
      final terminal = VtTerminal(cols: 10, rows: 3)..dispose();
      expect(terminal.encodeSnapshot, throwsStateError);
      expect(() => terminal.encodeSnapshotTo((_) {}), throwsStateError);
    });

    test('members throw StateError inside a callback of the terminal', () {
      withTerminal(10, 3, (terminal) {
        final errors = <Object>[];
        terminal.onBell = () {
          try {
            terminal.encodeSnapshot();
          } catch (error) {
            errors.add(error);
          }
          try {
            terminal.encodeSnapshotTo((_) {});
          } catch (error) {
            errors.add(error);
          }
        };
        writeText(terminal, '\x07');
        expect(errors, [isA<StateError>(), isA<StateError>()]);
      });
    });
  });
}
