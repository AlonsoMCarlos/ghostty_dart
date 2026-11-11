// Ported from package:xterm 4.0.0 (lib/src/core/input/keytab/keytab.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import '../keys.dart';
import 'keytab_default.dart';
import 'keytab_parse.dart';
import 'keytab_record.dart';
import 'keytab_token.dart';

/// A key table in Konsole's `.keytab` format: which bytes each key sends,
/// depending on the modifiers and the terminal's modes.
///
/// `KeytabInputHandler` looks keys up in one. xterm does not export this
/// class from its libraries, and neither does this package; it is reached
/// through `package:ghostty_dart_xterm/src/core/input/keytab/keytab.dart`,
/// as xterm's own tests do.
///
/// ```dart
/// final keytab = Keytab.parse(r'key F1 : "\EOP"');
/// final handler = KeytabInputHandler(keytab);
/// ```
class Keytab {
  /// Creates a keytab named [name] with [records], searched in order.
  Keytab({required this.name, required this.records});

  /// Parses a keytab [source].
  ///
  /// Throws `TokenizeError` or `ParseError` for malformed input.
  factory Keytab.parse(String source) {
    final tokens = tokenize(source).toList();
    final parser = KeytabParser()..addTokens(tokens);
    return parser.result;
  }

  /// The keytab xterm uses when `KeytabInputHandler` is given none, parsed
  /// from [kDefaultKeytab] on first use.
  static final defaultKeytab = Keytab.parse(kDefaultKeytab);

  /// The name from the `keyboard` line, if any.
  final String? name;

  /// The `key` lines, in source order.
  final List<KeytabRecord> records;

  /// Returns the first record for [key] whose modes all match, or `null`.
  ///
  /// A mode a record does not mention matches either state. Records that
  /// require VT52 mode (`-Ansi`) never match.
  KeytabRecord? find(
    TerminalKey key, {
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
    bool newLineMode = false,
    bool appCursorKeys = false,
    bool appKeyPad = false,
    bool keyPad = false,
    bool appScreen = false,
    bool macos = false,
  }) {
    for (final record in records) {
      if (record.key != key) {
        continue;
      }

      if (record.anyModifier == true) {
        if (ctrl == false && alt == false && shift == false) {
          continue;
        }
      } else if (record.anyModifier == false) {
        if (ctrl != false || alt != false || shift != false) {
          continue;
        }
      } else {
        if (record.ctrl != null && record.ctrl != ctrl) {
          continue;
        }

        if (record.shift != null && record.shift != shift) {
          continue;
        }

        if (record.alt != null && record.alt != alt) {
          continue;
        }
      }

      if (record.newLine != null && record.newLine != newLineMode) {
        continue;
      }

      if (record.appCursorKeys != null &&
          record.appCursorKeys != appCursorKeys) {
        continue;
      }

      if (record.appKeyPad != null && record.appKeyPad != appKeyPad) {
        continue;
      }

      if (record.keyPad != null && record.keyPad != keyPad) {
        continue;
      }

      if (record.appScreen != null && record.appScreen != appScreen) {
        continue;
      }

      if (record.macos != null && record.macos != macos) {
        continue;
      }

      // VT52 mode is not supported (as in xterm): the terminal is always
      // in ANSI mode, so `-Ansi` records never apply.
      if (record.ansi == false) {
        continue;
      }

      return record;
    }

    return null;
  }

  @override
  String toString() {
    final buffer = StringBuffer();

    buffer.writeln('keyboard "$name"');

    for (final record in records) {
      buffer.writeln(record);
    }

    return buffer.toString();
  }
}
