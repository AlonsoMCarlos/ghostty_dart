import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../input/pointer/mouse_reports.dart';
import '../input/pointer/pointer_mapping.dart';
import '../seams/terminal_geometry.dart';
import '../seams/terminal_seams.dart';
import 'row_accumulator.dart';
import 'terminal_scroll_router.dart';

// The look and timing follow Flutter's RawScrollbar defaults
// (`packages/flutter/lib/src/widgets/scrollbar.dart`, Flutter 3.47.9:
// `_kMinThumbExtent`, `_kScrollbarThickness`, `_kScrollbarFadeDuration`,
// `_kScrollbarTimeToFade`, thumb colour `Color(0x66BCBCBC)`), so the
// terminal's bar matches the other bars of a Flutter app.

/// The shortest thumb, in logical pixels (RawScrollbar's
/// `_kMinThumbExtent`).
const double kTerminalScrollbarMinThumbExtent = 18;

/// The default width of the scrollbar (RawScrollbar's
/// `_kScrollbarThickness`).
const double kTerminalScrollbarThickness = 6;

/// The default thumb colour (RawScrollbar's default `thumbColor`).
const Color kTerminalScrollbarColor = Color(0x66BCBCBC);

/// How long the scrollbar stays after the last scroll (RawScrollbar's
/// `_kScrollbarTimeToFade`).
const Duration kTerminalScrollbarTimeToFade = Duration(milliseconds: 600);

/// How long the fade takes (RawScrollbar's `_kScrollbarFadeDuration`).
const Duration kTerminalScrollbarFadeDuration = Duration(milliseconds: 300);

/// Where the thumb of a scrollbar sits on a track of [trackExtent] pixels:
/// its top and its extent, or `null` when there is nothing to scroll (no
/// scrollback, as on the alternate screen) or the track is shorter than
/// two minimum thumbs (a thumb could not move). Never exported.
///
/// The thumb is proportional to the visible part of the scrollable area,
/// but never shorter than [minExtent].
({double top, double extent})? scrollbarThumb(
  ViewportScrollbar bar,
  double trackExtent, {
  double minExtent = kTerminalScrollbarMinThumbExtent,
}) {
  final scrollable = bar.total - bar.length;
  if (scrollable <= 0 || !(trackExtent >= 2 * minExtent)) return null;
  final extent = math.max(minExtent, trackExtent * bar.length / bar.total);
  final fraction = (bar.offset / scrollable).clamp(0.0, 1.0);
  return (top: (trackExtent - extent) * fraction, extent: extent);
}

/// The first visible row for a thumb whose top is at [thumbTop] on a track
/// of [trackExtent] pixels (the inverse of [scrollbarThumb]). Never
/// exported.
int scrollbarRowAt(
  ViewportScrollbar bar,
  double trackExtent,
  double thumbTop, {
  double minExtent = kTerminalScrollbarMinThumbExtent,
}) {
  final thumb = scrollbarThumb(bar, trackExtent, minExtent: minExtent);
  if (thumb == null) return bar.offset;
  final fraction = (thumbTop / (trackExtent - thumb.extent)).clamp(0.0, 1.0);
  return (fraction * (bar.total - bar.length)).round();
}

/// A thin overlay scrollbar drawn from the terminal's viewport (ADR 0011).
/// There is no `ScrollPosition`: the viewport lives in libghostty and this
/// widget polls [TerminalViewport.scrollbar] when the viewport notifies.
/// Never exported.
///
/// It appears when the viewport's offset changes (not while output only
/// follows the bottom, nor when output grows under a scrolled-back,
/// anchored viewport), stays while its thumb is dragged, and fades out
/// after [fadeDelay]. Nothing is shown without scrollback. Place it over
/// the view (a `Stack` child); it sits at the right edge.
///
/// **Only the thumb takes the pointer**, and only while shown, so the last
/// column stays clickable and selectable. Dragging the thumb moves the
/// viewport. The wheel and a trackpad pan over the thumb scroll with the
/// same routing as over the terminal ([TerminalScrollRouter]): wheel
/// reports while the program tracks the mouse and alternate-scroll arrows
/// when [pointer] is given, otherwise the scrollback.
class TerminalScrollbar extends StatelessWidget {
  /// A scrollbar for [viewport] beside the grid of [geometry].
  const TerminalScrollbar({
    super.key,
    required this.viewport,
    required this.geometry,
    this.pointer,
    this.keys,
    this.text,
    this.reports = MouseReports.none,
    this.thickness = kTerminalScrollbarThickness,
    this.color = kTerminalScrollbarColor,
    this.fadeDelay = kTerminalScrollbarTimeToFade,
  });

