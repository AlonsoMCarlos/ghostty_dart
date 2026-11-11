// Ported from package:xterm 4.0.0 (lib/src/core/input/handler.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.
// Changed: KeytabInputHandler matches the keytab's AppCuKeys mode against
// `state.cursorKeysMode` (DECCKM); xterm passes `state.appKeypadMode`.

import '../platform.dart';
import '../state.dart';
import 'keys.dart';
import 'keytab/keytab.dart';

/// The key event received from the keyboard, along with the state of the
/// modifier keys and state of the terminal. Typically consumed by the
/// [TerminalInputHandler] to produce a escape sequence that can be recognized
/// by the terminal.
///
/// See also:
/// - [TerminalInputHandler]
class TerminalKeyboardEvent {
  /// The key pressed.
  final TerminalKey key;

  /// Whether Shift is held.
  final bool shift;

  /// Whether Control is held.
  final bool ctrl;

  /// Whether Alt (Option on macOS) is held.
  final bool alt;

  /// The terminal's modes when the key was pressed.
  final TerminalState state;

  /// Whether the alternate screen is active.
  final bool altBuffer;

  /// The platform the terminal behaves as.
  final TerminalTargetPlatform platform;

  /// Creates a key event; every field is required.
  TerminalKeyboardEvent({
    required this.key,
    required this.shift,
    required this.ctrl,
    required this.alt,
    required this.state,
    required this.altBuffer,
    required this.platform,
  });

  /// Returns a copy with the given fields replaced.
  TerminalKeyboardEvent copyWith({
    TerminalKey? key,
    bool? shift,
    bool? ctrl,
    bool? alt,
    TerminalState? state,
    bool? altBuffer,
    TerminalTargetPlatform? platform,
  }) {
    return TerminalKeyboardEvent(
      key: key ?? this.key,
      shift: shift ?? this.shift,
      ctrl: ctrl ?? this.ctrl,
      alt: alt ?? this.alt,
      state: state ?? this.state,
      altBuffer: altBuffer ?? this.altBuffer,
      platform: platform ?? this.platform,
    );
  }
}

/// TerminalInputHandler contains the logic for translating a [TerminalKeyboardEvent]
/// into escape sequences that can be recognized by the terminal.
abstract class TerminalInputHandler {
  /// Translates a [TerminalKeyboardEvent] into an escape sequence. If the event
  /// cannot be translated, null is returned.
  String? call(TerminalKeyboardEvent event);
}

/// A [TerminalInputHandler] that chains multiple handlers together. If any
/// handler returns a non-null value, it is returned. Otherwise, null is
/// returned.
class CascadeInputHandler implements TerminalInputHandler {
  final List<TerminalInputHandler> _handlers;

  /// Creates a handler that tries each of the handlers in order.
  const CascadeInputHandler(this._handlers);

  @override
  String? call(TerminalKeyboardEvent event) {
    for (final handler in _handlers) {
      final result = handler(event);
      if (result != null) {
        return result;
      }
    }
    return null;
  }
}

/// The default input handler for the terminal. That is composed of a
/// [KeytabInputHandler], a [CtrlInputHandler], and a [AltInputHandler].
///
/// It's possible to override the default input handler behavior by chaining
/// another input handler before or after the default input handler using
/// [CascadeInputHandler].
///
/// It is a `const`, so `identical(terminal.inputHandler,
/// defaultInputHandler)` tells whether a terminal uses it; `TerminalView`
/// then encodes keys with libghostty's key encoder instead (ADR 0013).
///
/// See also:
///  * [CascadeInputHandler]
const defaultInputHandler = CascadeInputHandler([
  KeytabInputHandler(),
  CtrlInputHandler(),
  AltInputHandler(),
]);

/// A [TerminalInputHandler] that translates key events according to a keytab
/// file. If no keytab is provided, [Keytab.defaultKeytab] is used.
///
/// Unlike xterm 4.0.0, the keytab's `AppCuKeys` mode follows the terminal's
/// application cursor keys mode (DECCKM), so the arrow keys send `ESC O A`
/// after `CSI ? 1 h`; xterm tied it to the application keypad mode.
class KeytabInputHandler implements TerminalInputHandler {
  /// Creates a handler that looks keys up in [keytab], or in
  /// [Keytab.defaultKeytab] when it is `null`.
  const KeytabInputHandler([this.keytab]);

  /// The keytab keys are looked up in; `null` means
  /// [Keytab.defaultKeytab].
  final Keytab? keytab;

  @override
  String? call(TerminalKeyboardEvent event) {
    final keytab = this.keytab ?? Keytab.defaultKeytab;

    final record = keytab.find(
      event.key,
      ctrl: event.ctrl,
      alt: event.alt,
      shift: event.shift,
      newLineMode: event.state.lineFeedMode,
      // Changed from xterm, which passed `appKeypadMode` here.
      appCursorKeys: event.state.cursorKeysMode,
      appKeyPad: event.state.appKeypadMode,
      appScreen: event.altBuffer,
      macos: event.platform == TerminalTargetPlatform.macos,
    );

    if (record == null) {
      return null;
    }

    var result = record.action.unescapedValue();
    result = insertModifiers(event, result);
    return result;
  }

  /// Replaces each `*` in [action] with the xterm modifier parameter for
  /// the event's modifiers (`2` Shift, `3` Alt, `4` Shift+Alt, `5` Control,
  /// `6` Shift+Control, `7` Control+Alt, `8` all three). Without modifiers
  /// [action] is returned unchanged.
  String insertModifiers(TerminalKeyboardEvent event, String action) {
    String? code;

    if (event.shift && event.alt && event.ctrl) {
      code = '8';
    } else if (event.ctrl && event.alt) {
      code = '7';
    } else if (event.shift && event.ctrl) {
      code = '6';
    } else if (event.ctrl) {
      code = '5';
    } else if (event.shift && event.alt) {
      code = '4';
    } else if (event.alt) {
      code = '3';
    } else if (event.shift) {
      code = '2';
    }

    if (code != null) {
      return action.replaceAll('*', code);
    }

    return action;
  }
}

/// A [TerminalInputHandler] that translates ctrl + key events into escape
/// sequences. For example, ctrl + a becomes ^A.
class CtrlInputHandler implements TerminalInputHandler {
  /// Creates the handler.
  const CtrlInputHandler();

  @override
  String? call(TerminalKeyboardEvent event) {
    if (!event.ctrl || event.shift || event.alt) {
      return null;
    }

    final key = event.key;

    if (key.index >= TerminalKey.keyA.index &&
        key.index <= TerminalKey.keyZ.index) {
      final input = key.index - TerminalKey.keyA.index + 1;
      return String.fromCharCode(input);
    }

    return null;
  }
}

/// A [TerminalInputHandler] that translates alt + key events into escape
/// sequences. For example, alt + a becomes ^[a.
///
/// The letter is sent in upper case (Alt+A and Alt+a both give `ESC A`),
/// as in xterm. On macOS it translates nothing, so Option keeps producing
/// characters.
class AltInputHandler implements TerminalInputHandler {
  /// Creates the handler.
  const AltInputHandler();

  @override
  String? call(TerminalKeyboardEvent event) {
    if (!event.alt || event.ctrl || event.shift) {
      return null;
    }

    if (event.platform == TerminalTargetPlatform.macos) {
      return null;
    }

    final key = event.key;

    if (key.index >= TerminalKey.keyA.index &&
        key.index <= TerminalKey.keyZ.index) {
      final charCode = key.index - TerminalKey.keyA.index + 65;
      final input = [0x1b, charCode];
      return String.fromCharCodes(input);
    }

    return null;
  }
}
