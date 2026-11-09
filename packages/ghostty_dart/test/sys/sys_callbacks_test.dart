// The Dart sys callbacks, checked in a separate process (see sys_probe.dart
// for why they cannot run inside the shared `dart test` process).
//
// setUpAll runs the probe once (about a second) and parses the one JSON
// object it prints; each test then only asserts on its keys. The probe runs
// on the test's own VM executable, not `dart run`: the VM finds the native
// asset mapping `dart test` already wrote in .dart_tool/, while `dart run`
// would re-bundle the library, which fails on Windows because this process
// holds the DLL open.
// To debug a failure, run `dart run test/sys/sys_probe.dart` from the
// package root and read the JSON.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

void main() {
  late Map<String, Object?> probe;
  late String probeStderr;

  setUpAll(() async {
    final library = Isolate.resolvePackageUriSync(
      Uri.parse('package:ghostty_dart/ghostty_dart.dart'),
    )!;
    final packageRoot = library.resolve('..').toFilePath();
    final result = await Process.run(Platform.resolvedExecutable, [
      'test/sys/sys_probe.dart',
    ], workingDirectory: packageRoot);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    probeStderr = result.stderr as String;
    // A `dart` launcher may print build-hook output before the probe's JSON.
    final stdout = result.stdout as String;
    probe =
        jsonDecode(stdout.substring(stdout.indexOf('{')))
            as Map<String, Object?>;
  });

  group('setVtLogHandler', () {
    test('delivers level, scope and message', () {
      final messages = probe['logFirst']! as List<Object?>;
      expect(messages, isNotEmpty);
      expect(
        messages,
        anyElement(['warning', 'kitty_gfx', contains('EINVAL')]),
      );
      expect(
        messages,
        anyElement(['warning', '', startsWith('unexpected length image id=1')]),
      );
    });

    test('a new handler replaces the old one', () {
      expect(probe['logReplacedOld'], 0);
      expect(probe['logReplacedNew'], greaterThan(0));
    });

    test('errors go to the installing zone and the terminal carries on', () {
      expect(probe['logAfterThrow'], 20);
      expect(probe['zoneErrors'], containsAll(['Bad state: handler failed']));
    });

    test('null discards messages, and a handler can be set again', () {
      expect(probe['logCleared'], 0);
      expect(probe['logReinstalled'], greaterThan(0));
    });
  });

  group('useVtStderrLogging', () {
    test('formats messages on stderr and replaces the Dart handler', () {
      expect(probeStderr, contains('[warning](kitty_gfx): '));
      expect(probe['stderrDelivered'], 0);
    });
  });

  group('setVtPngDecoder', () {
    test('decodes PNG transmissions into stored RGBA images', () {
      expect(probe['pngReceived'], [
        [9, 8, 7],
      ]);
      expect(probe['pngImage'], [1, 2, 'rgba']);
      expect(probe['pngPixels'], [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('null results and errors reject the image', () {
      expect(probe['pngNull'], isFalse);
      expect(probe['pngThrow'], isFalse);
      expect(probe['zoneErrors'], contains('FormatException: corrupt png'));
    });

    test('clearing the decoder rejects PNG images again', () {
      expect(probe['pngCleared'], isFalse);
    });
  });

  group('setVtSecureRandomSource', () {
    test('supplies the entropy of Kitty paste passwords', () {
      expect(probe['randomLengths'], [44]);
      // Every byte is 7, which the password alphabet maps to '9'.
      final password = base64.encode(utf8.encode('9' * 22));
      expect(probe['randomPty'], contains('pw=$password'));
    });

    test('false and errors make the operation fail', () {
      expect(probe['randomFalse'], 'ioError');
      expect(probe['randomThrow'], 'ioError');
      expect(probe['zoneErrors'], contains('Bad state: no entropy'));
    });

    test('null restores the platform source', () {
      expect(probe['randomCleared'], isNull);
    });
  });
}
