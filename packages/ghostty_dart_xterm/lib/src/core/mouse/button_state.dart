// Ported from package:xterm 4.0.0 (lib/src/core/mouse/button_state.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// Whether a mouse event is a release or a press.
enum TerminalMouseButtonState {
  /// The button was released.
  up,

  /// The button was pressed (or the wheel moved).
  down,
}
