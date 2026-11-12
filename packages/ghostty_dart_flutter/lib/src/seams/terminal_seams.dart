/// The internal seams between the view's parts (ADR 0011): the renderer,
/// keyboard and text input, and pointer, selection and scrolling program
/// against these interfaces only, so each can be built and tested without
/// the others. Never exported.
///
/// `ControllerSeams` (controller_seams.dart) implements all of them on top
/// of a [VtTerminalController]; the view creates one per controller and
/// passes it to each part. Tests should use a `ControllerSeams` over a real
/// controller, or `extends Fake` (flutter_test) rather than `implements`,
/// so members added later do not break them.
///
/// **Disposal.** Once [TerminalFrameSource.isDisposed] (or the same getter
/// of any other seam) is `true` the controller is gone: the renderer paints
/// the background only and never calls `updateFrame`, and every sink
/// method is a no-op returning a neutral value (`false`, `null`, nothing).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../controller/terminal_controller.dart';
import '../theme/terminal_theme.dart';

/// A highlight to paint, in viewport cells: from ([startX], [startY]) to
/// ([endX], [endY]), both inclusive, in line order. The rows may lie
/// above the viewport (negative) or below it; clip them to the grid.
typedef ViewportHighlight = ({
  Color color,
  int startX,
  int startY,
  int endX,
  int endY,
});

/// What the renderer reads, once per frame.
///
/// The [Listenable] notifies after anything visible may have changed
/// (output, resize, scroll, selection, theme, end of a render hold); the
/// renderer answers with `markNeedsPaint`, never with layout.
///
/// **Colours.** Every cell, default background (also for the padding) and
/// cursor colour comes from [RenderState.colors], which includes the
/// program's OSC 4/10/11/12 changes. [theme] is only for what the terminal
/// does not know: [VtTerminalTheme.selection] and the search colours. The
/// theme's cursor colour is pushed into the terminal opaque; when
/// `colors.cursor` still equals `VtTerminalTheme.rgbOf(theme.cursor)` (the
/// program did not change it), draw [VtTerminalTheme.cursor] to keep its
/// alpha.
abstract interface class TerminalFrameSource implements Listenable {
  /// Whether the controller was disposed. Then paint the background only.
  bool get isDisposed;

  /// The view's theme: selection and search colours (see the class docs).
  VtTerminalTheme get theme;

  /// Whether the program holds rendering (synchronized output, DEC mode
  /// 2026). While `true`, do not call [updateFrame]: keep showing the
  /// cached row pictures. A notification follows when the hold ends,
  /// including when the controller ends it after
  /// [VtTerminalController.renderHoldTimeout].
  bool get isRenderHeld;

  /// Copies the terminal into the shared [RenderState] and returns it.
  ///
  /// Call it once per paint, from `paint` (never from inside a terminal
  /// callback). The rows the state yields are borrowed until the next
  /// [updateFrame] or [endFrame] (see [RenderState]). The same instance is
  /// returned every time. Throws [StateError] after disposal.
  RenderState updateFrame();

  /// Marks the frame drawn ([RenderState.markClean]). Call it after every
  /// row of [RenderState.dirtyRows] was re-recorded.
  void endFrame();

  /// The controller's highlights ([VtTerminalController.addHighlight])
  /// that may be visible, in creation order, positioned for the viewport
  /// as of now. Read it once per paint, next to [updateFrame], and not
  /// while [isRenderHeld]. Empty when there are none or after disposal.
  List<ViewportHighlight> viewportHighlights();

  /// Tells the source that a frame was painted, and whether output floods
  /// the view: every visible row was replaced in each of the last frames
  /// (output scrolling a screen or more per frame, faster than anyone can
  /// read). While it floods, the source may deliver its notifications
  /// later, at the start of a frame a whole number of vsyncs after this
  /// paint (the controller's seams: [ControllerSeams.floodPacing] and
  /// [ControllerSeams.floodVsyncs]), so the renderer and every other
  /// listener of the view update together in fewer, evenly spaced frames.
  void painted({required bool flooded});
}

/// Where keys go: hardware keys and on-screen toolbar keys.
abstract interface class TerminalKeySink {
  /// Whether the controller was disposed; [sendKey] then does nothing.
  bool get isDisposed;

