/// Stateless encoders: focus reports (`focus.h`), paste safety and encoding
/// (`paste.h`), size reports (`size_report.h`), DECRPM mode reports
/// (`modes.h`) and colour scheme reports (`color_scheme.h`).
///
/// None of them needs a terminal or creates a native object.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../terminal/terminal.dart' show VtTerminal;
import 'reports.dart';

/// Most reports are under 32 bytes, so one native call is enough.
const _reportCapacity = 32;

/// Room for the bracketed paste start and end markers (`ESC [ 200 ~` and
/// `ESC [ 201 ~`).
const _bracketOverhead = 12;

/// Encodes a focus report: `CSI I` for [VtFocusEvent.gained], `CSI O` for
/// [VtFocusEvent.lost].
///
/// Send it only to a program that enabled focus reporting
/// ([TerminalMode.focusEvent], DEC mode 1004). Throws [ArgumentError] for
/// [VtFocusEvent.unknown].
///
/// ```dart
/// // In the widget's focus listener, while mode 1004 is set:
/// pty.write(encodeFocusEvent(VtFocusEvent.gained));
/// ```
Uint8List encodeFocusEvent(VtFocusEvent event) {
  final raw = vtFocusEventCodec.encode(event);
  ensureCompatibleLibrary();
  return callWithSizeQuery(
    'ghostty_focus_encode',
    (buffer, capacity, written) =>
        ghostty_focus_encode(raw, buffer, capacity, written),
    initialCapacity: _reportCapacity,
  );
}

/// Whether [text] is safe to paste without asking the user first.
///
/// Text is unsafe if it contains a line terminator (`\n` or `\r`, which
/// would run a command on an unbracketed paste) or the bracketed paste end
/// marker `ESC [ 201 ~` (which would end bracketed paste early). The check
/// is conservative: it ignores the terminal's modes, so it may flag text
/// that a bracketed paste would deliver safely.
bool isPasteSafe(String text) {
  ensureCompatibleLibrary();
  return withUtf8(
    text,
    (data, length) => ghostty_paste_is_safe(data.cast(), length),
  );
}

/// Encodes [text] for writing to the pty as a paste.
///
/// Unsafe control bytes (NUL, ESC, DEL, ...) become spaces. With
/// [bracketed] (when the program enabled [TerminalMode.bracketedPaste],
/// DEC mode 2004) the text is wrapped in `ESC [ 200 ~` … `ESC [ 201 ~`;
/// without it, newlines become carriage returns.
///
/// This does not check safety: call [isPasteSafe] first and confirm with
/// the user if it returns `false`. To paste into a [VtTerminal] with its
/// current modes, prefer the terminal's own paste support.
Uint8List encodePaste(String text, {required bool bracketed}) {
  ensureCompatibleLibrary();
  // The library rewrites its input in place, so it works on the pooled
  // native copy of the UTF-8 text, never on Dart memory. Retrying with the
  // rewritten input gives the same result (paste.h).
  return withUtf8(
    text,
    (data, length) => callWithSizeQuery(
      'ghostty_paste_encode',
      (buffer, capacity, written) => ghostty_paste_encode(
        data.cast(),
        length,
        bracketed,
        buffer,
        capacity,
        written,
      ),
      initialCapacity: length + _bracketOverhead,
    ),
  );
}

/// Encodes a size report in [style] for a terminal of [size].
///
/// A [VtTerminal] answers size queries itself through its size callback;
/// use this when you need to send a report yourself. Throws [ArgumentError]
/// for [SizeReportStyle.unknown] and [RangeError] if a [size] value is out
/// of range (rows and columns 0–65535, cell sizes 0–0xFFFFFFFF).
///
/// ```dart
/// final report = encodeSizeReport(
///   SizeReportStyle.csi18t,
///   const SizeReportSize(rows: 24, columns: 80, cellWidth: 9, cellHeight: 18),
/// ); // ESC [ 8 ; 24 ; 80 t
/// ```
Uint8List encodeSizeReport(SizeReportStyle style, SizeReportSize size) {
  final raw = sizeReportStyleCodec.encode(style);
  RangeError.checkValueInInterval(size.rows, 0, 0xFFFF, 'rows');
  RangeError.checkValueInInterval(size.columns, 0, 0xFFFF, 'columns');
  RangeError.checkValueInInterval(size.cellWidth, 0, 0xFFFFFFFF, 'cellWidth');
  RangeError.checkValueInInterval(size.cellHeight, 0, 0xFFFFFFFF, 'cellHeight');
  ensureCompatibleLibrary();
  return withScratch(sizeOf<GhosttySizeReportSize>(), (memory) {
    final native = memory.cast<GhosttySizeReportSize>();
    native.ref
      ..rows = size.rows
      ..columns = size.columns
      ..cell_width = size.cellWidth
      ..cell_height = size.cellHeight;
    return callWithSizeQuery(
      'ghostty_size_report_encode',
      (buffer, capacity, written) =>
          ghostty_size_report_encode(raw, native, buffer, capacity, written),
      initialCapacity: _reportCapacity,
    );
  });
}

/// Encodes a DECRPM mode report saying that [mode] is in [state]:
/// `CSI ? mode ; state $ y` for DEC private modes, `CSI mode ; state $ y`
/// for ANSI modes.
///
/// A [VtTerminal] answers `DECRQM` queries itself; use this to report a
/// mode the host owns. Throws [ArgumentError] for
/// [ModeReportState.unknown].
Uint8List encodeModeReport(TerminalMode mode, ModeReportState state) {
  final rawMode = terminalModeToRaw(mode);
  final rawState = modeReportStateCodec.encode(state);
  ensureCompatibleLibrary();
  return callWithSizeQuery(
    'ghostty_mode_report_encode',
    (buffer, capacity, written) => ghostty_mode_report_encode(
      rawMode,
      rawState,
      buffer,
      capacity,
      written,
    ),
    initialCapacity: _reportCapacity,
  );
}

/// Encodes a colour scheme report: `CSI ? 997 ; 1 n` for
/// [VtColorScheme.dark], `CSI ? 997 ; 2 n` for [VtColorScheme.light].
///
/// Send it unsolicited when the scheme changes, but only while the program
/// has [TerminalMode.reportColorScheme] (DEC mode 2031) set. Queries
/// (`CSI ? 996 n`) are answered by the terminal itself. Throws
/// [ArgumentError] for [VtColorScheme.unknown].
Uint8List encodeColorSchemeReport(VtColorScheme scheme) {
  final raw = vtColorSchemeCodec.encode(scheme);
  ensureCompatibleLibrary();
  return callWithSizeQuery(
    'ghostty_color_scheme_report_encode',
    (buffer, capacity, written) =>
        ghostty_color_scheme_report_encode(raw, buffer, capacity, written),
    initialCapacity: _reportCapacity,
  );
}