  /// The scrollback position to show and to move.
  final TerminalViewport viewport;

  /// Where the grid is.
  final TerminalGeometry geometry;

  /// Mouse tracking and modes for the wheel over the thumb; without it
  /// the wheel there always scrolls the scrollback.
  final TerminalPointerSink? pointer;

  /// Fallback for alternate-scroll arrows (see [TerminalScrollRouter]).
  final TerminalKeySink? keys;

  /// Where raw alternate-scroll sequences go (see [TerminalScrollRouter]).
  final TerminalTextSink? text;

  /// The view's mouse report filter and hook, for wheel reports (see
  /// [TerminalScrollRouter.reports]).
  final MouseReports reports;

  /// The width of the scrollbar in logical pixels.
  final double thickness;

  /// The colour of the thumb.
  final Color color;

  /// How long the scrollbar stays after the last scroll before it fades.
  final Duration fadeDelay;

  @override
  Widget build(BuildContext context) => _ScrollbarBody(
    router: TerminalScrollRouter(
      viewport: viewport,
      pointer: pointer,
      keys: keys,
      text: text,
      reports: reports,
    ),
    geometry: geometry,
    thickness: thickness,
    color: color,
    fadeDelay: fadeDelay,
  );
}

/// Where the scrollbar's state lives. [TerminalScrollbar] is a
/// `StatelessWidget` only because ADR 0011's frozen view contract fixes
/// its type; keep the state here rather than "simplifying" it away.
class _ScrollbarBody extends StatefulWidget {
  const _ScrollbarBody({
    required this.router,
    required this.geometry,
    required this.thickness,
    required this.color,
    required this.fadeDelay,
  });

  final TerminalScrollRouter router;
  final TerminalGeometry geometry;
  final double thickness;
  final Color color;
  final Duration fadeDelay;

  @override
  State<_ScrollbarBody> createState() => _ScrollbarBodyState();
}

/// The last polled viewport position, visibility, fade timer and thumb
/// drag.
class _ScrollbarBodyState extends State<_ScrollbarBody> {
  late ViewportScrollbar _bar;
  bool _visible = false;
  int? _dragPointer;

  /// Where the thumb's top would be under the dragging pointer (it may
  /// leave the track; [scrollbarRowAt] clamps).
  double _dragTop = 0;
  Timer? _fadeTimer;
  bool _pollScheduled = false;
  final _rows = RowAccumulator();
  final _wheelStream = WheelStream();

  TerminalViewport get _viewport => widget.router.viewport;

  @override
  void initState() {
    super.initState();
    _bar = _viewport.scrollbar;
    _viewport.addListener(_onViewportChanged);
  }

