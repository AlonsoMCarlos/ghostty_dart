import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_widget_benchmarks/src/firehose.dart';

final _sgr = RegExp(r'\x1b\[[0-9;]*m');

void main() {
  test('the tree stream is deterministic, line-shaped and coloured', () {
    final bytes = treeStream(1);
    expect(bytes.length, greaterThanOrEqualTo(1000000));
    expect(treeStream(1), bytes);
    expect(treeStream(1, seed: 7), isNot(bytes));
    final text = utf8.decode(bytes);
    expect(text, endsWith('\r\n'));
    final lines = text.split('\r\n')..removeLast();
    expect(lines.length, greaterThan(10000));
    for (final line in lines.take(2000)) {
      final plain = line.replaceAll(_sgr, '');
      expect(plain, matches(RegExp(r'^((│|\s)   )*(├|└)── \S+$')));
      // Short lines: no soft wrap at the benchmark's 200 columns.
      expect(plain.length, lessThan(200));
    }
    expect(text, contains('\x1b[01;34m')); // directories
    expect(text, contains('\x1b[01;32m')); // executables
  });

  test('the ASCII variant has the same shape without box drawing', () {
    final text = utf8.decode(treeStream(1, ascii: true));
    expect(text.runes.every((r) => r < 0x80), isTrue);
    expect(text, contains('|-- '));
    expect(text, contains('`-- '));
  });
}
