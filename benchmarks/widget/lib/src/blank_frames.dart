/// A frame with no terminal in it, repainted at the view's flood cadence:
/// what any Flutter frame costs on a machine, the embedder's present
/// included. Shared by the firehose and attribution benchmarks.
library;

import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

/// The time between two vsyncs at [refreshRate] Hz, 60 Hz when unknown:
/// as the view's seams count it (`ControllerSeams.vsyncPeriod`, internal
/// to ghostty_dart_flutter).
Duration vsyncPeriod(double refreshRate) {
  final hz = refreshRate.isFinite && refreshRate >= 24
      ? math.min(refreshRate, 1000.0)
      : 60.0;
  return Duration(microseconds: (1e6 / hz).round());
}

/// Drives [BlankFrames]: [changed] after each write asks for a repaint at
/// the start of the frame a whole number of vsyncs after the last paint,
/// the view's flood pacing (`ControllerSeams`, ADR 0011, amendment of
/// 2026-11-12: a timer wakes up in the vsync period before the due vsync
/// and schedules a frame callback).
final class BlankClock {
  /// A clock pacing repaints like [pacing] on a [refreshRate] Hz display.
  BlankClock(VtFloodPacing pacing, double refreshRate)
    : _period = vsyncPeriod(refreshRate),
      _vsyncs = math.max(
        1,
        (1e6 /
                vsyncPeriod(refreshRate).inMicroseconds /
                pacing.maxFramesPerSecond)
            .round(),
      );

  /// Bumped when a repaint is due.
  final repaints = ValueNotifier(0);
  final Duration _period;
  final int _vsyncs;
  Duration? _lastFrame;
  Timer? _timer;
  int? _frame;

  static Duration _now() => Duration(microseconds: Timeline.now);

  /// The terminal's content changed: repaint at the next due vsync.
  void changed() {
    if (_timer != null || _frame != null) return;
    final last = _lastFrame;
    final margin = _period ~/ 8 > const Duration(milliseconds: 1)
        ? _period ~/ 8
        : const Duration(milliseconds: 1);
    final wait = last == null
        ? Duration.zero
        : last + _period * (_vsyncs - 1) + margin - _now();
    if (wait <= Duration.zero) {
      _request();
    } else {
      _timer = Timer(
        Duration(milliseconds: (wait.inMicroseconds + 999) ~/ 1000),
        () {
          _timer = null;
          _request();
        },
      );
    }
  }

  void _request() {
    _frame = SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frame = null;
      _lastFrame = _frameTime();
      repaints.value++;
    });
  }

  Duration _frameTime() {
    final now = _now();
    final age = now - SchedulerBinding.instance.currentSystemFrameTimeStamp;
    return age.isNegative || age > const Duration(seconds: 1) ? now : now - age;
  }

  /// The blank widget painted a frame.
  void painted() {
    _timer?.cancel();
    _timer = null;
    final frame = _frame;
    if (frame != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frame);
      _frame = null;
    }
    _lastFrame = _frameTime();
  }

  /// Stops the clock.
  void dispose() {
    painted();
    repaints.dispose();
  }
}

/// A widget of [size] (or as large as allowed when null) that fills a
/// rectangle in a new colour each time [clock] asks for a repaint: a frame
/// with no terminal in it.
final class BlankFrames extends LeafRenderObjectWidget {
  /// A blank frame driven by [clock].
  const BlankFrames(this.clock, [this.size]);

  /// When to repaint.
  final BlankClock clock;

  /// The widget's size; null fills the constraints.
  final Size? size;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBlank(clock, size);
}

final class _RenderBlank extends RenderBox {
  _RenderBlank(this._clock, this._size);

  final BlankClock _clock;
  final Size? _size;
  int _frame = 0;

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _clock.repaints.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _clock.repaints.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void performLayout() {
    final wanted = _size;
    size = wanted == null ? constraints.biggest : constraints.constrain(wanted);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _clock.painted();
    final shade = 0x20 + (_frame++ & 0x1F);
    context.canvas.drawRect(
      offset & size,
      Paint()..color = Color.fromARGB(0xFF, shade, shade, shade),
    );
  }
}
