/// Value types for the stateless encoders: focus events (`focus.h`), DECRPM
/// mode report states (`modes.h`), colour schemes (`device.h`,
/// `color_scheme.h`) and size reports (`size_report.h`).
///
/// Pure Dart: no `dart:ffi`, so a future web backend can reuse it.
library;

import '../core/enum_codec.dart';

/// A focus change to report to a program that enabled focus reporting
/// (`GhosttyFocusEvent`, DEC mode 1004).
///
/// Named `VtFocusEvent` because `FocusEvent` clashes with the web DOM type.
enum VtFocusEvent {
  /// The terminal gained focus (`CSI I`).
  gained(0),

  /// The terminal lost focus (`CSI O`).
  lost(1),

  /// An event added by a later libghostty-vt release.
  unknown(null);

  const VtFocusEvent(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyFocusEvent` values to [VtFocusEvent] and back.
final vtFocusEventCodec = RawEnumCodec<VtFocusEvent>(
  VtFocusEvent.values,
  raw: (v) => v._raw,
  unknown: VtFocusEvent.unknown,
);

/// The state of a mode in a DECRPM report (`GhosttyModeReportState`, the
/// `Ps2` of `CSI ? Ps1 ; Ps2 $ y`).
enum ModeReportState {
  /// The mode is not recognized (0).
  notRecognized(0),

  /// The mode is set (1).
  set(1),

  /// The mode is reset (2).
  reset(2),

  /// The mode is permanently set (3).
  permanentlySet(3),

  /// The mode is permanently reset (4).
  permanentlyReset(4),

  /// A state added by a later libghostty-vt release.
  unknown(null);

  const ModeReportState(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyModeReportState` values to [ModeReportState] and
/// back.
final modeReportStateCodec = RawEnumCodec<ModeReportState>(
  ModeReportState.values,
  raw: (v) => v._raw,
  unknown: ModeReportState.unknown,
);

/// Whether the terminal's colours are light or dark (`GhosttyColorScheme`),
/// as reported to programs that ask (`CSI ? 996 n`) or subscribe (DEC mode
/// 2031).
///
/// Named `VtColorScheme` because `ColorScheme` clashes with Flutter's.
enum VtColorScheme {
  /// A light colour scheme (reported as `CSI ? 997 ; 2 n`).
  light(0),

  /// A dark colour scheme (reported as `CSI ? 997 ; 1 n`).
  dark(1),

  /// A scheme added by a later libghostty-vt release.
  unknown(null);

  const VtColorScheme(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyColorScheme` values to [VtColorScheme] and back.
final vtColorSchemeCodec = RawEnumCodec<VtColorScheme>(
  VtColorScheme.values,
  raw: (v) => v._raw,
  unknown: VtColorScheme.unknown,
);

/// The format of a size report (`GhosttySizeReportStyle`).
///
/// Member names follow the C suffixes: the in-band report of mode 2048 and
/// the XTWINOPS replies to `CSI 14 t`, `CSI 16 t`, `CSI 18 t` and
/// `CSI 19 t`.
enum SizeReportStyle {
  /// In-band size report (mode 2048):
  /// `ESC [ 48 ; rows ; cols ; height ; width t`, height and width in
  /// pixels of the text area.
  mode2048(0),

  /// Text area size in pixels: `ESC [ 4 ; height ; width t`.
  csi14t(1),

  /// Cell size in pixels: `ESC [ 6 ; height ; width t`.
  csi16t(2),

  /// Text area size in cells: `ESC [ 8 ; rows ; cols t`.
  csi18t(3),

  /// Screen size in cells: `ESC [ 9 ; rows ; cols t`. The physical screen
  /// size is unknown, so this reports the text area, like [csi18t].
  csi19t(4),

  /// A style added by a later libghostty-vt release.
  unknown(null);

  const SizeReportStyle(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttySizeReportStyle` values to [SizeReportStyle] and
/// back.
final sizeReportStyleCodec = RawEnumCodec<SizeReportStyle>(
  SizeReportStyle.values,
  raw: (v) => v._raw,
  unknown: SizeReportStyle.unknown,
);

/// The terminal size a size report describes (`GhosttySizeReportSize`).
final class SizeReportSize {
  /// Creates a size of [columns] × [rows] cells (each 0–65535) whose cells
  /// are [cellWidth] × [cellHeight] pixels (each 0–0xFFFFFFFF). Validated
  /// when encoded ([RangeError]).
  const SizeReportSize({
    required this.rows,
    required this.columns,
    required this.cellWidth,
    required this.cellHeight,
  });

  /// The number of rows.
  final int rows;

  /// The number of columns.
  final int columns;

  /// The width of one cell in pixels.
  final int cellWidth;

  /// The height of one cell in pixels.
  final int cellHeight;

  @override
  bool operator ==(Object other) =>
      other is SizeReportSize &&
      other.rows == rows &&
      other.columns == columns &&
      other.cellWidth == cellWidth &&
      other.cellHeight == cellHeight;

  @override
  int get hashCode => Object.hash(rows, columns, cellWidth, cellHeight);

  @override
  String toString() =>
      'SizeReportSize(${columns}x$rows cells, cell ${cellWidth}x${cellHeight}px)';
}
