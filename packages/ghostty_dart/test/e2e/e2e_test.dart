// End-to-end tests: several modules working together on one terminal, the
// way an embedder (the Flutter widget, the xterm adapter) uses them. Only
// the public API is used.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../../example/main.dart' as example;
import '../support/terminal_support.dart';

/// A vttest-like stream: title, SGR (16, 256 and 24-bit colours, every
/// attribute), cursor addressing, erase, a scroll region, wide and
/// combining characters, an OSC 8 hyperlink, DEC modes and the alternate
/// screen (entered and left again).
const _vtStream =
    '\x1b]2;e2e title\x07'
    '\x1b]7;file://host/tmp/e2e\x07'
    '\x1b[1;31mbold red\x1b[0m \x1b[3;4mitalic underline\x1b[0m\r\n'
    '\x1b[38;5;208m256\x1b[0m \x1b[38;2;1;2;3;48;2;250;251;252mrgb\x1b[0m\r\n'
    'wide 漢字 é 👍🏽\r\n'
    '\x1b]8;id=1;https://example.com/e2e\x1b\\link\x1b]8;;\x1b\\\r\n'
    '\x1b[10;1Hrow ten\x1b[5;20Hxy\x1b[1K'
    '\x1b[6;9r\x1b[9;1H\r\n\x1b[r'
    '\x1b[?1h\x1b[?2004h\x1b[?1049h\x1b[2Jalt screen\x1b[?1049l'
    '\x1b[12;1Hfind me here';

