// Shared assertion helpers for every module's tests.

import 'dart:convert';

import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

/// Checks that [codec] maps every known member of [values] to the raw C
/// constant in [expected] and back, that [expected] covers every member but
/// [unknown], that unknown raw values (including `GHOSTTY_ENUM_MAX_VALUE`)
/// decode to [unknown], and that encoding [unknown] throws.
///
/// Pass the bindings constants (not literals) in [expected], so a value
/// renumbered by a new header fails here.
void expectCodec<E extends Enum>(
  RawEnumCodec<E> codec,
  List<E> values,
  E unknown,
  Map<E, int> expected,
) {
  expect(
    expected.keys.toSet(),
    values.toSet()..remove(unknown),
    reason: 'every known member is mapped',
  );
  expected.forEach((value, raw) {
    expect(codec.encode(value), raw, reason: '$value');
    expect(codec.decode(raw), value, reason: '$value');
  });
  expect(codec.decode(9999), unknown);
  expect(codec.decode(-1), unknown);
  expect(codec.decode(GHOSTTY_ENUM_MAX_VALUE), unknown);
  expect(() => codec.encode(unknown), throwsArgumentError);
}

/// Encoded bytes as a readable string: one character per byte (Latin-1, so
/// high bytes stay distinct), with ESC shown as `ESC`.
String showEscapes(List<int> bytes) =>
    latin1.decode(bytes).replaceAll('\x1b', 'ESC');
