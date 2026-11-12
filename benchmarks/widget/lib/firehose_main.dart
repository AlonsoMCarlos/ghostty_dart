/// Firehose benchmark: a program floods the terminal (`tree -C` over a huge
/// directory) while the view is on screen.
///
/// Unlike the frame benchmark (`integration_test/frame_bench_test.dart`),
/// which writes a fixed amount per frame, this feeds the bytes the way a
/// pty does: [firehoseChunkBytes] chunks posted to the UI isolate from
/// another thread, with a 256 KiB flow-control window (flutter_pty2
/// 3.0.0's defaults), at a fixed rate, while frames come from vsync. It is
/// a plain app (no test binding, which schedules frames of its own), run
/// as a profile build by `mise run bench:firehose`.
///
/// The figure of merit is the process CPU time per MB of input, all
/// threads (UI, raster, GPU driver, IO, GC), next to wall time, frames
/// drawn and memory. Each run prints one `FIREHOSE {json}` line; the
/// process exits when done.
///
/// Three configurations run in turn: `no view` (the controller alone),
/// `blank` (the controller, plus a widget of the view's size that only
/// fills a rectangle, repainted at the view's flood cadence: what any
/// Flutter frame costs on this machine, the embedder's present included)
/// and `view`. On Linux the UI isolate runs on the platform thread, which
/// also presents each frame through GTK, so `ui ms/frame` of `blank` is
/// the floor no terminal widget can go under, and `view` minus `blank` is
/// the terminal's own cost per frame.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

import 'src/firehose.dart';
import 'src/frame_streams.dart';
import 'src/report.dart' show frameGapRegularity;
import 'src/subjects.dart';

/// MB (10^6 bytes) of `tree -C` output per run.
const _megabytes = int.fromEnvironment('FIREHOSE_MB', defaultValue: 40);

/// The program's output rate in kB/s; 0 means as fast as the terminal
/// takes it. The default, 7 MB/s, is about what `tree -C` produced over
/// 570,000 files on the maintainer's machine (2026-11-12): the program,
/// not the terminal, sets the pace, so the cost that matters is CPU time
/// per MB.
const _rate = int.fromEnvironment('FIREHOSE_RATE', defaultValue: 7000);

/// Draw the tree with ASCII (`|--`) instead of box drawing (`├──`), to
/// compare the cost of box-drawing glyphs.
const _ascii = bool.fromEnvironment('FIREHOSE_ASCII');

/// Runs per configuration.
const _runs = int.fromEnvironment('FIREHOSE_RUNS', defaultValue: 3);

/// Directory with the JetBrains Mono TTFs (the mise task points it at
/// ghostty_dart_flutter's pinned test fonts).
const _fontDir = String.fromEnvironment('BENCH_FONT_DIR');
const _fontFamily = 'JetBrains Mono';
const _style = TextStyle(fontFamily: _fontFamily, fontSize: 12);

/// flutter_pty2 3.0.0's `PtySpawnOptions.outputWindowBytes`.
const _windowBytes = 256 * 1024;

/// The configurations to run, comma-separated, in order: `no view`,
/// `blank`, `view`.
const _configs = String.fromEnvironment(
  'FIREHOSE_CONFIGS',
  defaultValue: 'no view,blank,view',
);

