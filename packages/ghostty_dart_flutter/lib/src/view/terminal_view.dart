import 'package:flutter/widgets.dart';

import '../controller/terminal_controller.dart';

/// A terminal view: draws a [VtTerminalController]'s terminal and sends the
/// user's keyboard, text, mouse and touch input to it.
///
/// ```dart
/// VtTerminalView(
///   controller: controller,
///   textStyle: const TextStyle(fontFamily: 'JetBrains Mono', fontSize: 14),
///   autofocus: true,
/// )
/// ```
///
/// Work in progress: this version only fills its area with the terminal's
/// background colour. It does not draw the grid, take input or resize the
/// terminal yet.
class VtTerminalView extends StatefulWidget {
  /// Creates a view of [controller].
  const VtTerminalView({
    super.key,
    required this.controller,
    this.textStyle,
    this.padding = EdgeInsets.zero,
    this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.shortcuts,
    this.onKeyEvent,
  });

  /// The terminal to show. The view does not dispose it.
  final VtTerminalController controller;

  /// The font of the grid; use a monospace font. Flutter has no portable
  /// "monospace" family, so pass a font you bundle with your app for the
  /// same metrics everywhere.
  final TextStyle? textStyle;

  /// The space between the view's edges and the grid.
  final EdgeInsets padding;

  /// The focus node for keyboard input; the view creates one when `null`.
  final FocusNode? focusNode;

  /// Whether the view requests focus when first built.
  final bool autofocus;

  /// Whether user input is ignored (output is still shown and selection
  /// still works).
  final bool readOnly;

  /// Whether to take input from hardware keys only, never opening a soft
  /// keyboard or an IME connection.
  final bool hardwareKeyboardOnly;

  /// The shortcut map, replacing the default one. `null` uses the default,
  /// which never takes Ctrl+V or Ctrl+A from the shell: copy and paste are
  /// Ctrl+Shift+C/V and Ctrl/Shift+Insert, or Cmd+C/V on Apple platforms.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Sees every key event before the terminal does; return
  /// [KeyEventResult.handled] to keep the terminal from receiving it.
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  State<VtTerminalView> createState() => VtTerminalViewState();
}

/// The state of a [VtTerminalView].
class VtTerminalViewState extends State<VtTerminalView> {
  @override
  Widget build(BuildContext context) {
    final background = widget.controller.terminal.colorBackground;
    return ColoredBox(
      color: background == null
          ? widget.controller.theme.background
          : Color(0xFF000000 | background.value),
      child: const SizedBox.expand(),
    );
  }
}
