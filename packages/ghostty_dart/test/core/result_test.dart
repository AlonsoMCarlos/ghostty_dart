import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

void main() {
  group('GhosttyResultCode', () {
    test('matches every GhosttyResult constant', () {
      const raw = {
        GhosttyResultCode.success: GhosttyResult.GHOSTTY_SUCCESS,
        GhosttyResultCode.outOfMemory: GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        GhosttyResultCode.invalidValue: GhosttyResult.GHOSTTY_INVALID_VALUE,
        GhosttyResultCode.outOfSpace: GhosttyResult.GHOSTTY_OUT_OF_SPACE,
        GhosttyResultCode.noValue: GhosttyResult.GHOSTTY_NO_VALUE,
        GhosttyResultCode.ioError: GhosttyResult.GHOSTTY_IO_ERROR,
        GhosttyResultCode.limitExceeded: GhosttyResult.GHOSTTY_LIMIT_EXCEEDED,
        GhosttyResultCode.rejected: GhosttyResult.GHOSTTY_REJECTED,
        GhosttyResultCode.unsupported: GhosttyResult.GHOSTTY_UNSUPPORTED,
      };
      expect(
        raw.keys,
        containsAll(
          GhosttyResultCode.values.toSet()..remove(GhosttyResultCode.unknown),
        ),
      );
      raw.forEach((code, value) {
        expect(resultCodec.encode(code), value, reason: code.name);
        expect(resultCodec.decode(value), code, reason: code.name);
      });
    });

    test('unknown negative codes decode to unknown', () {
      expect(decodeResult(-99), GhosttyResultCode.unknown);
      expect(GhosttyResultCode.unknown.isError, isTrue);
    });

    test('non-negative codes are successes', () {
      expect(decodeResult(0), GhosttyResultCode.success);
      expect(decodeResult(7), GhosttyResultCode.success);
      expect(GhosttyResultCode.success.isError, isFalse);
    });
  });

  group('checkResult', () {
    test('accepts success and non-negative codes', () {
      checkResult(0, 'op');
      checkResult(3, 'op');
    });

    test('throws GhosttyException carrying the code', () {
      expect(
        () => checkResult(GhosttyResult.GHOSTTY_INVALID_VALUE, 'ghostty_x'),
        throwsA(
          isA<GhosttyException>()
              .having((e) => e.code, 'code', GhosttyResultCode.invalidValue)
              .having((e) => e.rawCode, 'rawCode', -2)
              .having((e) => e.operation, 'operation', 'ghostty_x')
              .having((e) => '$e', 'toString', contains('invalidValue')),
        ),
      );
    });

    test('maps GHOSTTY_UNSUPPORTED to UnsupportedError', () {
      expect(
        () => checkResult(GhosttyResult.GHOSTTY_UNSUPPORTED, 'ghostty_x'),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('ghostty_x'),
          ),
        ),
      );
    });

    test('keeps the raw value of unknown codes', () {
      expect(
        () => checkResult(-42, 'op'),
        throwsA(
          isA<GhosttyException>()
              .having((e) => e.code, 'code', GhosttyResultCode.unknown)
              .having((e) => e.rawCode, 'rawCode', -42),
        ),
      );
    });
  });

  group('non-throwing variants', () {
    test('checkResultHasValue returns false only for NO_VALUE', () {
      expect(checkResultHasValue(0, 'op'), isTrue);
      expect(
        checkResultHasValue(GhosttyResult.GHOSTTY_NO_VALUE, 'op'),
        isFalse,
      );
      expect(
        () => checkResultHasValue(GhosttyResult.GHOSTTY_OUT_OF_SPACE, 'op'),
        throwsA(isA<GhosttyException>()),
      );
      expect(
        () => checkResultHasValue(GhosttyResult.GHOSTTY_UNSUPPORTED, 'op'),
        throwsUnsupportedError,
      );
    });

    test('checkResultAllowing returns allowed codes', () {
      const allowed = {GhosttyResultCode.outOfSpace, GhosttyResultCode.noValue};
      expect(checkResultAllowing(0, 'op', allowed), GhosttyResultCode.success);
      expect(
        checkResultAllowing(GhosttyResult.GHOSTTY_OUT_OF_SPACE, 'op', allowed),
        GhosttyResultCode.outOfSpace,
      );
      expect(
        () => checkResultAllowing(
          GhosttyResult.GHOSTTY_INVALID_VALUE,
          'op',
          allowed,
        ),
        throwsA(isA<GhosttyException>()),
      );
    });

    test('resultError builds the same errors as checkResult', () {
      expect(resultError(-8, 'op'), isA<UnsupportedError>());
      expect(resultError(-1, 'op'), isA<GhosttyException>());
    });
  });
}
