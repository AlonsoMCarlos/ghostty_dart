// Tests of the test-font loader (test/support/fonts.dart): its SHA-256
// against the FIPS 180-4 / NIST example vectors, and the pinned files.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../support/fonts.dart';

String _sha(String text) => sha256Hex(Uint8List.fromList(utf8.encode(text)));

void main() {
  group('sha256Hex', () {
    test('empty message', () {
      expect(
        _sha(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('"abc" (one block)', () {
      expect(
        _sha('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('the 448-bit message (padding spills into a second block)', () {
      expect(
        _sha('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('one million "a"', () {
      expect(
        _sha('a' * 1000000),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });
  });

  test('every bundled file matches its pinned hash', () {
    if (skipWithoutBundledFonts) {
      markTestSkipped('fonts not bundled');
      return;
    }
    for (final MapEntry(key: path, value: expected)
        in jetBrainsMonoSha256.entries) {
      expect(sha256Hex(File(path).readAsBytesSync()), expected, reason: path);
    }
  });
}