/// The flood pacing policies (`VtFloodPacing` names) the `blank` and
/// `view` configurations run with, comma-separated, in order.
const _pacings = String.fromEnvironment(
  'FIREHOSE_PACING',
  defaultValue: 'smooth,balanced',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_fontDir.isNotEmpty) {
    final loader = FontLoader(_fontFamily);
    for (final face in const ['Regular', 'Bold', 'Italic', 'BoldItalic']) {
      final bytes = File('$_fontDir/JetBrainsMono-$face.ttf').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
  final host = ValueNotifier<Widget>(const SizedBox.shrink());
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Align(
        alignment: Alignment.topLeft,
        child: ValueListenableBuilder(
          valueListenable: host,
          builder: (context, child, _) => child,
        ),
      ),
    ),
  );
  await SchedulerBinding.instance.endOfFrame;

  final data = treeStream(_megabytes, ascii: _ascii);
  final environment = {
    'MB': data.length / 1e6,
    'ascii': _ascii,
    'rate kB/s': _rate,
    'chunk': firehoseChunkBytes,
    'window': _windowBytes,
    'grid': '$benchCols x $benchRows',
    'dpr': PlatformDispatcher.instance.views.first.devicePixelRatio,
    'window px': _windowSize(),
    'refresh Hz': PlatformDispatcher.instance.views.first.display.refreshRate,
    'display': _display(),
    'Dart': Platform.version.split(' ').first,
    'OS': Platform.operatingSystemVersion,
  };
  stdout.writeln('FIREHOSE_ENV ${jsonEncode(environment)}');
  final configs = [
    for (final name in _configs.split(','))
      if (name.trim().isNotEmpty) name.trim(),
  ];
  for (final config in configs) {
    if (!const {'no view', 'blank', 'view'}.contains(config)) {
      stderr.writeln('unknown FIREHOSE_CONFIGS entry: $config');
      exit(2);
    }
  }
  final pacings = <VtFloodPacing>[];
  for (final name in _pacings.split(',')) {
    if (name.trim().isEmpty) continue;
    final pacing = VtFloodPacing.values.asNameMap()[name.trim()];
    if (pacing == null) {
      stderr.writeln('unknown FIREHOSE_PACING entry: $name');
      exit(2);
    }
    pacings.add(pacing);
  }
  if (pacings.isEmpty) pacings.add(VtFloodPacing.smooth);
  for (var run = 1; run <= _runs; run++) {
    int? noViewUiMs;
    for (final config in configs) {
      for (final pacing in config == 'no view' ? [null] : pacings) {
        final result = await _run(host, data, config: config, pacing: pacing);
        final uiMs = result['ui thread ms']! as int;
        final frames = result['frames']! as int;
        if (config == 'no view') noViewUiMs = uiMs;
        stdout.writeln(
          'FIREHOSE ${jsonEncode({'run': run, ...result, if (config != 'no view' && noViewUiMs != null && frames > 0) 'ui ms/frame over no view': _round((uiMs - noViewUiMs) / frames)})}',
        );
      }
    }
  }
  exit(0);
}

Future<Map<String, Object>> _run(
  ValueNotifier<Widget> host,
  Uint8List data, {
  required String config,
  required VtFloodPacing? pacing,
}) async {
  final subject = GhosttySubject(floodPacing: pacing ?? VtFloodPacing.smooth);
  final view = PlatformDispatcher.instance.views.first;
  final dpr = view.devicePixelRatio;
  final blank = _BlankClock(
    pacing ?? VtFloodPacing.smooth,
    view.display.refreshRate,
  );
  host.value = switch (config) {
    'view' => subject.build(_style, dpr),
    'blank' => _BlankFrames(blank, ghosttyGridSize(_style, dpr)),
    _ => const SizedBox.shrink(key: ValueKey('none')),
  };
  void write(Uint8List bytes) {
    subject.write(bytes);
    if (config == 'blank') blank.changed();
  }

  subject.write(setupBytes());
  await Future<void>.delayed(const Duration(milliseconds: 300));

  final timings = <FrameTiming>[];
  void onTimings(List<FrameTiming> list) => timings.addAll(list);
  SchedulerBinding.instance.addTimingsCallback(onTimings);
  final threads0 = _threadCpu();
  final cpu0 = _processCpu();
  final rss0 = ProcessInfo.currentRss;
  var peakRss = rss0;
  final rssTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
    final rss = ProcessInfo.currentRss;
    if (rss > peakRss) peakRss = rss;
  });
  final clock = Stopwatch()..start();
  final chunks = await _feed(data, write);
  // Let the last frame land.
  await Future<void>.delayed(const Duration(milliseconds: 100));
  clock.stop();
  rssTimer.cancel();
  final cpu = _processCpu() - cpu0;
  final threads = _threadCpu();
  final rssEnd = ProcessInfo.currentRss;
  // Timings arrive in batches; give the last one time to come in.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  SchedulerBinding.instance.removeTimingsCallback(onTimings);

  host.value = const SizedBox.shrink(key: ValueKey('none'));
  await SchedulerBinding.instance.endOfFrame;
  subject.dispose();
  blank.dispose();
  final uiThread = _mainThreadName();

  var build = 0;
  var raster = 0;
  for (final t in timings) {
    build += t.buildDuration.inMicroseconds;
    raster += t.rasterDuration.inMicroseconds;
  }
  List<int> gapsOf(FramePhase phase) => [
    for (var i = 1; i < timings.length; i++)
      timings[i].timestampInMicroseconds(phase) -
          timings[i - 1].timestampInMicroseconds(phase),
  ]..sort();
  final gaps = gapsOf(FramePhase.buildStart);
  final presents = gapsOf(FramePhase.rasterFinish);
  double quantileMs(List<int> sorted, double q) =>
      sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * q).round()] / 1000;
  double gapMs(double q) => quantileMs(gaps, q);
  final regularity = frameGapRegularity(
    gaps,
    vsyncPeriod: _vsyncPeriod(view.display.refreshRate),
  );
  final megabytes = data.length / 1e6;
  final seconds = clock.elapsedMicroseconds / 1e6;
  return {
    'config': config,
    'chunks': chunks,
    'wall s': _round(seconds),
    'cpu s': _round(cpu / 1e6),
    'cpu %': _round(100 * cpu / clock.elapsedMicroseconds),
    'cpu ms/MB': _round(cpu / 1000 / megabytes),
    'frames': timings.length,
    'build ms/frame': _round(
      timings.isEmpty ? 0 : build / 1000 / timings.length,
    ),
    'raster ms/frame': _round(
      timings.isEmpty ? 0 : raster / 1000 / timings.length,
    ),
    'frame gap ms p10/p50/p90': [
      _round(gapMs(0.1)),
      _round(gapMs(0.5)),
      _round(gapMs(0.9)),
    ],
    'pacing': ?pacing?.name,
    'frame gap jitter ms': _round(regularity.jitterMs),
    'frame gap irregular %': _round(regularity.irregularPercent),
    'present gap ms p10/p50/p90': [
      _round(quantileMs(presents, 0.1)),
      _round(quantileMs(presents, 0.5)),
      _round(quantileMs(presents, 0.9)),
    ],
    'rss start MiB': rss0 >> 20,
    'rss peak MiB': peakRss >> 20,
    'rss end MiB': rssEnd >> 20,
    'ui thread ms':
        ((threads[uiThread] ?? 0) - (threads0[uiThread] ?? 0)) ~/ 1000,
    'thread cpu ms': {
      for (final MapEntry(:key, :value) in threads.entries)
        if (value - (threads0[key] ?? 0) >= 10000)
          key: (value - (threads0[key] ?? 0)) ~/ 1000,
    },
  };
}

