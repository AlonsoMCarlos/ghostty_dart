import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

/// What a `Buffer`, its lines and its anchors need from the `Terminal`
/// that owns them, beyond xterm's public API. Never exported.
///
/// `Terminal` creates one in its constructor and binds it with
/// [bindTerminalEngine]; `Buffer` finds it with [terminalEngineOf].
final class TerminalEngine {
  /// Creates the engine state for a terminal that wraps [controller].
  TerminalEngine(this.controller);

  /// The controller the terminal owns.
  final VtTerminalController controller;

  /// Bumped whenever what the terminal shows may have changed (a write, a
  /// resize, a scroll, the alternate screen): line snapshots taken at an
  /// older epoch are stale.
  int epoch = 0;

  /// Whether the terminal has been disposed.
  bool isDisposed = false;

  /// Writes [sequence] (an escape sequence the terminal emulates an xterm
  /// method with) to the engine, or throws [StateError] when the
  /// program's output stopped inside a sequence. Set by `Terminal`.
  late void Function(String sequence) writeSequence;

  /// The libghostty-vt terminal. Throws [StateError] after the terminal
  /// was disposed.
  VtTerminal get vt {
    if (isDisposed) {
      throw StateError('the Terminal has been disposed');
    }
    return controller.terminal;
  }

  /// Marks every line snapshot stale.
  void invalidate() => epoch++;
}

final _engines = Expando<TerminalEngine>('TerminalEngine');

/// Binds [engine] to [terminal] (a `Terminal`); once, in its constructor.
void bindTerminalEngine(Object terminal, TerminalEngine engine) {
  assert(_engines[terminal] == null, 'engine bound twice');
  _engines[terminal] = engine;
}

/// The engine bound to [terminal], or `null` when [terminal] is not a
/// `Terminal` of this package (a hand-written `TerminalState`).
TerminalEngine? terminalEngineOf(Object terminal) => _engines[terminal];

/// [text] without control characters (C0, DEL, C1), so that writing it to
/// the terminal prints it and interprets nothing.
String printableText(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (!isControlCharacter(rune)) out.writeCharCode(rune);
  }
  return out.toString();
}

/// Whether [codePoint] is a C0 or C1 control character or DEL.
bool isControlCharacter(int codePoint) =>
    codePoint < 0x20 || (codePoint >= 0x7f && codePoint < 0xa0);
