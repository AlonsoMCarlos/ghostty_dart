// Shared test helpers for every module's tests.
//
// `screenText` formats the screen with the raw formatter bindings, so tests
// of other modules do not depend on the formatter module they may break.

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';

/// Creates a [VtTerminal], runs [body] with it and disposes it afterwards,
/// even if [body] throws.
R withTerminal<R>(int cols, int rows, R Function(VtTerminal terminal) body) {
  final terminal = VtTerminal(cols: cols, rows: rows);
  try {
    return body(terminal);
  } finally {
    terminal.dispose();
  }
}

/// Writes [text] to [terminal] as UTF-8.
void writeText(VtTerminal terminal, String text) =>
    terminal.write(utf8.encode(text));

/// The active screen of [terminal] as plain text, formatted by the library's
/// formatter with default options (trailing blank cells and rows trimmed,
/// rows joined with `\n`).
String screenText(VtTerminal terminal) => using((arena) {
  final handle = handleOf<GhosttyTerminalImpl>(terminal);
  final formatterOut = arena<GhosttyFormatter>();
  checkResult(
    ghostty_formatter_terminal_new(nullptr, formatterOut, handle.pointer),
    'ghostty_formatter_terminal_new',
  );
  final formatter = formatterOut.value;
  try {
    final bytes = callAllocating(
      'ghostty_formatter_format_alloc',
      (outPtr, outLength) =>
          ghostty_formatter_format_alloc(formatter, nullptr, outPtr, outLength),
    );
    return utf8.decode(bytes);
  } finally {
    ghostty_formatter_free(formatter);
  }
});

/// Reads one `uint16_t` terminal data field (`GhosttyTerminalData` [key])
/// with the raw bindings.
int terminalDataUint16(VtTerminal terminal, int key) => using((arena) {
  final out = arena<Uint16>();
  _getTerminalData(terminal, key, out.cast());
  return out.value;
});

/// Reads one `uint32_t` terminal data field (`GhosttyTerminalData` [key])
/// with the raw bindings, e.g. `GHOSTTY_TERMINAL_DATA_WIDTH_PX`.
int terminalDataUint32(VtTerminal terminal, int key) => using((arena) {
  final out = arena<Uint32>();
  _getTerminalData(terminal, key, out.cast());
  return out.value;
});

void _getTerminalData(VtTerminal terminal, int key, Pointer<Void> out) =>
    checkResult(
      ghostty_terminal_get(
        handleOf<GhosttyTerminalImpl>(terminal).pointer,
        key,
        out,
      ),
      'ghostty_terminal_get',
    );
