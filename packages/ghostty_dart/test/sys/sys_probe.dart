// Exercises the Dart sys callbacks (log handler, PNG decoder, secure random
// source) and prints one JSON object with what it observed.
//
// It runs in its own process, started by sys_callbacks_test.dart: these
// handlers are process-wide `NativeCallable.isolateLocal` callables, and
// `dart test` runs the other suites as concurrent isolates of one process.
// If one of them triggered a log message while a handler of this isolate
// was installed, the VM would abort the whole test run.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';

/// Transmits an RGBA image whose payload is 4 bytes short: the library logs
/// an "unexpected length" warning and rejects it.
const _badImage = '\x1b_Ga=t,f=32,s=2,v=2,i=1,q=2;AAAA\x1b\\';

String _png(int id, List<int> payload) =>
    '\x1b_Ga=t,f=100,i=$id,q=2;${base64.encode(payload)}\x1b\\';

void main() {
  final results = <String, Object?>{};
  final zoneErrors = <String>[];
  runZonedGuarded(() {
    final terminal = VtTerminal(cols: 20, rows: 5);
    try {
      _probeLogging(terminal, results);
      _probePng(terminal, results);
      _probeRandom(terminal, results);
    } finally {
      setVtLogHandler(null);
      setVtPngDecoder(null);
      setVtSecureRandomSource(null);
      terminal.dispose();
    }
  }, (error, _) => zoneErrors.add('$error'));
  results['zoneErrors'] = zoneErrors;
  print(jsonEncode(results));
}

void _write(VtTerminal terminal, String text) =>
    terminal.write(utf8.encode(text));

void _probeLogging(VtTerminal terminal, Map<String, Object?> results) {
  final first = <List<String>>[];
  setVtLogHandler(
    (level, scope, message) => first.add([level.name, scope, message]),
  );
  _write(terminal, _badImage);
  results['logFirst'] = first;

  final second = <String>[];
  setVtLogHandler((_, _, message) => second.add(message));
  final firstCount = first.length;
  _write(terminal, _badImage);
  results['logReplacedOld'] = first.length - firstCount;
  results['logReplacedNew'] = second.length;

  // The write must still complete: the terminal answers afterwards.
  setVtLogHandler((_, _, _) => throw StateError('handler failed'));
  _write(terminal, _badImage);
  results['logAfterThrow'] = terminal.cols;

  setVtLogHandler(null);
  final secondCount = second.length;
  _write(terminal, _badImage);
  results['logCleared'] = second.length - secondCount;

  // A handler set after clearing reuses the isolate's callable.
  final third = <String>[];
  setVtLogHandler((_, _, message) => third.add(message));
  _write(terminal, _badImage);
  results['logReinstalled'] = third.length;

  // The native logger writes to this process's stderr, which the test reads.
  final thirdCount = third.length;
  useVtStderrLogging();
  _write(terminal, _badImage);
  results['stderrDelivered'] = third.length - thirdCount;
  setVtLogHandler(null);
}

void _probePng(VtTerminal terminal, Map<String, Object?> results) {
  final received = <List<int>>[];
  setVtPngDecoder((png) {
    received.add(png);
    return RgbaImage(
      width: 1,
      height: 2,
      pixels: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
    );
  });
  _write(terminal, _png(10, [9, 8, 7]));
  final image = terminal.kittyImage(10);
  results['pngReceived'] = received;
  results['pngImage'] = image == null
      ? null
      : [image.width, image.height, image.format.name];
  results['pngPixels'] = terminal.kittyImagePixels(10);

  setVtPngDecoder((_) => null);
  _write(terminal, _png(11, [1]));
  results['pngNull'] = terminal.kittyImage(11) != null;

  setVtPngDecoder((_) => throw const FormatException('corrupt png'));
  _write(terminal, _png(12, [1]));
  results['pngThrow'] = terminal.kittyImage(12) != null;

  setVtPngDecoder(null);
  _write(terminal, _png(13, [1]));
  results['pngCleared'] = terminal.kittyImage(13) != null;
}

void _probeRandom(VtTerminal terminal, Map<String, Object?> results) {
  final pty = BytesBuilder();
  terminal
    ..onWritePty = pty.add
    ..onClipboardRead = (_) => null;
  _write(terminal, '\x1b[?5522h');

  final lengths = <int>[];
  setVtSecureRandomSource((buffer) {
    lengths.add(buffer.length);
    buffer.fillRange(0, buffer.length, 7);
    return true;
  });
  terminal.pasteText('hi');
  results['randomLengths'] = lengths;
  results['randomPty'] = latin1.decode(pty.takeBytes());

  setVtSecureRandomSource((_) => false);
  results['randomFalse'] = _pasteError(terminal);

  setVtSecureRandomSource((_) => throw StateError('no entropy'));
  results['randomThrow'] = _pasteError(terminal);

  setVtSecureRandomSource(null);
  results['randomCleared'] = _pasteError(terminal);
  terminal
    ..onWritePty = null
    ..onClipboardRead = null;
}

/// Pastes and returns the error it threw, or `null`.
String? _pasteError(VtTerminal terminal) {
  try {
    terminal.pasteText('hi');
    return null;
  } on GhosttyException catch (error) {
    return error.code.name;
  }
}