void main() {
  group('one stream through every module', () {
    late VtTerminal terminal;

    setUp(() {
      terminal = VtTerminal(cols: 40, rows: 12);
      writeText(terminal, _vtStream);
    });
    tearDown(() => terminal.dispose());

    test('terminal state', () {
      expect(terminal.title, 'e2e title');
      expect(terminal.pwd, 'file://host/tmp/e2e');
      expect(terminal.activeScreen, TerminalScreen.primary);
      expect(terminal.isModeEnabled(TerminalMode.cursorKeys), isTrue);
      expect(terminal.isModeEnabled(TerminalMode.bracketedPaste), isTrue);
      expect(terminal.isVtGround, isTrue);
      expect((terminal.cursorX, terminal.cursorY), (12, 11));
    });

    test('render state agrees with the formatter and grid refs', () {
      final state = RenderState()..update(terminal);
      final formatter = TerminalFormatter(terminal);
      try {
        final rendered = [
          for (final row in state.allRows)
            [
              for (var x = 0; x < row.length; x++)
                if (!row.widthAt(x).isSpacer)
                  row.hasTextAt(x) ? row.textAt(x) : ' ',
            ].join().trimRight(),
        ];
        expect(
          rendered.join('\n').trimRight(),
          formatter.formatText().trimRight(),
        );
        expect(rendered[0], 'bold red italic underline');
        expect(rendered[2], 'wide 漢字 é 👍🏽');
        expect(rendered[4], isNot(contains('xy')), reason: 'EL 1 erased it');
        expect(rendered.any((r) => r.contains('alt screen')), isFalse);

        // The same cell through the render state and a grid ref.
        final ref = terminal.gridRef(const GridPoint.active(0, 0))!;
        expect(ref.text, 'b');
        expect(ref.style.bold, isTrue);
        expect(ref.style.foreground, PaletteColor.red);
        final row0 = state.allRows.first;
        expect(row0.styleAt(0), ref.style);
        final rgb = terminal.gridRef(const GridPoint.active(4, 1))!;
        expect(rgb.style.foreground, const RgbColor(1, 2, 3));
        expect(rgb.style.background, const RgbColor(250, 251, 252));
        final link = terminal.gridRef(const GridPoint.active(0, 3))!;
        expect(link.hyperlinkUri, 'https://example.com/e2e');
        expect(link.cell.hasHyperlink, isTrue);
        final wide = terminal.gridRef(const GridPoint.active(5, 2))!;
        expect(wide.cell.width, CellWidth.wide);
        expect(textCellWidth('漢'), 2);
      } finally {
        formatter.dispose();
        state.dispose();
      }
    });

    test('selection, search and formatting', () {
      final selection = terminal.selectWord(const GridPoint.active(5, 0))!;
      final formatter = TerminalFormatter(terminal);
      final search = TerminalSearch(terminal, needle: 'find me');
      try {
        expect(formatter.formatText(selection: selection), 'red');
        terminal.selection = selection;
        expect(terminal.selection, isNotNull);
        search.run();
        expect(search.totalMatches, 1);
        final match = search.matches.single;
        expect(match.start.pointIn(PointSpace.active), GridPoint.active(0, 11));
        expect(formatter.formatText(selection: match), 'find me');
        formatter.format = TextFormat.html;
        expect(formatter.formatText(), contains('https://example.com/e2e'));
        formatter.format = TextFormat.vt;
        final replay = VtTerminal(cols: 40, rows: 12);
        try {
          replay.write(formatter.formatBytes());
          expect(screenText(replay), screenText(terminal));
        } finally {
          replay.dispose();
        }
      } finally {
        search.dispose();
        formatter.dispose();
      }
    });

    test('a snapshot restores the same screen and state', () {
      final restored = SnapshotDecoder(terminal.encodeSnapshot()).decode();
      try {
        expect(screenText(restored), screenText(terminal));
        expect(restored.title, terminal.title);
        expect(restored.cursor, terminal.cursor);
        expect(
          restored.isModeEnabled(TerminalMode.bracketedPaste),
          terminal.isModeEnabled(TerminalMode.bracketedPaste),
        );
      } finally {
        restored.dispose();
      }
    });

    test('encoders follow the terminal modes', () {
      final keys = KeyEncoder()..setFromTerminal(terminal);
      try {
        // DECCKM (?1h) is on: arrows are SS3.
        expect(keys.encode(const VtKeyEvent(key: VtKey.arrowUp)), [
          0x1b,
          0x4f,
          0x41,
        ]);
      } finally {
        keys.dispose();
      }
      // Bracketed paste (?2004h) is on, so paste is wrapped.
      final pasted = <int>[];
      terminal.onWritePty = pasted.addAll;
      terminal.pasteText('hi');
      expect(utf8.decode(pasted), '\x1b[200~hi\x1b[201~');
    });

    test('parsers decode the same sequences the terminal saw', () {
      final osc = OscParser();
      final sgr = SgrParser();
      try {
        final title = osc.parse(utf8.encode('2;e2e title'));
        expect(title, const OscWindowTitleCommand('e2e title'));
        expect(sgr.parseString('38;2;1;2;3'), [
          const SgrForeground(RgbColor(1, 2, 3), SgrColorForm.direct),
        ]);
      } finally {
        osc.dispose();
        sgr.dispose();
      }
    });
  });

  group('fake shell loop', () {
    test('replies written to the pty are fed back through the shell', () {
      withTerminal(40, 6, (terminal) {
        final shell = _FakeShell(terminal);
        terminal.onWritePty = shell.receive;
        final keys = KeyEncoder();
        addTearDown(keys.dispose);
        shell.start();
        void type(String text) {
          for (final rune in text.runes) {
            final char = String.fromCharCode(rune);
            shell.receive(
              keys.encode(VtKeyEvent(key: _keyOf(char), text: char)),
            );
          }
          shell.receive(keys.encode(const VtKeyEvent(key: VtKey.enter)));
          shell.pump();
        }

        type('echo hi');
        type('where');
        type('id');
        expect(screenText(terminal), '''
\$ echo hi
hi
\$ where
cursor at 4,1
\$ id
device ?62;22
\$''');
        expect(shell.repliesSeen, 2);
        expect(shell.unexpectedInput, isEmpty);
      });
    });
  });

  group('stress', () {
    test('large output, scrollback limits, search and render', () {
      withTerminal(80, 24, (terminal) {
        terminal
          ..scrollbackMaxBytes = null
          ..scrollbackMaxLines = 5000;
        const total = 60000;
        final chunk = StringBuffer();
        for (var i = 0; i < total; i++) {
          chunk.write('\x1b[3${i % 8}mline $i\x1b[0m ${'x' * (i % 50)}\r\n');
          if (chunk.length > 1 << 16) {
            writeText(terminal, chunk.toString());
            chunk.clear();
          }
        }
        writeText(terminal, '${chunk}done');

        expect(terminal.scrollbackRows, lessThanOrEqualTo(5000));
        expect(terminal.scrollbackRows, greaterThan(4000));
        expect(terminal.totalRows, terminal.scrollbackRows + 24);
        expect(terminal.scrollbar.isAtBottom, isTrue);
        final usage = terminal.memoryUsage;
        expect(usage.primary.pages, greaterThan(0));

        final search = TerminalSearch(terminal, needle: 'line ${total - 1} ')
          ..run();
        addTearDown(search.dispose);
        expect(search.totalMatches, 1);
        search.needle = 'line 0 ';
        search.run();
        expect(search.totalMatches, 0, reason: 'evicted from the history');

        terminal.scrollViewport(const ViewportScroll.top());
        final state = RenderState()..update(terminal);
        addTearDown(state.dispose);
        final first = state.allRows.first;
        final text = StringBuffer();
        for (var x = 0; x < first.length; x++) {
          first.writeTextTo(x, text);
        }
        final oldest = int.parse(
          RegExp(r'line (\d+)').firstMatch(text.toString())!.group(1)!,
        );
        expect(oldest, greaterThan(total - 5100));
        expect(terminal.scrollbar.offset, 0);

        terminal.scrollViewport(const ViewportScroll.bottom());
        state.update(terminal);
        // Rows are borrowed views: copy what you need during iteration.
        final firstCells = [for (final row in state.allRows) row.textAt(0)];
        expect(firstCells.last, 'd');
        expect(
          terminal.compress(CompressionMode.full),
          isNot(CompressionResult.pending),
        );
      });
    });

    test('random bytes never break any reader', () {
      final random = _Lcg(42);
      withTerminal(30, 8, (terminal) {
        final state = RenderState();
        final formatter = TerminalFormatter(terminal);
        addTearDown(state.dispose);
        addTearDown(formatter.dispose);
        for (var round = 0; round < 200; round++) {
          terminal.write(
            Uint8List.fromList([for (var i = 0; i < 256; i++) random.next()]),
          );
          state.update(terminal);
          for (final row in state.dirtyRows) {
            for (var x = 0; x < row.length; x++) {
              row
                ..styleAt(x)
                ..backgroundRgbAt(x)
                ..textAt(x);
            }
          }
          formatter.formatText();
          terminal.gridRef(GridPoint.active(round % 30, round % 8))?.text;
        }
        expect(terminal.cols, 30);
      });
    });
  });

  group('dispose ordering', () {
    test('disposing the terminal disposes every dependent first', () {
      final terminal = VtTerminal(cols: 20, rows: 4);
      writeText(terminal, 'one two three');
      final formatter = TerminalFormatter(terminal);
      final search = TerminalSearch(terminal, needle: 'two')..run();
      final gesture = SelectionGesture(terminal);
      final tracked = terminal.trackGridRef(const GridPoint.active(4, 0))!;
      final selection = terminal.selectAll()!;
      final state = RenderState()..update(terminal);
      final row = state.allRows.first;

      terminal.dispose();
      expect(formatter.isDisposed, isTrue);
      expect(search.isDisposed, isTrue);
      expect(gesture.isDisposed, isTrue);
      expect(tracked.isDisposed, isTrue);
      expect(selection.isValid, isFalse);
      expect(() => formatter.formatText(), throwsStateError);
      expect(() => search.totalMatches, throwsStateError);
      expect(() => gesture.clickCount, throwsStateError);
      expect(() => tracked.hasValue, throwsStateError);
      expect(() => terminal.write(Uint8List(1)), throwsStateError);
      // The render state is a copy: it outlives the terminal.
      expect(state.isDisposed, isFalse);
      expect(row.textAt(0), 'o');
      // Disposing again, dependents included, is a no-op.
      formatter.dispose();
      search.dispose();
      gesture.dispose();
      tracked.dispose();
      terminal.dispose();
      state.dispose();
    });

    test('dependents disposed inside a callback are freed after write', () {
      withTerminal(20, 4, (terminal) {
        writeText(terminal, 'abc abc');
        final search = TerminalSearch(terminal, needle: 'abc')..run();
        final tracked = terminal.trackGridRef(const GridPoint.active(0, 0))!;
        final gesture = SelectionGesture(terminal)
          ..press(const GridPoint.viewport(0, 0));
        terminal.onBell = () {
          search.dispose();
          tracked.dispose();
          gesture.dispose();
          expect(search.isDisposed, isTrue);
          expect(tracked.isDisposed, isTrue);
        };
        // The bell fires in the middle of the write; the rest still lands.
        writeText(terminal, '\x07 abc');
        expect(screenText(terminal), 'abc abc abc');
        // The terminal holds no stale registrations: new ones work.
        final again = TerminalSearch(terminal, needle: 'abc')..run();
        expect(again.totalMatches, 3);
        again.dispose();
        final ref = terminal.trackGridRef(const GridPoint.active(8, 0))!;
        expect(ref.snapshot()!.text, 'a');
        ref.dispose();
      });
    });

    test('a terminal disposed inside its own callback frees after write', () {
      final terminal = VtTerminal(cols: 20, rows: 4);
      final search = TerminalSearch(terminal, needle: 'x');
      final tracked = terminal.trackGridRef(const GridPoint.active(0, 0))!;
      var bells = 0;
      terminal.onBell = () {
        bells++;
        terminal.dispose();
        expect(terminal.isDisposed, isTrue);
        expect(search.isDisposed, isTrue);
        expect(tracked.isDisposed, isTrue);
      };
      writeText(terminal, 'a\x07b\x07c');
      expect(bells, 1, reason: 'no callback after dispose');
      expect(terminal.isDisposed, isTrue);
      expect(() => terminal.cols, throwsStateError);
      search.dispose();
      tracked.dispose();
    });

    test('forgotten terminals and dependents are collected', () async {
      final refs = _forgottenGraph();
      var garbage = <Object>[];
      for (var i = 0; i < 2000 && refs.any((r) => r.target != null); i++) {
        garbage = [for (var j = 0; j < 64; j++) Uint8List(1 << 16)];
        await Future<void>.delayed(Duration.zero);
      }
      expect(garbage, isNotEmpty);
      expect([for (final r in refs) r.target], everyElement(isNull));
    });
  });

  test('the example runs', () {
    final lines = <String>[];
    runZoned(
      example.main,
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => lines.add(line),
      ),
    );
    final output = lines.join('\n');
    expect(output, contains('title changed: "ghostty_dart tour"'));
    expect(output, contains('ESC[5;1RESC[?62;22c'));
    expect(output, contains('"hello": 2 matches'));
  });
}

