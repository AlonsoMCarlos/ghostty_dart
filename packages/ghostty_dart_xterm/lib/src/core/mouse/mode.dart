// Ported from package:xterm 4.0.0 (lib/src/core/mouse/mode.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// Which mouse events the program asked to receive.
///
/// See https://terminalguide.namepad.de/mouse/.
enum MouseMode {
  /// No mouse reporting.
  none,

  /// Button presses only (X10, DEC mode 9).
  clickOnly,

  /// Presses, releases and the wheel (DEC mode 1000).
  upDownScroll(reportScroll: true),

  /// As [upDownScroll], plus motion while a button is held (DEC mode
  /// 1002).
  upDownScrollDrag(reportScroll: true),

  /// As [upDownScroll], plus all motion (DEC mode 1003).
  upDownScrollMove(reportScroll: true);

  const MouseMode({this.reportScroll = false});

  /// Whether wheel events are reported in this mode.
  final bool reportScroll;
}

/// How mouse events are encoded.
///
/// See https://terminalguide.namepad.de/mouse/.
enum MouseReportMode {
  /// The default mouse reporting mode where digits are encoded as bytes with
  /// `32 + code`. This mode has a range from 1 to 223.
  normal,

  /// When code < 96 this is the same as [normal], otherwise the `code + 32` is
  /// encoded as 2 bytes in UTF-8. This mode has a range from 1 to 2015.
  utf,

  /// In this mode the code are encoded as 10-based numbers. Tha range is
  /// unlimited.
  sgr,

  /// Similar to [sgr], the difference is that the button id is encoded as
  /// `32 + code`.
  urxvt,
}
