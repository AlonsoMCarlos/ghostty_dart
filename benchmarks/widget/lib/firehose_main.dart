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
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'src/firehose.dart';
import 'src/frame_streams.dart';
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
    'Dart': Platform.version.split(' ').first,
    'OS': Platform.operatingSystemVersion,
  };
  stdout.writeln('FIREHOSE_ENV ${jsonEncode(environment)}');
  for (var run = 1; run <= _runs; run++) {
    for (final withView in [false, true]) {
      final result = await _run(host, data, withView: withView);
      stdout.writeln('FIREHOSE ${jsonEncode({'run': run, ...result})}');
    }
  }
  exit(0);
}

Future<Map<String, Object>> _run(
  ValueNotifier<Widget> host,
  Uint8List data, {
  required bool withView,
}) async {
  final subject = GhosttySubject();
  final dpr = PlatformDispatcher.instance.views.first.devicePixelRatio;
  host.value = withView
      ? subject.build(_style, dpr)
      : const SizedBox.shrink(key: ValueKey('none'));
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
  final chunks = await _feed(data, subject.write);
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

  var build = 0;
  var raster = 0;
  for (final t in timings) {
    build += t.buildDuration.inMicroseconds;
    raster += t.rasterDuration.inMicroseconds;
  }
  final gaps = [
    for (var i = 1; i < timings.length; i++)
      timings[i].timestampInMicroseconds(FramePhase.buildStart) -
          timings[i - 1].timestampInMicroseconds(FramePhase.buildStart),
  ]..sort();
  double gapMs(double q) =>
      gaps.isEmpty ? 0 : gaps[((gaps.length - 1) * q).round()] / 1000;
  final megabytes = data.length / 1e6;
  final seconds = clock.elapsedMicroseconds / 1e6;
  return {
    'config': withView ? 'view' : 'no view',
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
    'rss start MiB': rss0 >> 20,
    'rss peak MiB': peakRss >> 20,
    'rss end MiB': rssEnd >> 20,
    'thread cpu ms': {
      for (final MapEntry(:key, :value) in threads.entries)
        if (value - (threads0[key] ?? 0) >= 10000)
          key: (value - (threads0[key] ?? 0)) ~/ 1000,
    },
  };
}

double _round(num value) => (value * 100).round() / 100;

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
