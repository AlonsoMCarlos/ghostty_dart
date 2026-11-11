// Ported from package:xterm 4.0.0 (lib/src/ui/cursor_type.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// The shape `TerminalView` draws the cursor in.
enum TerminalCursorType {
  /// A filled cell.
  block,

  /// A line under the cell.
  underline,

  /// A vertical bar at the cell's left edge.
  verticalBar,
}
