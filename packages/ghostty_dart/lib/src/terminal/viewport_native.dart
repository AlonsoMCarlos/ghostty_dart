/// Internal implementation of `VtTerminal.scrollbar` and
/// `VtTerminal.scrollViewport`. Not exported.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import 'terminal_native.dart';
import 'viewport.dart';

typedef _ScrollTag = GhosttyTerminalScrollViewportTag;

/// Reads `GHOSTTY_TERMINAL_DATA_SCROLLBAR`.
ViewportScrollbar readScrollbar(Pointer<GhosttyTerminalImpl> terminal) =>
    readData(
      terminal,
      GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SCROLLBAR,
      sizeOf<GhosttyTerminalScrollbar>(),
      (out) {
        final bar = out.cast<GhosttyTerminalScrollbar>().ref;
        return ViewportScrollbar(
          total: bar.total,
          offset: bar.offset,
          length: bar.len,
        );
      },
    );

/// Moves the viewport of the terminal behind [handle] to [target]: inside
/// [NativeHandle.use], then bumps the epoch. Throws [RangeError] for a
/// negative [ScrollToRow.row].
void scrollViewportTo(
  NativeHandle<GhosttyTerminalImpl> handle,
  ViewportScroll target,
) {
  if (target case ScrollToRow(:final row)) {
    RangeError.checkNotNegative(row, 'row');
  }
  final raw = using((arena) {
    final behavior = arena<GhosttyTerminalScrollViewport>();
    _encode(target, behavior.ref);
    return handle.use(
      (terminal) => ghostty_terminal_scroll_viewport(terminal, behavior.ref),
    );
  });
  handle.bumpEpoch();
  checkResult(raw, 'ghostty_terminal_scroll_viewport');
}

/// Writes [target] into the tagged union [out].
void _encode(ViewportScroll target, GhosttyTerminalScrollViewport out) {
  final value = out.value;
  switch (target) {
    case ScrollToTop():
      out.tag = _ScrollTag.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP;
    case ScrollToBottom():
      out.tag = _ScrollTag.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM;
    case ScrollByRows(:final rows):
      out.tag = _ScrollTag.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA;
      value.delta = rows;
    case ScrollToRow(:final row):
      out.tag = _ScrollTag.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW;
      value.row = row;
    case ScrollByPrompts(:final prompts):
      out.tag = _ScrollTag.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT;
      value.delta_prompt = prompts;
  }
}
