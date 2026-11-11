// Ported from package:xterm 4.0.0 (lib/src/ui/keyboard_visibility.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import 'package:flutter/widgets.dart';

/// Calls [onKeyboardShow] and [onKeyboardHide] when the soft keyboard
/// appears or disappears (the view's bottom inset changes). The name's
/// typo is xterm's API.
class KeyboardVisibilty extends StatefulWidget {
  /// Watches the soft keyboard around [child].
  const KeyboardVisibilty({
    super.key,
    required this.child,
    this.onKeyboardShow,
    this.onKeyboardHide,
  });

  /// The widget below this one.
  final Widget child;

  /// Called when the bottom inset grows from zero (keyboard shown).
  final VoidCallback? onKeyboardShow;

  /// Called when the bottom inset drops to zero (keyboard hidden).
  final VoidCallback? onKeyboardHide;

  @override
  KeyboardVisibiltyState createState() => KeyboardVisibiltyState();
}

/// The state of a [KeyboardVisibilty]: observes the window's metrics.
class KeyboardVisibiltyState extends State<KeyboardVisibilty>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final bottomInset = View.of(context).viewInsets.bottom;

    if (bottomInset != _lastBottomInset) {
      if (bottomInset > 0) {
        widget.onKeyboardShow?.call();
      } else {
        widget.onKeyboardHide?.call();
      }
    }

    _lastBottomInset = bottomInset;

    super.didChangeMetrics();
  }

  var _lastBottomInset = 0.0;

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
