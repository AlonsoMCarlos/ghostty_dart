// Ported from package:xterm 4.0.0 (lib/src/core/mouse/button.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// A mouse button or wheel direction, as reported to the program.
enum TerminalMouseButton {
  /// The primary button.
  left(id: 0),

  /// The middle button.
  middle(id: 1),

  /// The secondary button.
  right(id: 2),

  /// The wheel scrolled up.
  wheelUp(id: 64 + 4, isWheel: true),

  /// The wheel scrolled down.
  wheelDown(id: 64 + 5, isWheel: true),

  /// The wheel scrolled left.
  wheelLeft(id: 64 + 6, isWheel: true),

  /// The wheel scrolled right.
  wheelRight(id: 64 + 7, isWheel: true);

  /// The id that is used to report a button press or release to the terminal.
  ///
  /// Mouse wheel up / down use button IDs 4 = 0100 (binary) and 5 = 0101 (binary).
  /// The bits three and four of the button are transposed by 64 and 128
  /// respectively, when reporting the id of the button and have have to be
  /// adjusted correspondingly.
  final int id;

  /// Whether this button is a mouse wheel button.
  final bool isWheel;

  const TerminalMouseButton({required this.id, this.isWheel = false});
}
