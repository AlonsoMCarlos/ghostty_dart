import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/snapshot/snapshot_progress.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

final _skip = libghosttyVtBuildInfo.supports(VtFeature.snapshot)
    ? null
    : 'built without snapshots';
final _hasKitty = libghosttyVtBuildInfo.supports(VtFeature.kittyGraphics);

/// A terminal with a long scrollback, styled text, a title, some modes and
/// a cursor away from the origin.
Uint8List _richSnapshot({int lines = 300}) => withTerminal(40, 8, (t) {
  t.scrollbackMaxBytes = null;
  writeText(t, List.generate(lines, (i) => 'history $i\r\n').join());
  writeText(t, '\x1b]0;saved title\x07\x1b[?2004h\x1b[?1h');
  writeText(t, '\x1b[1;31mbold red\x1b[0m plain\r\nsecond');
  return t.encodeSnapshot();
});

/// Decodes [snapshot] in one call; the caller disposes the terminal.
VtTerminal _decode(Uint8List snapshot) {
  final decoder = SnapshotDecoder(snapshot);
  try {
    return decoder.decode();
  } finally {
    decoder.dispose();
  }
}

/// Feeds [bytes] to a reader [chunk] bytes at a time.
int Function(Uint8List) _chunkedReader(Uint8List bytes, int chunk) {
  var offset = 0;
  return (buffer) {
    final count = min(min(chunk, buffer.length), bytes.length - offset);
    buffer.setRange(0, count, bytes, offset);
    offset += count;
    return count;
  };
}

/// The first ten cells of the oldest scrollback row.
String _oldestRow(VtTerminal t) => [
  for (var x = 0; x < 10; x++) t.gridRef(GridPoint.screen(x, 0))!.text,
].join().trimRight();

/// A copy of [bytes] with the byte at [index] inverted.
Uint8List _flipByte(Uint8List bytes, int index) {
  final copy = Uint8List.fromList(bytes);
  copy[index] ^= 0xFF;
  return copy;
}

