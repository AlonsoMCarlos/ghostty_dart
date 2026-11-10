import 'package:flutter/widgets.dart';

import '../../seams/terminal_geometry.dart';
import '../../seams/terminal_seams.dart';

/// Mouse, touch and wheel input for the view (ADR 0011): mouse reports
/// while the program tracks the mouse (Shift bypasses), selection gestures
/// otherwise, wheel and trackpad scrolling, alternate-scroll (DEC 1007)
/// arrows, and the pointer shape. Never exported.
///
/// Not implemented yet: it shows [child] and handles nothing.
class TerminalPointerScope extends StatefulWidget {
  /// Pointer input over [child].
  const TerminalPointerScope({
    super.key,
    required this.pointer,
    required this.viewport,
    required this.keys,
    required this.geometry,
    required this.child,
  });

  /// Where mouse reports and selections go.
  final TerminalPointerSink pointer;

  /// The scrollback position, for wheel scrolling.
  final TerminalViewport viewport;

  /// Where alternate-scroll arrow keys go.
  final TerminalKeySink keys;

  /// Where the grid is, to map pointer positions to cells.
  final TerminalGeometry geometry;

  /// The rest of the view.
  final Widget child;

  @override
  State<TerminalPointerScope> createState() => _TerminalPointerScopeState();
}

class _TerminalPointerScopeState extends State<TerminalPointerScope> {
  @override
  Widget build(BuildContext context) => widget.child;
}
