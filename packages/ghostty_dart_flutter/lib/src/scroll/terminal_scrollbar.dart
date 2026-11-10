import 'package:flutter/widgets.dart';

import '../seams/terminal_geometry.dart';
import '../seams/terminal_seams.dart';

/// A thin scrollbar drawn from the terminal's viewport (ADR 0011). There
/// is no `ScrollPosition`: the viewport lives in libghostty. Never
/// exported.
///
/// Not implemented yet: it shows nothing.
class TerminalScrollbar extends StatelessWidget {
  /// A scrollbar for [viewport] beside the grid of [geometry].
  const TerminalScrollbar({
    super.key,
    required this.viewport,
    required this.geometry,
  });

  /// The scrollback position to show and to move.
  final TerminalViewport viewport;

  /// Where the grid is.
  final TerminalGeometry geometry;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
