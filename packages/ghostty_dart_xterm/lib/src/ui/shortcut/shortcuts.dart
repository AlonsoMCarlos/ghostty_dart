// Ported from package:xterm 4.0.0 (lib/src/ui/shortcut/shortcuts.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// xterm's default shortcuts of `TerminalView` for the current platform:
/// Ctrl+Shift+C copies, Ctrl+V pastes and Ctrl+A selects all on Android,
/// Fuchsia, Linux and Windows; Cmd+C, Cmd+V and Cmd+A on iOS and macOS.
///
/// Unlike `ghostty_dart_flutter`'s own view, these take Ctrl+V and Ctrl+A
/// from the shell: the adapter keeps xterm's behaviour (ADR 0013). Pass
/// your own map to `TerminalView.shortcuts` to change them.
Map<ShortcutActivator, Intent> get defaultTerminalShortcuts {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      return _defaultShortcuts;
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return _defaultAppleShortcuts;
  }
}

final _defaultShortcuts = {
  const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
      CopySelectionTextIntent.copy,
  const SingleActivator(LogicalKeyboardKey.keyV, control: true):
      const PasteTextIntent(SelectionChangedCause.keyboard),
  const SingleActivator(LogicalKeyboardKey.keyA, control: true):
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
};

final _defaultAppleShortcuts = {
  const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
      CopySelectionTextIntent.copy,
  const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
      const PasteTextIntent(SelectionChangedCause.keyboard),
  const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
};
