/// Writes the attribution benchmark's fixture: [treeStream]'s `tree`-like
/// output with LF line ends, as the program writes it (the pty's `onlcr`
/// adds the CRs back on the way to the terminal).
///
/// Usage: `dart tool/attribution_fixture.dart <file> <MB>`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ghostty_dart_widget_benchmarks/src/firehose.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: attribution_fixture.dart <file> <MB>');
    exit(2);
  }
  final crlf = treeStream(int.parse(args[1]));
  final lf = Uint8List.fromList([
    for (final byte in crlf)
      if (byte != 0x0D) byte,
  ]);
  File(args[0])
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(lf);
}
