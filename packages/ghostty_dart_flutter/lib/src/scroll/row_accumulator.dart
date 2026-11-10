/// Turns pixel scroll deltas into whole rows (ADR 0011: scrolling is
/// driven by pointer deltas with fractional-row accumulation). Never
/// exported.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// Accumulates pixel deltas and hands out whole rows, keeping the
/// remainder for the next delta.
///
/// Mirrors Ghostty's `scrollCallback` (`src/Surface.zig` at tag `vt-1.0.0`): a
/// delta smaller than one cell is kept pending, and a larger one scrolls by
/// the number of whole cells it covers, rounded towards zero. Unlike
/// Ghostty the remainder is kept exactly, so slow trackpad scrolling never
/// loses distance.
final class RowAccumulator {
  double _pending = 0;

  /// The distance not yet turned into rows, in the units of [add].
  double get pending => _pending;

  /// Adds [delta] (positive is down, towards newer output) and returns the
  /// whole rows of [rowExtent] it completes, negative for up.
  ///
  /// A non-finite [delta] or a non-positive [rowExtent] adds nothing.
  int add(double delta, double rowExtent) {
    if (!delta.isFinite || !(rowExtent > 0) || !rowExtent.isFinite) return 0;
    final total = _pending + delta;
    final rows = (total / rowExtent).truncate();
    _pending = total - rows * rowExtent;
    return rows;
  }

  /// Drops the pending distance (at the start or end of a gesture, or
  /// when scrolling is cancelled).
  void reset() => _pending = 0;
}

/// Logical pixels per wheel line in Flutter's macOS embedder for a wheel
/// without precise deltas (`FlutterViewController.mm`, `dispatchMouseEvent`:
/// `pixelsPerLine = 40.0`, Flutter 3.47.9).
const double macOSWheelPixelsPerLine = 40;

/// Rows per wheel line for a discrete (notched) wheel: Ghostty's default
/// `mouse-scroll-multiplier` for discrete scrolling (`discrete: f64 = 3`,
/// `src/config/Config.zig` at tag `vt-1.0.0`).
const double discreteWheelRowsPerLine = 3;

/// Events of one wheel stream arrive closer together than this; an event
/// after a longer pause starts a new stream. Precise-delta devices and fast
/// wheel spins send events every frame (8–17 ms); a slow notch arrives on
/// its own.
const Duration wheelStreamGap = Duration(milliseconds: 100);

/// The scroll distance, in pixels, that a wheel event of [delta] logical
/// pixels should add to a [RowAccumulator] of [rowExtent] rows.
///
/// Flutter exposes no "precise deltas" flag on [PointerScrollEvent]; the
/// signals it does give are the device kind and the time stamp:
/// - On macOS, the embedder sends every scroll with gesture phases (the
///   trackpad, the Magic Mouse) as pan-zoom events of kind
///   [PointerDeviceKind.trackpad], and only phase-less `NSEventTypeScrollWheel`
///   events as scroll signals of kind [PointerDeviceKind.mouse]: `lines × 40`
///   px without precise deltas, raw pixels with them
///   (`FlutterViewController.mm`, `dispatchMouseEvent`, Flutter 3.47.9).
/// - macOS ramps a notched wheel's magnitude with its speed, so one slow
///   notch arrives alone as about 0.1 line (4 px), less than a row.
///
/// So on macOS an [isolated] mouse-kind event (none in the previous
/// [wheelStreamGap]) is taken as a discrete notch and, like Ghostty's
/// `scrollCallback` (`src/Surface.zig` at tag `vt-1.0.0`: at least one line
/// on Darwin, times `mouse-scroll-multiplier.discrete`, 3,
/// `src/config/Config.zig`), scrolls `max(lines, 1) × 3` rows. Events inside
/// a stream (fast notches, or a precise device without phases) keep their
/// pixel deltas and accumulate, so a smooth-scrolling mouse is never sped
/// up. Its first event can still count as a notch (one 3-row step).
///
/// Other platforms pass through unchanged: Linux sends 53 px per discrete
/// notch (`fl_scrolling_manager.cc`) and fractions of it for high-resolution
/// wheels, Windows the system's lines × 20 px (`flutter_window.cc`). With
/// rows taller than one notch, a Linux notch can scroll no row until the
/// next one (accepted for v0.1, ADR 0011).
double wheelScrollExtent(
  double delta,
  double rowExtent, {
  required TargetPlatform platform,
  required PointerDeviceKind kind,
  required bool isolated,
}) {
  if (delta == 0 ||
      !delta.isFinite ||
      !isolated ||
      platform != TargetPlatform.macOS ||
      kind != PointerDeviceKind.mouse) {
    return delta;
  }
  final lines = delta.abs() / macOSWheelPixelsPerLine;
  final rows = (lines < 1 ? 1 : lines) * discreteWheelRowsPerLine;
  return delta.sign * rows * rowExtent;
}

/// Tells whether each wheel event starts a stream (see [wheelStreamGap]).
/// Never exported.
final class WheelStream {
  Duration? _last;

  /// Whether the event at [timeStamp] comes after a pause of at least
  /// [wheelStreamGap] (or is the first); records it.
  bool isolated(Duration timeStamp) {
    final last = _last;
    _last = timeStamp;
    return last == null || (timeStamp - last).abs() >= wheelStreamGap;
  }
}
