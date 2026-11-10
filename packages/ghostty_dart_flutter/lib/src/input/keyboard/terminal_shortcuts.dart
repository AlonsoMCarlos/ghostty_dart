import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../../seams/terminal_seams.dart';

/// The default shortcut map for [platform] (ADR 0011, Input). Never
/// exported.
///
/// It never takes a key the shell needs: Ctrl+V (literal next) and Ctrl+A
/// (start of line) reach the program.
/// - Apple platforms: Cmd+C copies and Cmd+V pastes.
/// - Everywhere else: Ctrl+Shift+C and Ctrl+Insert copy, Ctrl+Shift+V and
///   Shift+Insert paste, the convention of Linux and Windows terminals
///   that xterm2 5.4.0 also adopted (research
///   `docs/internal/research/2026-11-09-flutter-input.md` §1.6).
///
/// Ctrl+Shift+C and Cmd+C are always consumed, even with nothing selected:
/// Ctrl+Shift+C encodes as `^C` and would interrupt the program when the
/// selection was just cleared (GNOME Terminal and Konsole consume it too).
/// Ctrl+Insert copies only with a selection and otherwise reaches the
/// program (`CSI 2;5~`, harmless).
Map<ShortcutActivator, Intent> defaultTerminalShortcuts(
  TargetPlatform platform,
) => switch (platform) {
  TargetPlatform.macOS || TargetPlatform.iOS => const {
    SingleActivator(LogicalKeyboardKey.keyC, meta: true):
        CopySelectionTextIntent.copy,
    SingleActivator(LogicalKeyboardKey.keyV, meta: true): PasteTextIntent(
      SelectionChangedCause.keyboard,
    ),
  },
  TargetPlatform.android ||
  TargetPlatform.fuchsia ||
  TargetPlatform.linux ||
  TargetPlatform.windows => const {
    SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
        CopySelectionTextIntent.copy,
    SingleActivator(LogicalKeyboardKey.insert, control: true):
        CopyIfSelectedIntent(),
    SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
        PasteTextIntent(SelectionChangedCause.keyboard),
    SingleActivator(LogicalKeyboardKey.insert, shift: true): PasteTextIntent(
      SelectionChangedCause.keyboard,
    ),
  },
};

/// Asked before pasting text that could run commands by itself (it holds a
/// newline and the program did not enable bracketed paste). Return `true`
/// to paste it anyway. Never exported (the view decides whether to expose
/// it).
typedef UnsafePasteCallback = Future<bool> Function(String text);

/// Copies the selection if there is one; otherwise the key reaches the
/// program. Never exported.
class CopyIfSelectedIntent extends Intent {
  /// The intent of Ctrl+Insert in the default map.
  const CopyIfSelectedIntent();
}

Future<void> _copy(TerminalTextSink text) async {
  final selected = text.isDisposed ? null : text.selectedText;
  if (selected == null) return;
  await Clipboard.setData(ClipboardData(text: selected));
}

/// Copies the terminal's selection to the clipboard. Always enabled: with
/// nothing selected it does nothing and still consumes the key. Never
/// exported.
class TerminalCopyAction extends Action<CopySelectionTextIntent> {
  /// Copies [text]'s selection.
  TerminalCopyAction(this.text);

  /// Where the selection is read from.
  TerminalTextSink text;

  @override
  bool isEnabled(CopySelectionTextIntent intent) =>
      !intent.collapseSelection && !text.isDisposed;

  @override
  Future<void> invoke(CopySelectionTextIntent intent) => _copy(text);
}

/// [CopyIfSelectedIntent]'s action: disabled while nothing is selected, so
/// the key falls through to the program. Never exported.
class TerminalCopyIfSelectedAction extends Action<CopyIfSelectedIntent> {
  /// Copies [text]'s selection, if any.
  TerminalCopyIfSelectedAction(this.text);

  /// Where the selection is read from.
  TerminalTextSink text;

  @override
  bool isEnabled(CopyIfSelectedIntent intent) =>
      !text.isDisposed && text.selectedText != null;

  @override
  Future<void> invoke(CopyIfSelectedIntent intent) => _copy(text);
}

/// Keeps a paste in order with the keys typed around it. Never exported.
///
/// [hold] reserves the paste's place in the input order before the
/// clipboard is read (asynchronously); [release] delivers the paste there
/// (or nothing, with `null`). Keys typed meanwhile wait behind it.
abstract interface class PasteSequencer {
  /// Reserves a place; pass the token to [release].
  Object hold();

  /// Fills the place [token] reserved with [send], or with nothing.
  void release(Object token, VoidCallback? send);
}

/// Pastes the clipboard's text into the terminal. Never exported.
///
/// Text the terminal rejects as unsafe is pasted only if [onUnsafePaste]
/// says so; without it, it is not pasted (Ghostty's
/// `clipboard-paste-protection`).
class TerminalPasteAction extends Action<PasteTextIntent> {
  /// Pastes into [text] unless [readOnly], in order through [sequencer].
  TerminalPasteAction(
    this.text, {
    this.readOnly = false,
    this.onUnsafePaste,
    this.sequencer,
  });

  /// Where the clipboard text goes.
  TerminalTextSink text;

  /// Whether pasting is disabled.
  bool readOnly;

  /// Confirms an unsafe paste; see [UnsafePasteCallback].
  UnsafePasteCallback? onUnsafePaste;

  /// Keeps the paste in order with typed keys; without it the paste goes
  /// out when the clipboard answers.
  PasteSequencer? sequencer;

  @override
  bool isEnabled(PasteTextIntent intent) => !readOnly && !text.isDisposed;

  @override
  Future<void> invoke(PasteTextIntent intent) async {
    final sequencer = this.sequencer;
    final token = sequencer?.hold();
    void deliver(VoidCallback? send) {
      if (sequencer != null) {
        sequencer.release(token!, send);
      } else {
        send?.call();
      }
    }

    final String? value;
    try {
      value = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      deliver(null);
      rethrow;
    }
    if (value == null || value.isEmpty || text.isDisposed) {
      deliver(null);
      return;
    }
    final pasted = value;
    // The rejection is only known once the paste reached its turn.
    deliver(() {
      if (text.paste(pasted) == PasteResult.rejected) {
        unawaited(_confirm(pasted));
      }
    });
  }

  Future<void> _confirm(String value) async {
    final confirm = onUnsafePaste;
    if (confirm != null && await confirm(value) && !text.isDisposed) {
      text.paste(value, allowUnsafe: true);
    }
  }
}