void main() {
  group('round trip', skip: _skip, () {
    test('restores text, styles, cursor, title, modes and scrollback', () {
      final restored = _decode(_richSnapshot());
      addTearDown(restored.dispose);
      expect((restored.cols, restored.rows), (40, 8));
      expect(screenText(restored), endsWith('bold red plain\nsecond'));
      expect(restored.title, 'saved title');
      expect((restored.cursorX, restored.cursorY), (6, 7));
      expect(restored.isModeEnabled(TerminalMode.bracketedPaste), isTrue);
      expect(restored.isModeEnabled(TerminalMode.cursorKeys), isTrue);
      expect(restored.isModeEnabled(TerminalMode.focusEvent), isFalse);
      final style = restored.gridRef(const GridPoint.active(0, 6))!.style;
      expect(style.bold, isTrue);
      expect(style.foreground, PaletteColor.red);
      expect(
        restored.gridRef(const GridPoint.active(10, 6))!.style.isDefault,
        isTrue,
      );
      expect(restored.scrollbackRows, greaterThan(280));
      expect(_oldestRow(restored), 'history 0');
    });

    test('restores the alternate screen and the primary behind it', () {
      final snapshot = withTerminal(20, 4, (t) {
        writeText(t, 'primary text\x1b[?1049h\x1b[2J\x1b[Halt text');
        return t.encodeSnapshot();
      });
      final restored = _decode(snapshot);
      addTearDown(restored.dispose);
      expect(restored.activeScreen, TerminalScreen.alternate);
      expect(screenText(restored), 'alt text');
      writeText(restored, '\x1b[?1049l');
      expect(restored.activeScreen, TerminalScreen.primary);
      expect(screenText(restored), 'primary text');
    });

    test('a restored terminal behaves like the original', () {
      final snapshot = withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        return t.encodeSnapshot();
      });
      final restored = _decode(snapshot);
      addTearDown(restored.dispose);
      writeText(restored, 'def');
      expect(screenText(restored), 'abcdef');
      expect(restored.encodeSnapshot(), isNotEmpty);
    });

    test('Kitty images and their pixels survive', skip: !_hasKitty, () {
      final snapshot = withTerminal(20, 5, (t) {
        t.resize(20, 5, cellWidthPx: 10, cellHeightPx: 20);
        writeText(
          t,
          '\x1b_Ga=T,f=32,s=1,v=2,i=7,q=2;'
          '${base64.encode([1, 2, 3, 4, 5, 6, 7, 8])}\x1b\\',
        );
        return t.encodeSnapshot();
      });
      final decoder = SnapshotDecoder(snapshot);
      addTearDown(decoder.dispose);
      final restored = decoder.ready();
      addTearDown(restored.dispose);
      expect(decoder.kittyImagesPrimary, 1);
      expect(decoder.kittyPendingBytesPrimary, 8);
      expect(restored.kittyImage(7)!.hasPixels, isFalse);
      expect(restored.kittyImagePixels(7), isNull);

      final progress = <SnapshotProgress>[];
      for (var step = decoder.next(); step != null; step = decoder.next()) {
        progress.add(step);
      }
      expect(
        progress,
        contains(
          const SnapshotImagePixels(
            screen: TerminalScreen.primary,
            imageId: 7,
            frame: 1,
            bytes: 8,
          ),
        ),
      );
      expect(restored.kittyImagePixels(7), [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(restored.kittyPlacements(), hasLength(1));
    });
  });

  group('incremental decoding', skip: _skip, () {
    test('ready gives a drawable terminal and next restores history', () {
      final decoder = SnapshotDecoder(_richSnapshot(lines: 3000));
      addTearDown(decoder.dispose);
      final terminal = decoder.ready();
      addTearDown(terminal.dispose);
      expect(screenText(terminal), endsWith('second'));
      final history = decoder.historyRowsPrimary!;
      expect(history, greaterThan(2900));
      expect(decoder.historyRowsAlternate, isNull);
      final before = terminal.scrollbackRows;
      expect(before, lessThan(history));

      var pages = 0;
      var rows = 0;
      for (var step = decoder.next(); step != null; step = decoder.next()) {
        final page = step as SnapshotPage;
        expect(page.screen, TerminalScreen.primary);
        pages++;
        rows += page.rows;
      }
      expect(pages, greaterThan(1));
      expect(decoder.isFinished, isTrue);
      expect(decoder.next(), isNull);
      expect(terminal.scrollbackRows, before + rows);
      expect(terminal.scrollbackRows, history);
      expect(_oldestRow(terminal), 'history 0');
    });

    test('live input between steps is allowed', () {
      final decoder = SnapshotDecoder(_richSnapshot(lines: 3000));
      addTearDown(decoder.dispose);
      final terminal = decoder.ready();
      addTearDown(terminal.dispose);
      decoder.next();
      writeText(terminal, '\r\nlive');
      terminal.resize(50, 10);
      while (decoder.next() != null) {}
      expect(screenText(terminal), endsWith('live'));
    });

    test('next invalidates borrowed views of the terminal', () {
      final decoder = SnapshotDecoder(_richSnapshot(lines: 3000));
      addTearDown(decoder.dispose);
      final terminal = decoder.ready();
      addTearDown(terminal.dispose);
      final ref = terminal.gridRef(const GridPoint.active(0, 0))!;
      decoder.next();
      expect(ref.isValid, isFalse);
    });

    test('next cannot run from a callback of the terminal', () {
      final decoder = SnapshotDecoder(_richSnapshot(lines: 3000));
      addTearDown(decoder.dispose);
      final terminal = decoder.ready();
      addTearDown(terminal.dispose);
      Object? error;
      terminal.onBell = () {
        try {
          decoder.next();
        } catch (e) {
          error = e;
        }
      };
      writeText(terminal, '\x07');
      expect(error, isA<StateError>());
    });
  });

  group('reader', skip: _skip, () {
    test('decodes a snapshot pulled in small chunks', () {
      final snapshot = _richSnapshot();
      final decoder = SnapshotDecoder.fromReader(_chunkedReader(snapshot, 7));
      addTearDown(decoder.dispose);
      final restored = decoder.decode();
      addTearDown(restored.dispose);
      expect(screenText(restored), endsWith('bold red plain\nsecond'));
      expect(decoder.sourceOffset, snapshot.length);
    });

    test('incremental decoding pulls as it goes', () {
      final snapshot = _richSnapshot(lines: 3000);
      var reads = 0;
      final read = _chunkedReader(snapshot, 4096);
      final decoder = SnapshotDecoder.fromReader((buffer) {
        reads++;
        return read(buffer);
      });
      addTearDown(decoder.dispose);
      final terminal = decoder.ready();
      addTearDown(terminal.dispose);
      final afterReady = reads;
      while (decoder.next() != null) {}
      expect(reads, greaterThan(afterReady));
      expect(terminal.scrollbackRows, decoder.historyRowsPrimary);
    });

    test('an error thrown by the reader is rethrown and poisons', () {
      final decoder = SnapshotDecoder.fromReader(
        (_) => throw const FormatException('network down'),
      );
      addTearDown(decoder.dispose);
      expect(decoder.decode, throwsA(isA<FormatException>()));
      expect(decoder.decode, throwsStateError);
      expect(() => decoder.sourceOffset, throwsStateError);
    });

    test('a count out of range is a RangeError and poisons', () {
      final tooMany = SnapshotDecoder.fromReader((buffer) => buffer.length + 1);
      addTearDown(tooMany.dispose);
      expect(tooMany.ready, throwsRangeError);
      expect(tooMany.ready, throwsStateError);

      final negative = SnapshotDecoder.fromReader((_) => -1);
      addTearDown(negative.dispose);
      expect(negative.decode, throwsRangeError);
      expect(() => negative.maxContinuationBytes, throwsStateError);
    });

    test('an early end of input is invalid', () {
      final snapshot = _richSnapshot();
      final read = _chunkedReader(
        Uint8List.sublistView(snapshot, 0, snapshot.length ~/ 2),
        512,
      );
      final decoder = SnapshotDecoder.fromReader(read);
      addTearDown(decoder.dispose);
      expect(
        decoder.decode,
        throwsA(
          isA<GhosttyException>().having(
            (e) => e.code,
            'code',
            GhosttyResultCode.invalidValue,
          ),
        ),
      );
    });

    test('disposing from the reader is deferred until the call returns', () {
      late SnapshotDecoder decoder;
      final read = _chunkedReader(_richSnapshot(), 64);
      decoder = SnapshotDecoder.fromReader((buffer) {
        decoder.dispose();
        return read(buffer);
      });
      // The decode finishes on the still-allocated decoder and its terminal
      // belongs to the caller.
      final terminal = decoder.decode();
      addTearDown(terminal.dispose);
      expect(screenText(terminal), endsWith('second'));
      expect(decoder.isDisposed, isTrue);
    });
  });

  group('invalid input', skip: _skip, () {
    Matcher rejected() => throwsA(isA<GhosttyException>());

    test('empty, truncated and corrupt snapshots are rejected', () {
      final snapshot = _richSnapshot();
      final inputs = <String, Uint8List>{
        'empty': Uint8List(0),
        'truncated header': Uint8List.sublistView(snapshot, 0, 8),
        'truncated': Uint8List.sublistView(snapshot, 0, snapshot.length - 1),
        'garbage': Uint8List.fromList(
          List.generate(4096, (i) => Random(i).nextInt(256)),
        ),
        'flipped': _flipByte(snapshot, snapshot.length ~/ 3),
      };
      inputs.forEach((name, bytes) {
        final decoder = SnapshotDecoder(bytes);
        addTearDown(decoder.dispose);
        VtTerminal? terminal;
        try {
          terminal = decoder.decode();
        } on GhosttyException {
          expect(decoder.next, throwsStateError, reason: name);
          return;
        } finally {
          terminal?.dispose();
        }
        // A flipped byte inside cell data can still decode; anything else
        // must fail.
        expect(name, 'flipped');
      });
      expect(() => _decode(Uint8List(0)), rejected());
    });

    test('a truncated snapshot fails in next and keeps the terminal', () {
      final snapshot = _richSnapshot(lines: 3000);
      final decoder = SnapshotDecoder(
        Uint8List.sublistView(snapshot, 0, snapshot.length - 16),
      );
      addTearDown(decoder.dispose);
      final terminal = decoder.ready();
      addTearDown(terminal.dispose);
      Object? error;
      try {
        while (decoder.next() != null) {}
      } catch (e) {
        error = e;
      }
      expect(error, isA<GhosttyException>());
      expect(decoder.next, throwsStateError);
      expect(screenText(terminal), endsWith('second'));
    });

    test('trailing bytes are left unread', () {
      final snapshot = _richSnapshot(lines: 5);
      final decoder = SnapshotDecoder(
        Uint8List.fromList([...snapshot, 1, 2, 3]),
      );
      addTearDown(decoder.dispose);
      decoder.decode().dispose();
      expect(decoder.sourceOffset, snapshot.length);
    });
  });

  group('options', skip: _skip, () {
    test('report their defaults and changes', () {
      final decoder = SnapshotDecoder(_richSnapshot(lines: 5));
      addTearDown(decoder.dispose);
      expect(decoder.maxContinuationBytes, 65 * 1024 * 1024);
      expect(decoder.retainContinuation, isFalse);
      expect(decoder.compressHistory, isFalse);
      expect(
        decoder.kittyImageStorageLimit,
        VtTerminal.defaultKittyImageStorageLimit,
      );
      decoder
        ..maxContinuationBytes = 100
        ..retainContinuation = true
        ..compressHistory = true
        ..kittyImageStorageLimit = 0;
      expect(decoder.maxContinuationBytes, 100);
      expect(decoder.retainContinuation, isTrue);
      expect(decoder.compressHistory, isTrue);
      expect(decoder.kittyImageStorageLimit, 0);
      decoder
        ..maxContinuationBytes = null
        ..kittyImageStorageLimit = null;
      expect(decoder.maxContinuationBytes, 65 * 1024 * 1024);
      expect(
        decoder.kittyImageStorageLimit,
        VtTerminal.defaultKittyImageStorageLimit,
      );
      expect(() => decoder.maxContinuationBytes = -1, throwsRangeError);
      expect(() => decoder.kittyImageStorageLimit = -1, throwsRangeError);
    });

    test('freeze once decoding starts', () {
      final decoder = SnapshotDecoder(_richSnapshot(lines: 5));
      addTearDown(decoder.dispose);
      final terminal = decoder.ready();
      addTearDown(terminal.dispose);
      expect(() => decoder.compressHistory = true, throwsStateError);
      expect(() => decoder.maxContinuationBytes = 1, throwsStateError);
      expect(decoder.retainContinuation, isFalse);
    });

    test('retainContinuation restores an unfinished sequence', () {
      final snapshot = withTerminal(10, 3, (t) {
        t.continuationMaxBytes = 64;
        writeText(t, 'x\x1b]0;half a ti');
        return t.encodeSnapshot();
      });
      final decoder = SnapshotDecoder(snapshot)..retainContinuation = true;
      addTearDown(decoder.dispose);
      final restored = decoder.decode();
      addTearDown(restored.dispose);
      expect(utf8.decode(restored.continuation!), '\x1b]0;half a ti');
      writeText(restored, 'tle\x07');
      expect(restored.title, 'half a title');
    });

    test('without it the parser state is restored but not exported', () {
      final snapshot = withTerminal(10, 3, (t) {
        t.continuationMaxBytes = 64;
        writeText(t, '\x1b]0;ab');
        return t.encodeSnapshot();
      });
      final restored = _decode(snapshot);
      addTearDown(restored.dispose);
      expect(restored.continuationMaxBytes, 0);
      writeText(restored, 'c\x07');
      expect(restored.title, 'abc');
    });

    test('maxContinuationBytes 0 rejects a snapshot mid-sequence', () {
      final snapshot = withTerminal(10, 3, (t) {
        t.continuationMaxBytes = 64;
        writeText(t, '\x1b[3');
        return t.encodeSnapshot();
      });
      final decoder = SnapshotDecoder(snapshot)..maxContinuationBytes = 0;
      addTearDown(decoder.dispose);
      expect(decoder.decode, throwsA(isA<GhosttyException>()));
    });
  });

  group('lifecycle', skip: _skip, () {
    test('decode and ready are one-shot and exclusive', () {
      final decoder = SnapshotDecoder(_richSnapshot(lines: 5));
      addTearDown(decoder.dispose);
      expect(decoder.next, throwsStateError);
      decoder.decode().dispose();
      expect(decoder.isFinished, isTrue);
      expect(decoder.decode, throwsStateError);
      expect(decoder.ready, throwsStateError);
      expect(decoder.next(), isNull);
    });

    test('disposing the terminal disposes the decoder first', () {
      final decoder = SnapshotDecoder(_richSnapshot(lines: 3000));
      final terminal = decoder.ready();
      terminal.dispose();
      expect(decoder.isDisposed, isTrue);
      expect(decoder.next, throwsStateError);
    });

    test('disposing the decoder keeps the terminal', () {
      final decoder = SnapshotDecoder(_richSnapshot(lines: 3000));
      final terminal = decoder.ready();
      addTearDown(terminal.dispose);
      decoder.next();
      decoder
        ..dispose()
        ..dispose();
      expect(terminal.isDisposed, isFalse);
      writeText(terminal, '\r\nafter');
      expect(screenText(terminal), endsWith('after'));
      expect(terminal.scrollbackRows, greaterThan(0));
    });

    test('members throw StateError after dispose', () {
      final decoder = SnapshotDecoder(_richSnapshot(lines: 5))..dispose();
      expect(decoder.decode, throwsStateError);
      expect(decoder.ready, throwsStateError);
      expect(decoder.next, throwsStateError);
      expect(() => decoder.isFinished, throwsStateError);
      expect(() => decoder.sourceOffset, throwsStateError);
      expect(() => decoder.historyRowsPrimary, throwsStateError);
      expect(() => decoder.compressHistory = true, throwsStateError);
    });

    test('many forgotten decoders do not crash the finalizers', () {
      final snapshot = _richSnapshot(lines: 5);
      for (var i = 0; i < 200; i++) {
        SnapshotDecoder(snapshot);
        SnapshotDecoder.fromReader(_chunkedReader(snapshot, 100));
      }
    });
  });

  group('progress values', () {
    test('equality and toString', () {
      const page = SnapshotPage(
        screen: TerminalScreen.primary,
        rows: 10,
        remaining: 2,
      );
      expect(
        page,
        const SnapshotPage(
          screen: TerminalScreen.primary,
          rows: 10,
          remaining: 2,
        ),
      );
      expect(
        page.hashCode,
        isNot(
          const UnknownSnapshotProgress(
            screen: TerminalScreen.primary,
          ).hashCode,
        ),
      );
      expect(page.toString(), contains('10 rows'));
      const pixels = SnapshotImagePixels(
        screen: TerminalScreen.alternate,
        imageId: 1,
        frame: 2,
        bytes: 3,
      );
      expect(pixels, isNot(page));
      expect(pixels.toString(), contains('frame 2'));
    });

    test('the progress kind matches GhosttySnapshotDecoderProgressKind', () {
      const expected = {
        SnapshotProgressKind.page: GhosttySnapshotDecoderProgressKind
            .GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_PAGE,
        SnapshotProgressKind.image: GhosttySnapshotDecoderProgressKind
            .GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_IMAGE,
      };
      expected.forEach((kind, raw) {
        expect(snapshotProgressKindCodec.encode(kind), raw);
        expect(snapshotProgressKindCodec.decode(raw), kind);
      });
      expect(
        snapshotProgressKindCodec.decode(GHOSTTY_ENUM_MAX_VALUE),
        SnapshotProgressKind.unknown,
      );
    });
  });
}
