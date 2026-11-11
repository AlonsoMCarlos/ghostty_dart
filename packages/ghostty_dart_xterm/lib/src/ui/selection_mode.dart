// Ported from package:xterm 4.0.0 (lib/src/ui/selection_mode.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// How a selection covers the cells between its two ends.
enum SelectionMode {
  /// Running text, wrapping from the end of one row to the next.
  line,

  /// A rectangle (block of columns) with the ends at opposite corners.
  block,
}
