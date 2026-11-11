// Ported from package:xterm 4.0.0 (lib/src/core/input/keytab/keytab_record.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import '../keys.dart';
import 'keytab_escape.dart';

/// What a keytab line does: send text, or run a named shortcut.
enum KeytabActionType {
  /// Send the (escaped) string to the program.
  input,

  /// A named action such as `scrollPageUp`. Nothing runs it:
  /// [KeytabAction.unescapedValue] returns the name, so when such a line
  /// matches, `KeytabInputHandler` sends the name itself as text, as xterm
  /// 4.0.0 does. In the default keytab, earlier `+AnyMod` lines shadow
  /// every shortcut line.
  shortcut,
}

/// The right-hand side of a keytab line.
class KeytabAction {
  /// Creates an action of [type] with the raw [value] from the keytab.
  KeytabAction(this.type, this.value);

  /// Whether [value] is text to send or a shortcut name.
  final KeytabActionType type;

  /// The value as written in the keytab, escapes not expanded.
  final String value;

  /// [value] with its escapes expanded for [KeytabActionType.input], or
  /// unchanged for a shortcut.
  String unescapedValue() {
    if (type == KeytabActionType.input) {
      return keytabUnescape(value);
    } else {
      return value;
    }
  }

  @override
  String toString() {
    switch (type) {
      case KeytabActionType.input:
        return '"$value"';
      case KeytabActionType.shortcut:
        return value;
    }
  }
}

/// One `key` line of a keytab: a key, the modes it requires, and its
/// action.
///
/// Each mode is `true` (`+Mode`, required on), `false` (`-Mode`, required
/// off) or `null` (not mentioned, matches either).
class KeytabRecord {
  /// Creates a record; every mode is required but may be `null`.
  KeytabRecord({
    required this.qtKeyName,
    required this.key,
    required this.action,
    required this.alt,
    required this.ctrl,
    required this.shift,
    required this.anyModifier,
    required this.ansi,
    required this.appScreen,
    required this.keyPad,
    required this.appCursorKeys,
    required this.appKeyPad,
    required this.newLine,
    required this.macos,
  });

  /// The Qt key name as written in the keytab.
  String qtKeyName;

  /// The key [qtKeyName] maps to.
  TerminalKey key;

  /// What the line does.
  KeytabAction action;

  /// `Alt` mode.
  bool? alt;

  /// `Control` mode.
  bool? ctrl;

  /// `Shift` mode.
  bool? shift;

  /// `AnyMod`: any of Alt, Control and Shift held (`true`) or none
  /// (`false`).
  bool? anyModifier;

  /// `Ansi` mode (`false` means VT52, which is never matched).
  bool? ansi;

  /// `AppScreen`: the alternate screen is active.
  bool? appScreen;

  /// `KeyPad`: the key comes from the keypad.
  bool? keyPad;

  /// `AppCuKeys`: application cursor keys (DECCKM).
  bool? appCursorKeys;

  /// `AppKeyPad`: application keypad (DECKPAM).
  bool? appKeyPad;

  /// `NewLine`: line feed / new line mode (LNM).
  bool? newLine;

  /// `Mac`: the platform is macOS.
  bool? macos;

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('$qtKeyName ');

    if (alt != null) {
      buffer.write(_toMode(alt!, 'Alt'));
    }

    if (ctrl != null) {
      buffer.write(_toMode(ctrl!, 'Control'));
    }

    if (shift != null) {
      buffer.write(_toMode(shift!, 'Shift'));
    }

    if (anyModifier != null) {
      buffer.write(_toMode(anyModifier!, 'AnyMod'));
    }

    if (ansi != null) {
      buffer.write(_toMode(ansi!, 'Ansi'));
    }

    if (appScreen != null) {
      buffer.write(_toMode(appScreen!, 'AppScreen'));
    }

    if (keyPad != null) {
      buffer.write(_toMode(keyPad!, 'KeyPad'));
    }

    if (appCursorKeys != null) {
      buffer.write(_toMode(appCursorKeys!, 'AppCuKeys'));
    }

    if (appKeyPad != null) {
      buffer.write(_toMode(appKeyPad!, 'AppKeyPad'));
    }

    if (newLine != null) {
      buffer.write(_toMode(newLine!, 'NewLine'));
    }

    if (macos != null) {
      buffer.write(_toMode(macos!, 'Mac'));
    }

    buffer.write(' : $action');

    return buffer.toString();
  }

  static String _toMode(bool status, String mode) {
    if (status == true) {
      return '+$mode';
    }

    if (status == false) {
      return '-$mode';
    }

    return '';
  }
}
