/// `cat` at a fixed rate: the pty child of the attribution benchmark
/// (`lib/attribution_main.dart`), standing in for a program such as
/// `tree ~` that produces output at its own pace.
///
/// Usage: `dart tool/paced_cat.dart <file> <kB/s>` (0: as fast as the pty
/// takes it). Writes the file to stdout in 4 KiB blocking writes, so a
/// full pty buffer stops the writer, as it stops a real program.
library;

import 'dart:io';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: paced_cat.dart <file> <kB/s>');
    exit(2);
  }
  final data = File(args[0]).readAsBytesSync();
  final rate = int.parse(args[1]);
  // writeOnly, not append: appending seeks, which a tty refuses.
  final out = File('/dev/stdout').openSync(mode: FileMode.writeOnly);
  const block = 4096;
  final clock = Stopwatch()..start();
  var sent = 0;
  while (sent < data.length) {
    final allowed = rate == 0
        ? data.length
        : (clock.elapsedMicroseconds * rate / 1000).floor();
    if (sent >= allowed) {
      sleep(const Duration(milliseconds: 1));
      continue;
    }
    var end = sent + block;
    if (end > allowed) end = allowed;
    if (end > data.length) end = data.length;
    out.writeFromSync(data, sent, end);
    sent = end;
  }
  out.closeSync();
}
