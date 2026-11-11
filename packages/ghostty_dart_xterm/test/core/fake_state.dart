import 'package:ghostty_dart_xterm/core.dart';

/// A [TerminalState] whose modes the tests set directly.
class FakeState implements TerminalState {
  @override
  int viewWidth = 80;

  @override
  int viewHeight = 24;

  @override
  final CursorStyle cursor = CursorStyle();

  @override
  bool reflowEnabled = true;

  @override
  bool insertMode = false;

  @override
  bool lineFeedMode = false;

  @override
  bool cursorKeysMode = false;

  @override
  bool reverseDisplayMode = false;

  @override
  bool originMode = false;

  @override
  bool autoWrapMode = true;

  @override
  MouseMode mouseMode = MouseMode.none;

  @override
  MouseReportMode mouseReportMode = MouseReportMode.normal;

  @override
  bool cursorBlinkMode = false;

  @override
  bool cursorVisibleMode = true;

  @override
  bool appKeypadMode = false;

  @override
  bool reportFocusMode = false;

  @override
  bool altBufferMouseScrollMode = false;

  @override
  bool bracketedPasteMode = false;
}