double _round(num value) => (value * 100).round() / 100;

/// The window's size in physical pixels: what the embedder presents each
/// frame.
String _windowSize() {
  final size = PlatformDispatcher.instance.views.first.physicalSize;
  return '${size.width.round()} x ${size.height.round()}';
}

/// The windowing system GTK uses: `wayland` or `x11` (`GDK_BACKEND` when
/// set, else the session's). On X11 Flutter's Linux embedder copies every
/// frame through the CPU (`fl_view_renderer.cc`: frames are shareable
/// only on Wayland).
String _display() {
  final env = Platform.environment;
  final backend = env['GDK_BACKEND'];
  if (backend != null && backend.isNotEmpty) return backend;
  if ((env['WAYLAND_DISPLAY'] ?? '').isNotEmpty) return 'wayland';
  if ((env['DISPLAY'] ?? '').isNotEmpty) return 'x11';
  return env['XDG_SESSION_TYPE'] ?? 'unknown';
}

/// The name `_threadCpu` gives the main thread (the process's own, which
/// runs the UI isolate and GTK), or `''` off Linux.
String _mainThreadName() {
  final file = File('/proc/self/comm');
  if (!file.existsSync()) return '';
  return file.readAsStringSync().trim().replaceAll(RegExp('[0-9]+'), '#');
}

/// The time between two vsyncs at [refreshRate] Hz, 60 Hz when unknown:
/// as the view's seams count it (`ControllerSeams.vsyncPeriod`, internal
/// to ghostty_dart_flutter).
Duration _vsyncPeriod(double refreshRate) {
  final hz = refreshRate.isFinite && refreshRate >= 24
      ? math.min(refreshRate, 1000.0)
      : 60.0;
  return Duration(microseconds: (1e6 / hz).round());
}

/// Drives the `blank` configuration: [changed] after each write asks for
/// a repaint at the start of the frame a whole number of vsyncs after the
/// last paint, the view's flood pacing (`ControllerSeams`, ADR 0011,
/// amendment of 2026-11-12: a timer wakes up in the vsync period before
/// the due vsync and schedules a frame callback).
final class _BlankClock {
  _BlankClock(VtFloodPacing pacing, double refreshRate)
    : _period = _vsyncPeriod(refreshRate),
      _vsyncs = math.max(
        1,
        (1e6 /
                _vsyncPeriod(refreshRate).inMicroseconds /
                pacing.maxFramesPerSecond)
            .round(),
      );

