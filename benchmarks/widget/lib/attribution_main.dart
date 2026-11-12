/// Attribution benchmark: where the CPU time of an output flood goes.
///
/// A real pty child (`tool/paced_cat.dart`, or `cat` at rate 0) writes a
/// `tree`-like fixture through flutter_pty2, the way `tree ~` floods a
/// terminal app built on this package (vtterm), and the same stream runs
/// through four cumulative layers:
///
/// * `pty`: flutter_pty2 reads and acknowledges the output, which is
///   discarded;
/// * `parser`: plus `VtTerminalController.writeBytes` (libghostty-vt's
///   parser and the controller), no view;
/// * `blank`: plus a full-window Flutter frame that only fills a
///   rectangle, repainted at the view's flood cadence (each pacing);
/// * `view`: the controller with a full-window `VtTerminalView` instead.
///
/// Each run prints one `ATTRIBUTION {json}` line with process CPU per MB
/// and per thread; once every run is done, a markdown table of medians
/// and the increments of each layer (pty, parser + controller, Flutter's
/// frame, the widget). Runtime settings come from the environment, so the
/// mise task (`bench:attribution`) can run one build under several
/// renderers, scales and window sizes:
///
/// * `ATTRIBUTION_FIXTURE`: the fixture file (LF line ends; the pty's
///   `onlcr` turns them into CRLF);
/// * `ATTRIBUTION_DART`, `ATTRIBUTION_PACER`: the Dart executable and
///   `tool/paced_cat.dart`;
/// * `ATTRIBUTION_RATE` (kB/s, 0: `cat`), `ATTRIBUTION_RUNS`,
///   `ATTRIBUTION_LAYERS`, `ATTRIBUTION_PACING`, `ATTRIBUTION_FONT_SIZE`;
/// * `ATTRIBUTION_VARIANT`: a label for the table (renderer, scale, pty
///   package).
///
/// Linux only: it reads `/proc`. Run by `mise run bench:attribution`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

import 'src/attribution.dart';
import 'src/blank_frames.dart';
import 'src/proc_stats.dart';

final _env = Platform.environment;
String _setting(String name, String fallback) {
  final value = _env['ATTRIBUTION_$name'];
  return value == null || value.isEmpty ? fallback : value;
}

/// Directory with the JetBrains Mono TTFs (the mise task points it at
/// ghostty_dart_flutter's pinned test fonts).
const _fontDir = String.fromEnvironment('BENCH_FONT_DIR');
const _fontFamily = 'JetBrains Mono';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final fixture = File(_setting('FIXTURE', ''));
  if (!fixture.existsSync()) {
    stderr.writeln('ATTRIBUTION_FIXTURE is not a file: ${fixture.path}');
    exit(2);
  }
  final rate = int.parse(_setting('RATE', '7000'));
  final runs = int.parse(_setting('RUNS', '3'));
  final style = TextStyle(
    fontFamily: _fontFamily,
    // vtterm's default size.
    fontSize: double.parse(_setting('FONT_SIZE', '14')),
  );
  final layers = [
    for (final name in _setting('LAYERS', 'pty,parser,blank,view').split(','))
      if (name.trim().isNotEmpty) Layer.values.byName(name.trim()),
  ];
  final pacings = [
    for (final name in _setting('PACING', 'smooth,balanced').split(','))
      if (name.trim().isNotEmpty) VtFloodPacing.values.byName(name.trim()),
  ];
  final List<String> command;
  if (rate == 0) {
    command = ['cat', fixture.path];
  } else {
    command = [
      _setting('DART', 'dart'),
      _setting('PACER', 'tool/paced_cat.dart'),
      fixture.path,
      '$rate',
    ];
  }

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
      home: ValueListenableBuilder(
        valueListenable: host,
        builder: (context, child, _) => child,
      ),
    ),
  );
  await SchedulerBinding.instance.endOfFrame;
  final grid = await _measureGrid(host, style);

  final view = PlatformDispatcher.instance.views.first;
  // After the pty's onlcr: one more byte per line.
  final source = fixture.readAsBytesSync();
  final bytes = source.length + source.where((b) => b == 0x0A).length;
  final environment = {
    'variant': _setting('VARIANT', ''),
    'MB': bytes / 1e6,
    'rate kB/s': rate,
    'child': command.first == 'cat' ? 'cat' : 'paced_cat.dart',
    'grid': '${grid.cols} x ${grid.rows}',
    'font px': style.fontSize,
    'dpr': view.devicePixelRatio,
    'window px': windowSize(),
    'refresh Hz': view.display.refreshRate,
    'display': displayBackend(),
    'engine switches': engineSwitches(_env),
    'Dart': Platform.version.split(' ').first,
    'OS': Platform.operatingSystemVersion,
    'cpus': Platform.numberOfProcessors,
  };
  stdout.writeln('ATTRIBUTION_ENV ${jsonEncode(environment)}');

  final results = <Map<String, Object?>>[];
  for (var run = 1; run <= runs; run++) {
    for (final layer in layers) {
      for (final pacing in layer.paints ? pacings : [null]) {
        final result = await _run(
          host,
          command,
          grid,
          style,
          layer: layer,
          pacing: pacing,
        );
        final megabytes = (result['bytes']! as int) / 1e6;
        if ((result['bytes']! as int) != bytes) {
          stderr.writeln(
            'error: received ${result['bytes']} bytes, expected $bytes '
            '(${command.join(' ')})',
          );
          exit(1);
        }
        final line = {'run': run, ...result, 'MB': megabytes};
        results.add(line);
        stdout.writeln('ATTRIBUTION ${jsonEncode(line)}');
      }
    }
  }
  for (final line in attributionTable(
    results,
    mainThread: mainThreadName(),
    title: [
      _setting('VARIANT', 'attribution'),
      'window ${windowSize()} px, dpr ${view.devicePixelRatio}, '
          'grid ${grid.cols}x${grid.rows}, ${environment['display']}, '
          '${(bytes / 1e6).toStringAsFixed(1)} MB at '
          '${rate == 0 ? 'cat speed' : '$rate kB/s'}, $runs runs',
    ].join(' | '),
  )) {
    stdout.writeln('ATTRIBUTION_TABLE $line');
  }
  exit(0);
}

