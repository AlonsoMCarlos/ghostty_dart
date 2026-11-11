// Ported from package:xterm 4.0.0 (lib/src/core/input/keytab/keytab_escape.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

final _esc = String.fromCharCode(0x1b);

/// Expands the escapes of a keytab action string: `\E` (ESC), `\\`, `\"`,
/// `\t`, `\r`, `\n`, `\b` and `\xHH`.
String keytabUnescape(String str) {
  str = str
      .replaceAll(r'\E', _esc)
      .replaceAll(r'\\', '\\')
      .replaceAll(r'\"', '"')
      .replaceAll(r'\t', '\t')
      .replaceAll(r'\r', '\r')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\b', '\b');

  final hexPattern = RegExp(r'\\x([0-9a-fA-F][0-9a-fA-F])');
  str = str.replaceAllMapped(hexPattern, (match) {
    final hexString = match.group(1)!;
    final hexValue = int.parse(hexString, radix: 16);
    return String.fromCharCode(hexValue);
  });

  return str;
}