  @override
  void didUpdateWidget(_ScrollbarBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.router.viewport, _viewport)) {
      oldWidget.router.viewport.removeListener(_onViewportChanged);
      _viewport.addListener(_onViewportChanged);
      _bar = _viewport.scrollbar;
    }
  }

  @override
  void dispose() {
    _viewport.removeListener(_onViewportChanged);
    _fadeTimer?.cancel();
    super.dispose();
  }

  void _onViewportChanged() {
    // A notification can arrive while the tree is being built (a write
    // from a build method); poll after that frame instead of rebuilding
    // inside it.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_pollScheduled) return;
      _pollScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _pollScheduled = false;
        if (mounted) _poll();
      });
      return;
    }
    _poll();
  }

  void _poll() {
    final bar = _viewport.scrollbar;
    if (bar == _bar) return;
    final old = _bar;
    // Only a moved viewport shows the bar: output that follows the bottom
    // moves the offset too, and output under an anchored viewport only
    // grows the total.
    final moved =
        bar.offset != old.offset && !(old.isAtBottom && bar.isAtBottom);
    setState(() {
      _bar = bar;
      if (moved) _show();
    });
  }

  /// Shows the scrollbar and (re)starts the fade timer. Call inside
  /// `setState`.
  void _show() {
    _visible = true;
    _fadeTimer?.cancel();
    _fadeTimer = _dragPointer != null
        ? null
        : Timer(widget.fadeDelay, () {
            if (mounted && _dragPointer == null) {
              setState(() => _visible = false);
            }
          });
  }

  void _onThumbDown(PointerDownEvent event, double thumbTop) {
    if (_dragPointer != null || event.buttons & kPrimaryButton == 0) return;
    _dragTop = thumbTop;
    setState(() {
      _dragPointer = event.pointer;
      _show();
    });
  }

  void _onThumbMove(PointerMoveEvent event, double trackExtent) {
    if (event.pointer != _dragPointer || _viewport.isDisposed) return;
    // The thumb moves under the pointer, so follow the pointer's deltas
    // rather than its position on the (moving) thumb.
    _dragTop += event.localDelta.dy;
    _viewport.scrollViewport(
      ViewportScroll.row(scrollbarRowAt(_bar, trackExtent, _dragTop)),
    );
  }

  void _onThumbEnd(PointerEvent event) {
    if (event.pointer != _dragPointer) return;
    setState(() {
      _dragPointer = null;
      _show();
    });
  }

  void _scroll(double dy, Offset local) {
    final rows = _rows.add(dy, widget.geometry.metrics.height);
    widget.router.scroll(
      rows,
      surface: widget.geometry.toSurface(local),
      modifiers: currentKeyModifiers(),
      cell: widget.geometry.viewportCellAt(local),
    );
  }

  void _onSignal(PointerSignalEvent event, Offset origin) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (_viewport.isDisposed) return;
      final scroll = resolved as PointerScrollEvent;
      _scroll(
        wheelScrollExtent(
          scroll.scrollDelta.dy,
          widget.geometry.metrics.height,
          platform: defaultTargetPlatform,
          kind: scroll.kind,
          isolated: _wheelStream.isolated(scroll.timeStamp),
        ),
        origin + scroll.localPosition,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: widget.thickness,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final track = constraints.maxHeight;
            final thumb = scrollbarThumb(_bar, track);
            if (thumb == null) return const SizedBox.shrink();
            final origin = Offset(
              widget.geometry.viewSize.width - widget.thickness,
              thumb.top,
            );
            return IgnorePointer(
              ignoring: !_visible,
              child: AnimatedOpacity(
                opacity: _visible ? 1 : 0,
                duration: kTerminalScrollbarFadeDuration,
                // Only the thumb is hit-testable: a Stack whose one child
                // is positioned on the thumb.
                child: Stack(
                  children: [
                    Positioned(
                      top: thumb.top,
                      height: thumb.extent,
                      left: 0,
                      right: 0,
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (e) => _onThumbDown(e, thumb.top),
                        onPointerMove: (e) => _onThumbMove(e, track),
                        onPointerUp: _onThumbEnd,
                        onPointerCancel: _onThumbEnd,
                        onPointerSignal: (e) => _onSignal(e, origin),
                        onPointerPanZoomStart: (_) => _rows.reset(),
                        onPointerPanZoomUpdate: (e) => _scroll(
                          -e.localPanDelta.dy,
                          origin + e.localPosition,
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: widget.color,
                            borderRadius: BorderRadius.circular(
                              widget.thickness / 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