  /// Encodes [event] for the terminal's current modes and sends it to the
  /// program. Returns `true` if bytes were sent. See
  /// [VtTerminalController.sendKey].
  bool sendKey(VtKeyEvent event);

  /// Modifiers latched by `VtTerminalKeyToolbar` (Ctrl, Alt). The input
  /// layer adds them to the next key or text it sends and then resets this
  /// to [KeyModifiers.none].
  ValueNotifier<KeyModifiers> get latchedModifiers;
}

/// Where text goes: committed IME and soft-keyboard text, the clipboard,
/// focus reports.
///
/// The [Listenable] notifies whenever output may have moved the cursor:
/// re-read [cursorViewportCell] then. Coalesce the platform calls it
/// causes (caret and composing rects) to once per frame, with a
/// post-frame callback, not once per notification.
abstract interface class TerminalTextSink implements Listenable {
  /// Whether the controller was disposed; the methods then do nothing.
  bool get isDisposed;

  /// Sends committed text unchanged, as UTF-8. See
  /// [VtTerminalController.sendText].
  void sendText(String text);

  /// Pastes [text]; see [VtTerminalController.paste]. Returns
  /// [PasteResult.nothingToPaste] after disposal.
  PasteResult paste(String text, {bool allowUnsafe = false});

  /// Reports a focus change (only sent while DEC mode 1004 is set).
  void sendFocus({required bool focused});

  /// The selected text for copying, or `null`.
  String? get selectedText;

  /// The cursor's cell in the viewport, for the IME caret and composing
  /// rectangles, or `null` while the cursor is scrolled out of view.
  GridPoint? get cursorViewportCell;

  /// Whether the program is reading a password (the terminal's
  /// password-input heuristic, `RenderCursor.isPasswordInput`) as of the
  /// last painted frame; the text input should then disable suggestions
  /// and personalised learning.
  bool get isPasswordInput;
}

/// The viewport: the scrollback position and how to move it.
abstract interface class TerminalViewport implements Listenable {
  /// Whether the controller was disposed; [scrollViewport] then does
  /// nothing.
  bool get isDisposed;

  /// The viewport's position; poll it when notified.
  ViewportScrollbar get scrollbar;

  /// Moves the viewport.
  void scrollViewport(ViewportScroll target);

  /// Whether the alternate screen is active (no scrollback; the wheel
  /// sends arrow keys when DEC mode 1007 is set).
  bool get isAlternateScreen;
}

/// Where pointer events go: mouse reports and selection.
abstract interface class TerminalPointerSink {
  /// Whether the controller was disposed; the methods then do nothing and
  /// the getters return neutral values.
  bool get isDisposed;

  /// Whether the program tracks the mouse. While `true`, pointer events go
  /// to [sendMouse] unless Shift is held.
  bool get isMouseTracking;

  /// Whether [mode] is set (e.g. [TerminalMode.mouseAlternateScroll]).
  bool isModeEnabled(TerminalMode mode);

  /// The pointer shape the program asked for (OSC 22).
  MouseShape get mouseShape;

  /// Sets the geometry the mouse encoder converts pixels with; pass
  /// `TerminalGeometry.mouseEncoderSize` after every layout change.
  void setMouseGeometry(MouseEncoderSize size);

  /// Tells the mouse encoder whether any button is held (button-event
  /// tracking reports motion only while one is).
  void setMouseButtonsPressed({required bool anyPressed});

  /// Encodes and sends a mouse report. Positions are device pixels from the
  /// top-left of the view, padding included. Returns `true` if bytes were
  /// sent.
  bool sendMouse(VtMouseEvent event);

  /// The terminal, for creating the view's [SelectionGesture] (owned and
  /// disposed by the pointer layer) and the `select…` methods of
  /// [VtTerminalSelection]. Throws [StateError] after disposal.
  VtTerminal get terminal;

  /// The current selection; setting it highlights it and notifies.
  /// Reading returns a borrowed snapshot that goes stale on the next
  /// write, scroll or selection change: read it again, never keep it.
  VtSelection? get selection;
  set selection(VtSelection? value);
}