/// A terminal with one of every dependent kind, all unreachable on return.
List<WeakReference<Object>> _forgottenGraph() {
  final terminal = VtTerminal(cols: 10, rows: 3);
  writeText(terminal, 'a hit\r\nb hit');
  terminal.onBell = () {};
  return [
    WeakReference(terminal),
    WeakReference(TerminalFormatter(terminal)),
    WeakReference(TerminalSearch(terminal, needle: 'hit')..run()),
    WeakReference(SelectionGesture(terminal)),
    WeakReference(terminal.trackGridRef(const GridPoint.active(0, 0))!),
  ];
}

VtKey _keyOf(String char) => switch (char) {
  ' ' => VtKey.space,
  _ => VtKey.unidentified,
};

/// A tiny line-editing shell on the other side of the pty. Bytes from the
/// terminal (keys and replies) arrive through [receive], are queued (the
/// terminal must not be written to from its own callback) and handled by
/// [pump], which writes the shell's output back into the terminal.
final class _FakeShell {
  _FakeShell(this.terminal);

  final VtTerminal terminal;
  final _input = <int>[];
  final _line = StringBuffer();
  int repliesSeen = 0;
  final unexpectedInput = <String>[];

  void receive(Uint8List bytes) => _input.addAll(bytes);

  void start() => _out(r'$ ');

