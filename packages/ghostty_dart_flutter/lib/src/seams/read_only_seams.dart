import 'package:flutter/foundation.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import 'controller_seams.dart';
import 'terminal_seams.dart';

/// The pointer layer's view of [seams] for a read-only view: the program
/// never receives mouse reports, wheel reports or alternate-scroll keys,
/// so every press selects and the wheel scrolls the scrollback (the
/// viewport is still moved through [seams] itself). Never exported.
///
/// The view creates one per [ControllerSeams] and keeps it while the view
/// is read-only, because the pointer layer needs a stable sink.
final class ReadOnlyPointerSeams
    implements TerminalPointerSink, TerminalTextSink, TerminalKeySink {
  /// A read-only wrapper of [seams].
  ReadOnlyPointerSeams(this.seams);

  /// The seams every read goes to.
  final ControllerSeams seams;

  @override
  bool get isDisposed => seams.isDisposed;

  // TerminalPointerSink: no tracking, no reports.

  @override
  bool get isMouseTracking => false;

  @override
  bool isModeEnabled(TerminalMode mode) =>
      mode != TerminalMode.mouseAlternateScroll && seams.isModeEnabled(mode);

  @override
  MouseShape get mouseShape => seams.mouseShape;

  @override
  void setMouseGeometry(MouseEncoderSize size) => seams.setMouseGeometry(size);

  @override
  void setMouseButtonsPressed({required bool anyPressed}) {}

  @override
  bool sendMouse(VtMouseEvent event) => false;

  @override
  VtTerminal get terminal => seams.terminal;

  @override
  VtSelection? get selection => seams.selection;

  @override
  set selection(VtSelection? value) => seams.selection = value;

  // TerminalTextSink and TerminalKeySink: nothing reaches the program.

  @override
  void addListener(VoidCallback listener) => seams.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => seams.removeListener(listener);

  @override
  void sendText(String text) {}

  @override
  PasteResult paste(String text, {bool allowUnsafe = false}) =>
      PasteResult.nothingToPaste;

  @override
  void sendFocus({required bool focused}) {}

  @override
  String? get selectedText => seams.selectedText;

  @override
  GridPoint? get cursorViewportCell => seams.cursorViewportCell;

  @override
  bool get isPasswordInput => seams.isPasswordInput;

  @override
  bool sendKey(VtKeyEvent event) => false;

  @override
  ValueNotifier<KeyModifiers> get latchedModifiers => seams.latchedModifiers;
}
