// Adversarial tests from the T01 correctness review.
//
// Keep the first test first: it needs a fresh isolate (each test file runs in
// its own) whose scratch pools have never been used.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

final _mallocFinalizer = NativeFinalizer(malloc.nativeFree);

NativeHandle<Uint8> _handle(List<String> log, String name) =>
    NativeHandle<Uint8>(
      malloc<Uint8>(8),
      typeName: name,
      free: (p) {
        log.add('free $name');
        malloc.free(p);
      },
      finalizer: _mallocFinalizer,
    );

/// The total pixel size (width, height) the library stores for [terminal].
(int, int) _pixels(VtTerminal terminal) => (
  terminalDataUint32(
    terminal,
    GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_WIDTH_PX,
  ),
  terminalDataUint32(
    terminal,
    GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_HEIGHT_PX,
  ),
);

/// The style of the active-area cell at ([x], [y]), read with the raw grid
/// ref bindings and decoded with [cellStyleFromNative].
CellStyle _styleAt(VtTerminal terminal, int x, int y) => using((arena) {
  final point = arena<GhosttyPoint>();
  gridPointToNative(GridPoint.active(x, y), point.ref);
  final ref = arena<GhosttyGridRef>()..initSized(sizeOf<GhosttyGridRef>());
  checkResult(
    ghostty_terminal_grid_ref(
      handleOf<GhosttyTerminalImpl>(terminal).pointer,
      point.ref,
      ref,
    ),
    'ghostty_terminal_grid_ref',
  );
  final style = arena<GhosttyStyle>();
  checkResult(ghostty_grid_ref_style(ref, style), 'ghostty_grid_ref_style');
  return cellStyleFromNative(style.ref);
});