  /// Handles queued input until the shell and the terminal are quiet.
  void pump() {
    while (_input.isNotEmpty) {
      final bytes = List.of(_input);
      _input.clear();
      _handle(bytes);
    }
  }

  void _handle(List<int> bytes) {
    final text = latin1.decode(bytes);
    var i = 0;
    while (i < text.length) {
      final reply = RegExp(r'\x1b\[(\??[\d;]*)([Rc])').matchAsPrefix(text, i);
      if (reply != null) {
        repliesSeen++;
        _out(
          reply[2] == 'R'
              ? 'cursor at ${reply[1]!.replaceAll(';', ',')}\r\n\$ '
              : 'device ${reply[1]}\r\n\$ ',
        );
        i = reply.end;
        continue;
      }
      final char = text[i++];
      if (char == '\r') {
        _run(_line.toString());
        _line.clear();
      } else if (char.codeUnitAt(0) >= 0x20) {
        _line.write(char);
        _out(char);
      } else {
        unexpectedInput.add(char);
      }
    }
  }

  void _run(String command) {
    _out('\r\n');
    switch (command) {
      case 'where':
        _out('\x1b[6n');
      case 'id':
        _out('\x1b[c');
      default:
        if (command.startsWith('echo ')) _out('${command.substring(5)}\r\n');
        _out(r'$ ');
    }
  }

  void _out(String text) => writeText(terminal, text);
}

/// A small deterministic generator for random byte streams.
final class _Lcg {
  _Lcg(this._state);

  int _state;

  int next() {
    _state = (_state * 1103515245 + 12345) & 0x7FFFFFFF;
    return _state >> 16 & 0xFF;
  }
}
