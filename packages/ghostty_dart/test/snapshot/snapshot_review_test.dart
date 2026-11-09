// Adversarial tests from the correctness review of the snapshot module
// (T09).

import 'dart:math';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

final _skip = libghosttyVtBuildInfo.supports(VtFeature.snapshot)
    ? null
    : 'built without snapshots';

Uint8List _historySnapshot(int lines) => withTerminal(40, 8, (t) {
  t.scrollbackMaxBytes = null;
  writeText(t, List.generate(lines, (i) => 'history $i\r\n').join());
  return t.encodeSnapshot();
});

Matcher _ghostty(GhosttyResultCode code) =>
    throwsA(isA<GhosttyException>().having((e) => e.code, 'code', code));

void main() {
  group('reader contract', skip: _skip, () {
    test('a reader that always fills the whole buffer works', () {
      final snapshot = _historySnapshot(200);
      var offset = 0;
      final decoder = SnapshotDecoder.fromReader((buffer) {
        final count = min(buffer.length, snapshot.length - offset);
        buffer.setRange(0, count, snapshot, offset);
        offset += count;
        return count;
      });
      addTearDown(decoder.dispose);
      final terminal = decoder.decode();
      addTearDown(terminal.dispose);
      expect(decoder.sourceOffset, snapshot.length);
      expect(screenText(terminal), contains('history 199'));
    });

    test('an empty source is rejected by both constructors', () {
      final fromBytes = SnapshotDecoder(Uint8List(0));
      addTearDown(fromBytes.dispose);
      expect(fromBytes.decode, _ghostty(GhosttyResultCode.invalidValue));

      final fromReader = SnapshotDecoder.fromReader((_) => 0);
      addTearDown(fromReader.dispose);
      expect(fromReader.ready, _ghostty(GhosttyResultCode.invalidValue));
      expect(fromReader.ready, throwsStateError);
    });

    test('a reader failing in next invalidates borrowed views and keeps '
        'the terminal', () {
      final snapshot = _historySnapshot(3000);
      var offset = 0;
      var fail = false;
      final decoder = SnapshotDecoder.fromReader((buffer) {
        if (fail) throw const FormatException('gone');
        final count = min(min(512, buffer.length), snapshot.length - offset);
        buffer.setRange(0, count, snapshot, offset);
        offset += count;
        return count;
      });
      addTearDown(decoder.dispose);
      final terminal = decoder.ready();
      addTearDown(terminal.dispose);
      expect(decoder.next(), isA<SnapshotPage>());

      final ref = terminal.gridRef(const GridPoint.active(0, 0))!;
      fail = true;
      SnapshotProgress? progress;
      Object? error;
      try {
        // The reader may not be asked for more bytes until a few records
        // later, so step until it is.
        do {
          progress = decoder.next();
        } while (progress != null);
      } on FormatException catch (e) {
        error = e;
      }
      expect(error, isA<FormatException>());
      expect(ref.isValid, isFalse);
      expect(decoder.next, throwsStateError);
      writeText(terminal, '\r\nalive');
      expect(screenText(terminal), endsWith('alive'));
    });
  });

  group('round trip', skip: _skip, () {
    test('wide, combining and emoji text survives', () {
      const text = '日本語 é 🎉 ok';
      final snapshot = withTerminal(30, 3, (t) {
        writeText(t, text);
        return t.encodeSnapshot();
      });
      final decoder = SnapshotDecoder(snapshot);
      addTearDown(decoder.dispose);
      final terminal = decoder.decode();
      addTearDown(terminal.dispose);
      expect(screenText(terminal), text);
    });

    test('a decoded terminal can be snapshotted again', () {
      final first = _historySnapshot(50);
      final decoder = SnapshotDecoder(first);
      addTearDown(decoder.dispose);
      final terminal = decoder.decode();
      addTearDown(terminal.dispose);
      final second = terminal.encodeSnapshot();
      final again = SnapshotDecoder(second);
      addTearDown(again.dispose);
      final restored = again.decode();
      addTearDown(restored.dispose);
      expect(screenText(restored), screenText(terminal));
      expect(restored.scrollbackRows, terminal.scrollbackRows);
    });
  });

  group('ownership', skip: _skip, () {
    test('a decoder dropped mid-stream leaves a usable terminal', () {
      final snapshot = _historySnapshot(3000);
      final terminals = <VtTerminal>[];
      for (var i = 0; i < 20; i++) {
        // The decoder is never disposed: its finalizer must not touch the
        // terminal it borrowed.
        final decoder = SnapshotDecoder(snapshot);
        terminals.add(decoder.ready());
        decoder.next();
      }
      for (final t in terminals) {
        writeText(t, '\r\nok');
        expect(screenText(t), endsWith('ok'));
        t.dispose();
      }
    });

    test('a terminal disposed from the reader fails the step cleanly', () {
      final snapshot = _historySnapshot(3000);
      var offset = 0;
      VtTerminal? terminal;
      final decoder = SnapshotDecoder.fromReader((buffer) {
        terminal?.dispose();
        final count = min(min(256, buffer.length), snapshot.length - offset);
        buffer.setRange(0, count, snapshot, offset);
        offset += count;
        return count;
      });
      terminal = decoder.ready();
      // The terminal and the decoder are freed after the native call
      // returns; reading the progress then reports the disposal.
      Object? error;
      try {
        while (decoder.next() != null) {}
      } on StateError catch (e) {
        error = e;
      }
      expect(error, isA<StateError>());
      expect(terminal.isDisposed, isTrue);
      expect(decoder.isDisposed, isTrue);
    });
  });
}
