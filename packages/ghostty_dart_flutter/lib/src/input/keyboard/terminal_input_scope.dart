import 'package:flutter/widgets.dart';

import '../../seams/terminal_geometry.dart';
import '../../seams/terminal_seams.dart';

/// Keyboard and text input for the view (ADR 0011): hardware keys through
/// the key encoder, the IME and soft keyboards through a delta text input
/// client, shortcuts that never steal shell keys, and the IME composing
/// overlay. Never exported.
///
/// Not implemented yet: it shows [child] and handles nothing.
class TerminalInputScope extends StatefulWidget {
  /// Input for [child], sending keys to [keys] and text to [text].
  const TerminalInputScope({
    super.key,
    required this.keys,
    required this.text,
    required this.geometry,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.shortcuts,
    this.onKeyEvent,
    this.textStyle,
    this.onComposingChanged,
    required this.child,
  });

  /// Where encoded keys go.
  final TerminalKeySink keys;

  /// Where committed text, pastes and focus reports go.
  final TerminalTextSink text;

  /// Where the grid is, for the IME caret and composing rectangles.
  final TerminalGeometry geometry;

  /// The view's focus node.
  final FocusNode focusNode;

  /// Whether to request focus when first built.
  final bool autofocus;

  /// Whether to ignore input.
  final bool readOnly;

  /// Whether to use hardware keys only (no text input connection).
  final bool hardwareKeyboardOnly;

  /// The shortcut map, replacing the default policy (which never takes
  /// Ctrl+V or Ctrl+A from the shell). `null` uses the default. The xterm
  /// adapter passes xterm's map here.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Sees every key event before the terminal does; returning
  /// [KeyEventResult.handled] or [KeyEventResult.skipRemainingHandlers]
  /// stops the terminal from encoding it (xterm's `onKeyEvent`).
  final FocusOnKeyEventCallback? onKeyEvent;

  /// The grid font, for drawing IME composing text in place.
  final TextStyle? textStyle;

  /// Called with `true` when IME composing starts and `false` when it
  /// ends, so the view can hide the renderer's cursor meanwhile.
  final ValueChanged<bool>? onComposingChanged;

  /// The rest of the view.
  final Widget child;

  @override
  State<TerminalInputScope> createState() => _TerminalInputScopeState();
}

class _TerminalInputScopeState extends State<TerminalInputScope> {
  @override
  Widget build(BuildContext context) => widget.child;
}
