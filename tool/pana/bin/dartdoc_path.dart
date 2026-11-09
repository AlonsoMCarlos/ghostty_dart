// Prints the path of the locked dartdoc's `bin/dartdoc.dart`, resolved from
// this package's package config (so relative or percent-encoded `rootUri`s
// resolve correctly). Used by run_pana.sh; exits 1 if dartdoc is missing.

import 'dart:io';
import 'dart:isolate';

void main() {
  final lib = Isolate.resolvePackageUriSync(Uri.parse('package:dartdoc/'));
  final bin = lib == null
      ? null
      : File.fromUri(lib.resolve('../bin/dartdoc.dart'));
  if (bin == null || !bin.existsSync()) {
    stderr.writeln(
      'error: dartdoc is not in tool/pana/.dart_tool/package_config.json; '
      'run `dart pub get --enforce-lockfile` in tool/pana',
    );
    exitCode = 1;
    return;
  }
  stdout.writeln(bin.path);
}