  final repaints = ValueNotifier(0);
  final Duration _period;
  final int _vsyncs;
  Duration? _lastFrame;
  Timer? _timer;
  int? _frame;

  static Duration _now() => Duration(microseconds: Timeline.now);

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

  void dispose() {
    painted();
    repaints.dispose();
  }
}

/// A widget of the view's size that fills a rectangle in a new colour
/// each time [clock] asks for a repaint: a frame with no terminal in it.
final class _BlankFrames extends LeafRenderObjectWidget {
  const _BlankFrames(this.clock, this.size);

  final _BlankClock clock;
  final Size size;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBlank(clock, size);
}

final class _RenderBlank extends RenderBox {
  _RenderBlank(this._clock, this._size);

  final _BlankClock _clock;
  final Size _size;
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
  void performLayout() => size = constraints.constrain(_size);

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

/// CPU time (user + system) of every live thread of this process, by
/// thread name with digits replaced by `#`, in microseconds. Empty off
/// Linux.
Map<String, int> _threadCpu() {
  final result = <String, int>{};
  final tasks = Directory('/proc/self/task');
  if (!tasks.existsSync()) return result;
  for (final task in tasks.listSync()) {
    try {
      final stat = File('${task.path}/stat').readAsStringSync();
      final close = stat.lastIndexOf(')');
      final name = stat
          .substring(stat.indexOf('(') + 1, close)
          .replaceAll(RegExp('[0-9]+'), '#');
      final fields = stat.substring(close + 2).split(' ');
      // utime and stime (fields 14 and 15 of proc_pid_stat(5)), in clock
      // ticks of 1/100 s.
      final ticks = int.parse(fields[11]) + int.parse(fields[12]);
      result[name] = (result[name] ?? 0) + ticks * 10000;
    } on FileSystemException {
      // The thread exited while listing.
    }
  }
  return result;
}

/// The process's CPU time (user + system, all threads, exited ones
/// included) in microseconds. Linux only.
int _processCpu() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return (int.parse(fields[11]) + int.parse(fields[12])) * 10000;
}

/// Feeds [data] to [write] from a producer isolate, the pty's side;
/// completes with the number of chunks once the last one was written.
Future<int> _feed(Uint8List data, void Function(Uint8List) write) async {
  final port = ReceivePort();
  final done = Completer<int>();
  SendPort? acks;
  var chunks = 0;
  port.listen((message) {
    if (message is SendPort) {
      acks = message;
    } else if (message is Uint8List) {
      write(message);
      chunks++;
      acks!.send(message.length);
    } else if (message == null) {
      done.complete(chunks);
    }
  });
  await Isolate.spawn(_produce, (
    port.sendPort,
    TransferableTypedData.fromList([data]),
    _rate,
  ));
  final result = await done.future;
  port.close();
  return result;
}

/// Posts the data in [firehoseChunkBytes] chunks at the given rate in kB/s
/// (0: unlimited) while fewer than [_windowBytes] are unacknowledged.
Future<void> _produce(
  (SendPort out, TransferableTypedData data, int rate) args,
) async {
  final (out, transferable, rate) = args;
  final data = transferable.materialize().asUint8List();
  final acks = ReceivePort();
  out.send(acks.sendPort);
  var sent = 0;
  var acked = 0;
  final clock = Stopwatch()..start();
  final done = Completer<void>();
  void pump() {
    final allowed = rate == 0
        ? data.length
        : (clock.elapsedMicroseconds * rate / 1000).floor();
    while (sent < data.length &&
        sent < allowed &&
        sent - acked < _windowBytes) {
      final end = (sent + firehoseChunkBytes).clamp(0, data.length);
      // A copy: sending a view copies its whole backing buffer.
      out.send(data.sublist(sent, end));
      sent = end;
    }
    if (sent >= data.length && !done.isCompleted) done.complete();
  }

  acks.listen((message) {
    acked += message as int;
    pump();
  });
  final timer = Timer.periodic(const Duration(milliseconds: 1), (_) => pump());
  await done.future;
  timer.cancel();
  out.send(null);
  acks.close();
}
