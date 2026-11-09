// A tour of package:ghostty_dart: feed a terminal a VT stream, answer its
// replies, draw its screen as ANSI, encode keys, then select, copy and
// search the text.
//
// Run from packages/ghostty_dart:  dart run example/main.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';

/// What a program might print: a title, colours and attributes, a wide
/// character, a hyperlink, and two queries the terminal answers through
/// `onWritePty` (cursor position report and primary device attributes).
const _sample =
    '\x1b]2;ghostty_dart tour\x07'
    '\x1b[1mBold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[4munderlined\x1b[0m '
    '\x1b[31mred\x1b[0m \x1b[38;5;208morange\x1b[0m '
    '\x1b[38;2;80;160;255;48;2;30;30;30mtrue colour\x1b[0m\r\n'
    'Wide: 漢字 — emoji: 👍🏽\r\n'
    '\x1b]8;;https://lib.ghostty.org/vt/\x1b\\a hyperlink\x1b]8;;\x1b\\\r\n'
    'hello world, hello terminal\r\n'
    '\x1b[6n\x1b[c';

void main() {
  print(
    'libghostty-vt $libghosttyVtVersion '
    '(${libghosttyVtBuildInfo.optimizeMode.name})\n',
  );

  final terminal = VtTerminal(cols: 60, rows: 8);
  final renderState = RenderState();
  final keys = KeyEncoder();
  try {
    // 1. Effects. Callbacks run synchronously inside write(); a real app
    //    queues the pty bytes and sends them to the child process later
    //    (writing back into the terminal from a callback throws).
    final toPty = BytesBuilder();
    terminal
      ..onWritePty = toPty.add
      ..onTitleChanged = (title) => print('title changed: "$title"');
    terminal.write(utf8.encode(_sample));
    print('replies for the pty: ${_visible(toPty.takeBytes())}\n');

    // 2. Rendering: one update, then style runs per row, printed as ANSI.
    renderState.update(terminal);
    print('screen (${renderState.cols}x${renderState.rows}):');
    for (final row in renderState.allRows) {
      print('  │${_ansiRow(row)}\x1b[0m');
    }
    final cursor = renderState.cursor;
    print('cursor: ${cursor.position} ${cursor.style.name}\n');

    // 3. Keys, synced with the terminal's modes. DECCKM (cursor keys mode)
    //    switches arrows from CSI to SS3 sequences.
    keys.setFromTerminal(terminal);
    _printKey(keys, 'arrow up', const VtKeyEvent(key: VtKey.arrowUp));
    _printKey(
      keys,
      'ctrl+c',
      const VtKeyEvent(key: VtKey.c, modifiers: KeyModifiers.ctrl, text: 'c'),
    );
    _printKey(keys, 'é', const VtKeyEvent(key: VtKey.unidentified, text: 'é'));
    terminal.setMode(TerminalMode.cursorKeys, enabled: true);
    keys.setFromTerminal(terminal);
    _printKey(keys, 'arrow up (DECCKM)', const VtKeyEvent(key: VtKey.arrowUp));
    print('');

    // 4. Select everything and copy it as plain text, then 5. search.
    //    Selections and matches are borrowed: use them before the next
    //    change to the terminal.
    final formatter = TerminalFormatter(terminal);
    final search = TerminalSearch(terminal, needle: 'hello');
    try {
      final all = terminal.selectAll();
      if (all != null) {
        print('copied text:\n${formatter.formatText(selection: all)}\n');
      }
      search.run();
      print('"hello": ${search.totalMatches} matches');
      // Matches come newest first; reversed, they read top to bottom.
      for (final match in search.matches.reversed) {
        // Every cell has a screen position (scrollback included).
        final at = match.start.pointIn(PointSpace.screen)!;
        final row = terminal.selectLine(at);
        print(
          '  at column ${at.x}, row ${at.y}: '
          '"${formatter.formatText(selection: row)}"',
        );
      }
    } finally {
      search.dispose();
      formatter.dispose();
    }
  } finally {
    keys.dispose();
    renderState.dispose();
    terminal.dispose();
  }
}

/// One rendered row as ANSI text: one SGR sequence per style run, not per
/// cell.
String _ansiRow(RenderRow row) {
  final out = StringBuffer();
  var x = 0;
  while (x < row.length) {
    final end = row.styleRunEnd(x);
    out.write(_sgr(row.styleAt(x), row.backgroundAt(x)));
    for (var i = x; i < end; i++) {
      // Spacer cells of wide characters have no text of their own.
      if (row.widthAt(i).isSpacer) continue;
      if (row.hasTextAt(i)) {
        row.writeTextTo(i, out);
      } else {
        out.write(' ');
      }
    }
    x = end;
  }
  return out.toString();
}

String _sgr(CellStyle style, ColorRef background) {
  final codes = [0];
  if (style.bold) codes.add(1);
  if (style.faint) codes.add(2);
  if (style.italic) codes.add(3);
  if (style.underline != UnderlineStyle.none) codes.add(4);
  if (style.inverse) codes.add(7);
  if (style.strikethrough) codes.add(9);
  codes
    ..addAll(_color(style.foreground, 38))
    ..addAll(_color(background, 48));
  return '\x1b[${codes.join(';')}m';
}

List<int> _color(ColorRef color, int base) => switch (color) {
  DefaultColor() => const [],
  PaletteColor(:final index) => [base, 5, index],
  RgbColor(:final r, :final g, :final b) => [base, 2, r, g, b],
};

void _printKey(KeyEncoder keys, String label, VtKeyEvent event) =>
    print('key ${label.padRight(18)} -> ${_visible(keys.encode(event))}');

/// Bytes with control characters made visible.
String _visible(List<int> bytes) => utf8
    .decode(bytes, allowMalformed: true)
    .replaceAllMapped(
      RegExp(r'[\x00-\x1f]'),
      (m) => m[0] == '\x1b'
          ? 'ESC'
          : '^${String.fromCharCode(m[0]!.codeUnitAt(0) + 64)}',
    );
