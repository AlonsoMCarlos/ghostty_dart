/// @docImport '../../view/terminal_view.dart';
library;

import 'package:flutter/widgets.dart';

import '../../controller/terminal_controller.dart';

/// A row of keys that soft keyboards lack (Esc, Ctrl, Alt, Tab and the
/// arrows), for mobile. Ctrl and Alt latch: they apply to the next key or
/// character typed in the [controller]'s view.
///
/// Place it next to the [VtTerminalView] of the same [controller], for
/// example above the soft keyboard.
///
/// Work in progress: this version shows nothing yet.
class VtTerminalKeyToolbar extends StatelessWidget {
  /// A toolbar that sends its keys to [controller].
  const VtTerminalKeyToolbar({super.key, required this.controller});

  /// The terminal the keys go to.
  final VtTerminalController controller;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
