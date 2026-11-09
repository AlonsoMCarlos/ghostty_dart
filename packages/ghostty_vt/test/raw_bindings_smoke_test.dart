// Smoke test of the raw generated bindings against the native library
// provided by the build hook. Exercises create -> write -> format -> free.

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:ghostty_vt/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

void main() {
  test('reports a 1.x library version', () {
    expect(ghostty_version().cast<Utf8>().toDartString(), startsWith('1.'));
  });

  test('parses bytes and formats the screen as plain text', () {
    using((arena) {
      final terminalOut = arena<GhosttyTerminal>();
      expect(
        ghostty_terminal_new(nullptr, terminalOut, 80, 24),
        GhosttyResult.GHOSTTY_SUCCESS,
      );
      final terminal = terminalOut.value;
      addTearDown(() => ghostty_terminal_free(terminal));

      final input = utf8.encode('hello \x1b[1mghostty\x1b[0m\r\nline 2');
      final buffer = arena<Uint8>(input.length)
        ..asTypedList(input.length).setAll(0, input);
      ghostty_terminal_vt_write(terminal, buffer, input.length);

      final cols = arena<Uint16>();
      expect(
        ghostty_terminal_get(
          terminal,
          GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLS,
          cols.cast(),
        ),
        GhosttyResult.GHOSTTY_SUCCESS,
      );
      expect(cols.value, 80);

      final formatterOut = arena<GhosttyFormatter>();
      expect(
        ghostty_formatter_terminal_new(nullptr, formatterOut, terminal),
        GhosttyResult.GHOSTTY_SUCCESS,
      );
      final formatter = formatterOut.value;
      addTearDown(() => ghostty_formatter_free(formatter));

      final outPtr = arena<Pointer<Uint8>>();
      final outLen = arena<Size>();
      expect(
        ghostty_formatter_format_alloc(formatter, nullptr, outPtr, outLen),
        GhosttyResult.GHOSTTY_SUCCESS,
      );
      final text = utf8.decode(outPtr.value.asTypedList(outLen.value));
      ghostty_free(nullptr, outPtr.value, outLen.value);

      expect(text, 'hello ghostty\nline 2');
    });
  });
}
