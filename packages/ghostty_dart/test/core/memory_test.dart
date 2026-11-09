import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

const _outOfSpace = GhosttyResult.GHOSTTY_OUT_OF_SPACE;
const _noValue = GhosttyResult.GHOSTTY_NO_VALUE;

/// Simulates a `(buf, buf_len, out_written)` function that produces
/// [payload], counting calls in [calls].
int Function(Pointer<Uint8>, int, Pointer<Size>) _fakeWriter(
  List<int> payload,
  List<int> calls,
) => (buffer, capacity, outLength) {
  calls.add(capacity);
  outLength.value = payload.length;
  if (capacity < payload.length) return _outOfSpace;
  buffer.asTypedList(payload.length).setAll(0, payload);
  return 0;
};

void main() {
  group('withNativeBytes', () {
    test('copies bytes and reports the length', () {
      final bytes = Uint8List.fromList([1, 2, 3, 250]);
      final seen = withNativeBytes(
        bytes,
        (data, length) => data.asTypedList(length).toList(),
      );
      expect(seen, [1, 2, 3, 250]);
    });

    test('gives empty input a valid pointer', () {
      withNativeBytes(Uint8List(0), (data, length) {
        expect(data, isNot(nullptr));
        expect(length, 0);
      });
    });

    test('nested use never shares memory', () {
      final outer = Uint8List.fromList(List.filled(64, 7));
      withNativeBytes(outer, (outerData, outerLength) {
        withNativeBytes(Uint8List.fromList(List.filled(64, 9)), (inner, _) {
          expect(inner, isNot(outerData));
        });
        expect(outerData.asTypedList(outerLength), everyElement(7));
      });
    });

    test('handles inputs larger than the retained block', () {
      final big = Uint8List(3 << 20)..[(3 << 20) - 1] = 42;
      final last = withNativeBytes(big, (data, length) => data[length - 1]);
      expect(last, 42);
    });

    test('withUtf8 encodes text', () {
      final decoded = withUtf8('héllo ✓', decodeUtf8);
      expect(decoded, 'héllo ✓');
    });
  });

  test('withScratch gives zeroed memory', () {
    withScratch(32, (memory) => memory.asTypedList(32).fillRange(0, 32, 0xff));
    withScratch(32, (memory) {
      expect(memory.asTypedList(32), everyElement(0));
    });
  });

  group('decoding', () {
    test('decodeUtf8 replaces malformed sequences', () {
      using((arena) {
        final data = arena<Uint8>(3)
          ..asTypedList(3).setAll(0, [0x61, 0xff, 0x62]);
        expect(decodeUtf8(data, 3), 'a�b');
        expect(decodeUtf8(nullptr, 0), '');
      });
    });

    test('copyBytes copies and accepts NULL for zero length', () {
      expect(copyBytes(nullptr, 0), isEmpty);
      using((arena) {
        final data = arena<Uint8>(2)..asTypedList(2).setAll(0, [5, 6]);
        final copy = copyBytes(data, 2);
        data[0] = 0;
        expect(copy, [5, 6]);
      });
    });

    test('readGhosttyString decodes a borrowed string', () {
      using((arena) {
        final bytes = utf8.encode('título');
        final data = arena<Uint8>(bytes.length)
          ..asTypedList(bytes.length).setAll(0, bytes);
        final string = arena<GhosttyString>();
        string.ref
          ..ptr = data
          ..len = bytes.length;
        expect(readGhosttyString(string.ref), 'título');
      });
    });
  });

  group('library allocations', () {
    test('takeLibraryBytes copies and frees with ghostty_free', () {
      final data = ghostty_alloc(nullptr, 3);
      data.asTypedList(3).setAll(0, [1, 2, 3]);
      expect(takeLibraryBytes(data, 3), [1, 2, 3]);
    });

    test('callAllocating returns formatter output', () {
      withTerminal(20, 3, (terminal) {
        writeText(terminal, 'abc');
        expect(screenText(terminal), 'abc');
      });
    });

    test('callAllocating maps errors', () {
      expect(
        () => callAllocating('fake_alloc', (_, _) => -2),
        throwsA(isA<GhosttyException>()),
      );
    });
  });

  group('size-query buffers', () {
    test('retries with the size the library reports', () {
      // DECRPM for DEC mode 25 (cursor visible) set: CSI ? 25 ; 1 $ y.
      final bytes = callWithSizeQuery(
        'ghostty_mode_report_encode',
        (buffer, capacity, outLength) => ghostty_mode_report_encode(
          terminalModeToRaw(TerminalMode.cursorVisible),
          GhosttyModeReportState.GHOSTTY_MODE_REPORT_SET,
          buffer,
          capacity,
          outLength,
        ),
        initialCapacity: 1,
      );
      expect(ascii.decode(bytes), '\x1b[?25;1\$y');
    });

    test('accepts a NULL / 0 size query from the library', () {
      final calls = <int>[];
      final bytes = callWithSizeQuery(
        'fake',
        _fakeWriter([1, 2, 3, 4, 5], calls),
        initialCapacity: 0,
      );
      expect(bytes, [1, 2, 3, 4, 5]);
      expect(calls, [0, 5]);
    });

    test('succeeds in one call when the first buffer fits', () {
      final calls = <int>[];
      callWithSizeQuery('fake', _fakeWriter([1], calls));
      expect(calls, hasLength(1));
    });

    test('returns null or throws for NO_VALUE', () {
      expect(tryCallWithSizeQuery('fake', (_, _, _) => _noValue), isNull);
      expect(
        () => callWithSizeQuery('fake', (_, _, _) => _noValue),
        throwsA(
          isA<GhosttyException>().having(
            (e) => e.code,
            'code',
            GhosttyResultCode.noValue,
          ),
        ),
      );
    });

    test('gives up when the size never fits', () {
      expect(
        () => callWithSizeQuery('fake', (_, capacity, outLength) {
          outLength.value = capacity + 1;
          return _outOfSpace;
        }),
        throwsA(
          isA<GhosttyException>().having(
            (e) => e.code,
            'code',
            GhosttyResultCode.outOfSpace,
          ),
        ),
      );
    });

    test('propagates other errors', () {
      expect(
        () => callWithSizeQuery(
          'fake',
          (_, _, _) => GhosttyResult.GHOSTTY_UNSUPPORTED,
        ),
        throwsUnsupportedError,
      );
    });

    test('tryCallWithBuffer follows the GhosttyBuffer convention', () {
      final payload = utf8.encode('grapheme ✓');
      final capacities = <int>[];
      final bytes = tryCallWithBuffer('fake', (buffer) {
        final ref = buffer.ref;
        capacities.add(ref.cap);
        ref.len = payload.length;
        if (ref.cap < payload.length) return _outOfSpace;
        ref.ptr.asTypedList(payload.length).setAll(0, payload);
        return 0;
      }, initialCapacity: 2);
      expect(utf8.decode(bytes!), 'grapheme ✓');
      expect(capacities, [2, payload.length]);
    });

    test('tryCallWithCodepointBuffer retries with the reported count', () {
      const codepoints = [0x65, 0x301, 0x1F600];
      final capacities = <int>[];
      final result = tryCallWithCodepointBuffer('fake', (buffer) {
        final ref = buffer.ref;
        capacities.add(ref.cap);
        final written = ref.cap < codepoints.length
            ? ref.cap
            : codepoints.length;
        ref.ptr.asTypedList(written).setAll(0, codepoints.take(written));
        ref.len = codepoints.length;
        return written < codepoints.length ? _outOfSpace : 0;
      }, initialCapacity: 1);
      expect(result, codepoints);
      expect(capacities, [1, 3]);
      expect(tryCallWithCodepointBuffer('fake', (_) => _noValue), isNull);
    });
  });

  group('sized structs', () {
    test('initSized zeroes the struct and sets its size', () {
      using((arena) {
        final usage = arena<GhosttyTerminalMemoryUsage>();
        usage
            .cast<Uint8>()
            .asTypedList(sizeOf<GhosttyTerminalMemoryUsage>())
            .fillRange(0, sizeOf<GhosttyTerminalMemoryUsage>(), 0xaa);
        usage.initSized(sizeOf<GhosttyTerminalMemoryUsage>());
        expect(usage.ref.size, sizeOf<GhosttyTerminalMemoryUsage>());
        final rest = usage
            .cast<Uint8>()
            .asTypedList(sizeOf<GhosttyTerminalMemoryUsage>())
            .skip(sizeOf<Size>());
        expect(rest, everyElement(0));
      });
    });

    test('an initialised sized struct is accepted by the library', () {
      withTerminal(10, 4, (terminal) {
        using((arena) {
          final usage = arena<GhosttyTerminalMemoryUsage>()
            ..initSized(sizeOf<GhosttyTerminalMemoryUsage>());
          checkResult(
            ghostty_terminal_get(
              handleOf<GhosttyTerminalImpl>(terminal).pointer,
              GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MEMORY_USAGE,
              usage.cast(),
            ),
            'ghostty_terminal_get',
          );
        });
      });
    });
  });

  group('GrowableNativeBuffer', () {
    test('grows and disposes idempotently', () {
      final buffer = GrowableNativeBuffer(4);
      expect(buffer.capacity, 4);
      buffer.ensureCapacity(2);
      expect(buffer.capacity, 4);
      buffer.ensureCapacity(100);
      expect(buffer.capacity, greaterThanOrEqualTo(100));
      buffer.pointer.asTypedList(100).fillRange(0, 100, 1);
      buffer
        ..dispose()
        ..dispose();
      expect(() => buffer.pointer, throwsStateError);
      expect(() => buffer.ensureCapacity(1), throwsStateError);
    });
  });
}
