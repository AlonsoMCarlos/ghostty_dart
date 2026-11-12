/// A deterministic `tree -C`-like byte stream for the firehose benchmark:
/// a program that floods the terminal with short coloured lines as fast as
/// the pty takes them.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Bytes per pty read in the firehose benchmark: Linux pty reads return at
/// most 4 KiB (the N_TTY buffer), although flutter_pty2 3.0.0 reads into a
/// 16 KiB buffer (`PTY_REACTOR_BUFFER_SIZE`, `src/unix/pty_unix_session.c`).
const firehoseChunkBytes = 4096;

const _names = [
  'src',
  'lib',
  'test',
  'build',
  'node_modules',
  'index',
  'main',
  'utils',
  'config',
  'README',
  'package',
  'module',
  'widget',
  'render',
  'cache',
  'assets',
  'image',
  'data',
  'vendor',
  'include',
];

const _extensions = [
  '.dart',
  '.c',
  '.h',
  '.js',
  '.json',
  '.md',
  '.png',
  '.txt',
  '.so',
  '',
];

/// [megabytes] MB (10^6 bytes, rounded up to whole lines) of `tree -C`
/// output after the pty's `onlcr`: box-drawing indentation (`│   `,
/// `├── `, `└── `), bold blue directories, green executables and plain
/// files, CRLF line ends. Generated from `Random(seed)`, so every run sees
/// the same bytes. With [ascii] the indentation is `tree --charset=ascii`'s
/// (`|   `, `|-- `, `` `-- ``) instead.
Uint8List treeStream(int megabytes, {int seed = 42, bool ascii = false}) {
  final random = Random(seed);
  final out = BytesBuilder(copy: false);
  final target = megabytes * 1000000;
  var length = 0;
  var depth = 0;
  final line = StringBuffer();
  while (length < target) {
    line.clear();
    for (var i = 0; i < depth; i++) {
      line.write(random.nextInt(4) == 0 ? '    ' : (ascii ? '|   ' : '│   '));
    }
    line.write(
      random.nextInt(6) == 0
          ? (ascii ? '`-- ' : '└── ')
          : (ascii ? '|-- ' : '├── '),
    );
    final name =
        '${_names[random.nextInt(_names.length)]}_${random.nextInt(100000)}';
    final kind = random.nextInt(10);
    if (kind < 2) {
      line.write('\x1b[01;34m$name\x1b[00m');
      if (depth < 12) depth++;
    } else if (kind == 2) {
      line.write('\x1b[01;32m$name\x1b[00m');
    } else {
      line.write('$name${_extensions[random.nextInt(_extensions.length)]}');
      if (depth > 0 && random.nextInt(5) == 0) depth--;
    }
    line.write('\r\n');
    final bytes = utf8.encode(line.toString());
    out.add(bytes);
    length += bytes.length;
  }
  return out.takeBytes();
}