void main() {
  test(
    'the first pooled request for zero bytes still gets a valid pointer',
    () {
      // Regression: the pool started with no block, so the very first
      // zero-length request received NULL despite the documented guarantee.
      withNativeBytes(Uint8List(0), (data, length) {
        expect(data, isNot(nullptr));
        expect(length, 0);
      });
      withScratch(0, (memory) => expect(memory, isNot(nullptr)));
    },
  );

  group('VtTerminal.resize', () {
    test('keeps the cell width after DECCOLM changes the column count', () {
      // Regression: the omitted cell size was derived as total px ÷ cols,
      // but DECCOLM changes cols without updating the total, so the cell
      // width silently shrank (10 px → 6 px here).
      withTerminal(80, 24, (terminal) {
        terminal.resize(80, 24, cellWidthPx: 10, cellHeightPx: 20);
        writeText(terminal, '\x1b[?40h\x1b[?3h'); // allow DECCOLM, go 132
        expect(terminal.cols, 132);
        terminal.resize(100, 30);
        expect(_pixels(terminal), (1000, 600));
      });
    });

    test('a failed or rejected resize does not change the kept cell size', () {
      withTerminal(10, 4, (terminal) {
        terminal.resize(10, 4, cellWidthPx: 7, cellHeightPx: 9);
        expect(() => terminal.resize(0, 4, cellWidthPx: 100), throwsRangeError);
        terminal.resize(5, 2);
        expect(_pixels(terminal), (35, 18));
      });
    });

    test('accepts the uint32 pixel extremes', () {
      withTerminal(1, 1, (terminal) {
        terminal.resize(1, 1, cellWidthPx: 0xFFFFFFFF, cellHeightPx: 0);
        expect(_pixels(terminal), (0xFFFFFFFF, 0));
        expect(
          () => terminal.resize(1, 1, cellWidthPx: 0x100000000),
          throwsRangeError,
        );
        expect(() => terminal.resize(1, 1, cellHeightPx: -1), throwsRangeError);
      });
    });
  });

  group('VtTerminal.write', () {
    test('multi-byte UTF-8 split across writes is reassembled', () {
      withTerminal(10, 2, (terminal) {
        final bytes = utf8.encode('é😀');
        for (final b in bytes) {
          terminal.write(Uint8List.fromList([b]));
        }
        expect(screenText(terminal), 'é😀');
      });
    });

    test('inputs larger than the retained pool block are written in full', () {
      withTerminal(80, 4, (terminal) {
        // 2 MB of 'a' (a multiple of 80, beyond the 1 MiB retained block)
        // plus 3, then a marker: the tail row must read exactly 'aaaEND'.
        const length = 80 * 26215 + 3;
        final big = Uint8List(length)..fillRange(0, length, 0x61);
        terminal
          ..write(big)
          ..write(utf8.encode('END'));
        expect(screenText(terminal).split('\n').last, 'aaaEND');
      });
    });

    test('a dispose from inside write is deferred until the call returns', () {
      // Simulates a terminal callback that disposes the terminal: the free
      // must wait for the outermost use() to return.
      final terminal = VtTerminal(cols: 4, rows: 2);
      final handle = handleOf<GhosttyTerminalImpl>(terminal);
      handle.use((pointer) {
        terminal.dispose();
        expect(terminal.isDisposed, isTrue);
        // The native object is still alive: this call must not crash.
        ghostty_terminal_vt_write(pointer, nullptr, 0);
        expect(() => terminal.write(Uint8List(1)), throwsStateError);
      });
      expect(() => handle.pointer, throwsStateError);
    });
  });

  group('NativeHandle', () {
    test('a throwing dependent does not stop the owner from being freed', () {
      // Regression: an exception from a dependent's cleanup escaped before
      // the owner's free, leaking it (its finalizer was already detached).
      final log = <String>[];
      final owner = _handle(log, 'owner');
      final bad = _handle(log, 'bad')
        ..addCleanup(() => throw StateError('boom'));
      final good = _handle(log, 'good');
      owner
        ..addDependent(bad)
        ..addDependent(good);
      expect(owner.dispose, throwsA(isA<StateError>()));
      expect(log, ['free bad', 'free good', 'free owner']);
      expect([owner, bad, good].every((h) => h.isDisposed), isTrue);
      owner.dispose(); // still idempotent
      expect(log, hasLength(3));
    });

    test('a deferred dispose still runs cleanups after the free', () {
      final log = <String>[];
      final handle = _handle(log, 'h')..addCleanup(() => log.add('cleanup'));
      handle.use((_) {
        handle.dispose();
        expect(log, isEmpty);
      });
      expect(log, ['free h', 'cleanup']);
    });

    test('a cleanup that disposes again does not free twice', () {
      final log = <String>[];
      late NativeHandle<Uint8> handle;
      handle = _handle(log, 'h')..addCleanup(() => handle.dispose());
      handle.dispose();
      expect(log, ['free h']);
    });

    test('garbage-collected dependents are skipped', () {
      final log = <String>[];
      final owner = _handle(log, 'owner');
      for (var i = 0; i < 40; i++) {
        owner.addDependent(_handle(log, 'd$i')..dispose());
      }
      log.clear();
      owner.dispose();
      expect(log, ['free owner']);
    });
  });

  group('library info', () {
    test('the feature set cannot be modified', () {
      expect(
        () => libghosttyVtBuildInfo.features.clear(),
        throwsUnsupportedError,
      );
    });
  });

  group('style decoding from a real terminal', () {
    test('SGR attributes and colours decode from GhosttyStyle', () {
      withTerminal(10, 2, (terminal) {
        writeText(
          terminal,
          '\x1b[1;3;2;5;7;8;9;53;4:3;38;5;196;48;2;1;2;3;58;2;9;8;7mX'
          '\x1b[0mY\x1b[21mZ',
        );
        expect(
          _styleAt(terminal, 0, 0),
          const CellStyle(
            foreground: PaletteColor(196),
            background: RgbColor(1, 2, 3),
            underlineColor: RgbColor(9, 8, 7),
            bold: true,
            italic: true,
            faint: true,
            blink: true,
            inverse: true,
            invisible: true,
            strikethrough: true,
            overline: true,
            underline: UnderlineStyle.curly,
          ),
        );
        expect(_styleAt(terminal, 1, 0).isDefault, isTrue);
        expect(
          _styleAt(terminal, 2, 0),
          const CellStyle(underline: UnderlineStyle.double),
        );
      });
    });
  });
}
