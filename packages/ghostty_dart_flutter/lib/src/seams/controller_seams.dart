import 'package:flutter/foundation.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../controller/controller_internals.dart';
import '../controller/terminal_controller.dart';
import '../theme/terminal_theme.dart';
import 'terminal_geometry.dart';
import 'terminal_seams.dart';

/// Implements every seam on top of one [VtTerminalController]. The view
/// creates one per controller and hands it to the renderer, the input
/// layers and the scrollbar. Never exported.
///
/// After the controller is disposed, the sinks are no-ops (see the
/// library docs of `terminal_seams.dart`).
final class ControllerSeams
    implements
        TerminalFrameSource,
        TerminalKeySink,
        TerminalTextSink,
        TerminalViewport,
        TerminalPointerSink {
  /// Seams for [controller], which must not be disposed.
  ControllerSeams(this.controller) : _internals = internalsOf(controller) {
    _internals.usedByWidgets = true;
  }

  /// The controller every seam delegates to.
  final VtTerminalController controller;
  final ControllerInternals _internals;

  @override
  bool get isDisposed => controller.isDisposed;

  // Listenable (frame source, text sink and viewport).

  @override
  void addListener(VoidCallback listener) {
    if (!isDisposed) controller.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener); // allowed after dispose

  // Layout (the view)

  /// Resizes the terminal to [geometry] from the view's layout: the
  /// terminal changes at once, while `onResize` and the listener
  /// notification run after the frame, where listeners may rebuild.
  void resizeDuringLayout(TerminalGeometry geometry) {
    if (isDisposed) return;
    _internals.resizeDuringLayout(
      geometry.cols,
      geometry.rows,
      cellWidthPx: geometry.metrics.widthPx,
      cellHeightPx: geometry.metrics.heightPx,
    );
  }

  /// Gives up reading frames, so another seams object (a new view of the
  /// same controller) may. The view calls it when it is disposed.
  void release() {
    if (!isDisposed && identical(_internals.frameOwner, this)) {
      _internals.frameOwner = null;
    }
  }

  // TerminalFrameSource

  @override
  VtTerminalTheme get theme => controller.theme;

  @override
  bool get isRenderHeld => !isDisposed && _internals.isRenderHeld;

  @override
  RenderState updateFrame() {
    final internals = internalsOf(controller);
    assert(
      internals.frameOwner == null || identical(internals.frameOwner, this),
      'Two views read frames from one VtTerminalController; a controller '
      'drives at most one VtTerminalView at a time.',
    );
    internals.frameOwner = this;
    return internals.renderState..update(controller.terminal);
  }

  @override
  void endFrame() => internalsOf(controller).renderState.markClean();

  // TerminalKeySink

  @override
  bool sendKey(VtKeyEvent event) => !isDisposed && controller.sendKey(event);

  @override
  ValueNotifier<KeyModifiers> get latchedModifiers =>
      _internals.latchedModifiers;

  // TerminalTextSink

  @override
  void sendText(String text) {
    if (!isDisposed) controller.sendText(text);
  }

  @override
  PasteResult paste(String text, {bool allowUnsafe = false}) => isDisposed
      ? PasteResult.nothingToPaste
      : controller.paste(text, allowUnsafe: allowUnsafe);

  @override
  void sendFocus({required bool focused}) {
    if (!isDisposed) controller.sendFocus(focused: focused);
  }

  @override
  String? get selectedText => isDisposed ? null : controller.selectedText;

  @override
  GridPoint? get cursorViewportCell {
    if (isDisposed) return null;
    final vt = controller.terminal;
    final scrollbar = vt.scrollbar;
    // The active area is the last `rows` rows of the scrollable area; the
    // viewport starts `offset` rows from its top.
    final y = vt.cursorY + (scrollbar.total - vt.rows) - scrollbar.offset;
    if (y < 0 || y >= vt.rows) return null;
    return GridPoint.viewport(vt.cursorX, y);
  }

  @override
  bool get isPasswordInput =>
      !isDisposed && _internals.renderState.cursor.isPasswordInput;

  // TerminalViewport

  @override
  ViewportScrollbar get scrollbar => isDisposed
      ? const ViewportScrollbar(total: 0, offset: 0, length: 0)
      : controller.scrollbar;

  @override
  void scrollViewport(ViewportScroll target) {
    if (!isDisposed) controller.scrollViewport(target);
  }

  @override
  bool get isAlternateScreen => !isDisposed && controller.isAlternateScreen;

  // TerminalPointerSink

  @override
  bool get isMouseTracking => !isDisposed && controller.isMouseTracking;

  @override
  bool isModeEnabled(TerminalMode mode) =>
      !isDisposed && controller.isModeEnabled(mode);

  @override
  MouseShape get mouseShape =>
      isDisposed ? MouseShape.defaultShape : controller.mouseShape;

  @override
  void setMouseGeometry(MouseEncoderSize size) {
    if (!isDisposed) _internals.mouseEncoder.configure(size: size);
  }

  @override
  void setMouseButtonsPressed({required bool anyPressed}) {
    if (!isDisposed) {
      _internals.mouseEncoder.configure(anyButtonPressed: anyPressed);
    }
  }

  @override
  bool sendMouse(VtMouseEvent event) =>
      !isDisposed && controller.sendMouse(event);

  @override
  VtTerminal get terminal {
    if (isDisposed) {
      throw StateError('VtTerminalController has been disposed');
    }
    return controller.terminal;
  }

  @override
  VtSelection? get selection => isDisposed ? null : controller.selection;

  @override
  set selection(VtSelection? value) {
    if (!isDisposed) controller.selection = value;
  }
}