/// The grid a full-window view gets: lay one out and read its size, so
/// the layers without a view parse into the same grid.
Future<({int cols, int rows})> _measureGrid(
  ValueNotifier<Widget> host,
  TextStyle style,
) async {
  final controller = VtTerminalController();
  host.value = VtTerminalView(controller: controller, textStyle: style);
  await SchedulerBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final grid = (cols: controller.cols, rows: controller.rows);
  host.value = const SizedBox.shrink(key: ValueKey('none'));
  await SchedulerBinding.instance.endOfFrame;
  controller.dispose();
  return grid;
}

Future<Map<String, Object?>> _run(
  ValueNotifier<Widget> host,
  List<String> command,
  ({int cols, int rows}) grid,
  TextStyle style, {
  required Layer layer,
  required VtFloodPacing? pacing,
}) async {
  final view = PlatformDispatcher.instance.views.first;
  final controller = layer == Layer.pty
      ? null
      : VtTerminalController(cols: grid.cols, rows: grid.rows);
  final blank = layer == Layer.blank
      ? BlankClock(pacing!, view.display.refreshRate)
      : null;
  host.value = switch (layer) {
    Layer.view => VtTerminalView(
      controller: controller!,
      textStyle: style,
      floodPacing: pacing!,
    ),
    Layer.blank => BlankFrames(blank!),
    _ => const SizedBox.shrink(key: ValueKey('none')),
  };
  await SchedulerBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(milliseconds: 300));

  var frames = 0;
  void onTimings(List<FrameTiming> list) => frames += list.length;
  SchedulerBinding.instance.addTimingsCallback(onTimings);
  final threads0 = threadCpu();
  final cpu0 = processCpu();
  final clock = Stopwatch()..start();
  final session = await Pty.spawn(
    PtySpawnOptions(
      executable: command.first,
      arguments: command.sublist(1),
      size: PtySize(columns: grid.cols, rows: grid.rows),
    ),
  );
  var received = 0;
  var messages = 0;
  int? firstByteUs;
  final subscription = session.output.listen((bytes) {
    firstByteUs ??= clock.elapsedMicroseconds;
    received += bytes.length;
    messages++;
    if (controller != null) controller.writeBytes(bytes);
    blank?.changed();
  });
  await session.done;
  // Let the last frame land.
  await Future<void>.delayed(const Duration(milliseconds: 100));
  clock.stop();
  final cpu = processCpu() - cpu0;
  final threads = threadCpu();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  SchedulerBinding.instance.removeTimingsCallback(onTimings);
  await subscription.cancel();
  await session.close();

  host.value = const SizedBox.shrink(key: ValueKey('none'));
  await SchedulerBinding.instance.endOfFrame;
  controller?.dispose();
  blank?.dispose();

  final seconds = clock.elapsedMicroseconds / 1e6;
  return {
    'layer': layer.name,
    'pacing': pacing?.name,
    'bytes': received,
    'messages': messages,
    'wall s': round2(seconds),
    'first byte s': round2((firstByteUs ?? 0) / 1e6),
    'cpu ms': cpu ~/ 1000,
    'frames': frames,
    'thread cpu ms': threadCpuDelta(threads0, threads),
  };
}
