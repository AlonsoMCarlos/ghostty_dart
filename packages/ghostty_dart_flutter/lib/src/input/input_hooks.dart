/// @docImport '../view/terminal_view.dart';
library;

import 'package:flutter/services.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

/// Called for a key press or repeat before the view encodes it (see
/// [VtTerminalView.onTerminalKey]).
///
/// [modifiers] are the event's effective modifiers, including the ones
/// latched on a `VtTerminalKeyToolbar`. Return `null` to let the view
/// handle the key as usual; return a string to consume the key and send
/// that string to the program instead (an empty string sends nothing and
/// leaves the key to the rest of the app).
typedef VtTerminalKeyHook =
    String? Function(KeyEvent event, KeyModifiers modifiers);

/// Called with text the view is about to send to the program (see
/// [VtTerminalView.onTerminalText]).
///
/// Return `null` to send [text] unchanged, or the string to send instead
/// (empty: send nothing).
typedef VtTerminalTextHook = String? Function(String text);

/// Decides whether a mouse event is reported to the program (see
/// [VtTerminalView.mouseReportFilter]). Return `false` to handle it as if
/// the program did not track the mouse.
typedef VtTerminalMouseFilter = bool Function(VtMouseEvent event);

/// Called for a mouse event about to be reported, before the view encodes
/// it (see [VtTerminalView.onTerminalMouse]).
///
/// [cell] is the viewport cell under the pointer. Return `null` to encode
/// and send [event] as usual, or the string to send instead (empty: send
/// nothing).
typedef VtTerminalMouseHook =
    String? Function(VtMouseEvent event, GridPoint cell);
