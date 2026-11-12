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
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

import 'src/blank_frames.dart';
import 'src/firehose.dart';
import 'src/frame_streams.dart';
import 'src/proc_stats.dart';
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
    'window px': windowSize(),
    'refresh Hz': PlatformDispatcher.instance.views.first.display.refreshRate,
    'display': displayBackend(),
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
  final blank = BlankClock(
    pacing ?? VtFloodPacing.smooth,
    view.display.refreshRate,
  );
  host.value = switch (config) {
    'view' => subject.build(_style, dpr),
    'blank' => BlankFrames(blank, ghosttyGridSize(_style, dpr)),
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
  final threads0 = threadCpu();
  final cpu0 = processCpu();
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
  final cpu = processCpu() - cpu0;
  final threads = threadCpu();
  final rssEnd = ProcessInfo.currentRss;
  // Timings arrive in batches; give the last one time to come in.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  SchedulerBinding.instance.removeTimingsCallback(onTimings);

  host.value = const SizedBox.shrink(key: ValueKey('none'));
  await SchedulerBinding.instance.endOfFrame;
  subject.dispose();
  blank.dispose();
  final uiThread = mainThreadName();

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
    vsyncPeriod: vsyncPeriod(view.display.refreshRate),
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
    'thread cpu ms': threadCpuDelta(threads0, threads),
  };
}

double _round(num value) => (value * 100).round() / 100;

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
