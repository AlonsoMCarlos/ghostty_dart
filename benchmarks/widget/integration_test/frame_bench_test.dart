// Frame-time benchmark of the three terminal widgets (ADR 0011 targets).
//
// Run it with `mise run bench:widget` (flutter drive --profile on a real
// display; benchmarks/README.md). Every scenario × widget pair runs in
// several passes, the widget order rotating per pass; each run is traced
// with `traceAction`, and test_driver/perf_driver.dart summarises the
// timelines into build/widget_bench.md.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_widget_benchmarks/src/frame_streams.dart';
import 'package:ghostty_dart_widget_benchmarks/src/report.dart';
import 'package:ghostty_dart_widget_benchmarks/src/subjects.dart';
import 'package:integration_test/integration_test.dart';

/// Frames measured per run (`--dart-define=BENCH_FRAMES=n`).
const _frames = int.fromEnvironment('BENCH_FRAMES', defaultValue: 300);

/// Passes over every pair (`--dart-define=BENCH_PASSES=n`).
const _passes = int.fromEnvironment('BENCH_PASSES', defaultValue: 3);

/// The renderer the mise task asked for (`impeller` or `skia`); the driver
/// checks it against the timeline.
const _renderer = String.fromEnvironment('BENCH_RENDERER');

/// Untraced frames before each run, from the same stream as the measured
/// frames: four cycles of the full-screen scenario, so every measured
/// screen has been drawn before.
const _warmUpFrames = fullScreenCycle * 4;

/// Directory with the JetBrains Mono TTFs (`--dart-define=BENCH_FONT_DIR`;
/// the mise task points it at ghostty_dart_flutter's pinned test fonts).
const _fontDir = String.fromEnvironment('BENCH_FONT_DIR');

const _fontFamily = 'JetBrains Mono';
const _fontSize = 12.0;
const _style = TextStyle(fontFamily: _fontFamily, fontSize: _fontSize);

Future<void> _loadFont() async {
  if (_fontDir.isEmpty) {
    fail('BENCH_FONT_DIR is not set: run `mise run bench:widget`.');
  }
  final loader = FontLoader(_fontFamily);
  for (final face in const ['Regular', 'Bold', 'Italic', 'BoldItalic']) {
    final file = File('$_fontDir/JetBrainsMono-$face.ttf');
    if (!file.existsSync()) fail('missing font file ${file.path}');
    final bytes = file.readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

/// Requests a frame even when nothing changed, and waits until it is done.
Future<void> _nextFrame() {
  SchedulerBinding.instance.scheduleForcedFrame();
  return SchedulerBinding.instance.endOfFrame;
}

/// [items] rotated left by [by].
List<T> _rotate<T>(List<T> items, int by) => [
  for (var i = 0; i < items.length; i++) items[(i + by) % items.length],
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Frames come from the engine's vsync, as in an app; pump() adds none.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;

  final runs = <String, Map<String, Object>>{};
  final environment = <String, String>{};
  var devicePixelRatio = 0.0;

  setUpAll(_loadFont);

  tearDownAll(() {
    binding.reportData ??= <String, dynamic>{};
    binding.reportData!['bench_meta'] = {
      'runs': runs,
      'environment': environment,
      'devicePixelRatio': devicePixelRatio,
      'renderer': _renderer,
    };
  });

  final subjects = [
    for (final create in allSubjects) (create: create, name: _nameOf(create)),
  ];
  for (var pass = 1; pass <= _passes; pass++) {
    for (final scenario in Scenario.values) {
      for (final (:create, :name) in _rotate(subjects, pass - 1)) {
        testWidgets('pass $pass · ${scenario.label} · $name', (tester) async {
          final subject = create();
          addTearDown(subject.dispose);
          final view = tester.view;
          final dpr = view.devicePixelRatio;
          devicePixelRatio = dpr;
          final logical = view.physicalSize / dpr;
          final grid = ghosttyGridSize(_style, dpr);
          environment
            ..['Grid'] = '$benchCols × $benchRows cells'
            ..['Font'] = '$_fontFamily $_fontSize px'
            ..['Device pixel ratio'] = '$dpr'
            ..['Window (logical px)'] =
                '${logical.width.round()} × ${logical.height.round()}'
            ..['Dart'] = Platform.version.split(' ').first
            ..['OS'] = Platform.operatingSystemVersion
            ..['Frames per run'] = '$_frames (+ $_warmUpFrames warm-up)'
            ..['Passes'] = '$_passes, widget order rotated per pass';
          if (grid.width > logical.width || grid.height > logical.height) {
            fail(
              'the window (${logical.width} × ${logical.height}) cannot '
              'hold the grid (${grid.width} × ${grid.height}); enlarge the '
              'display',
            );
          }

          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              home: Align(
                alignment: Alignment.topLeft,
                child: subject.build(_style, dpr),
              ),
            ),
          );
          subject.write(setupBytes());
          await _nextFrame();

          final (:warmUp, :measured) = warmUpAndMeasured(
            scenario,
            warmUp: _warmUpFrames,
            count: _frames,
          );
          for (final bytes in warmUp) {
            if (bytes.isNotEmpty) subject.write(bytes);
            await _nextFrame();
          }

          final writeMicros = <int>[];
          final stopwatch = Stopwatch();
          final key = reportKey(scenario.label, name, pass);
          await binding.traceAction(() async {
            for (final bytes in measured) {
              if (bytes.isNotEmpty) {
                stopwatch
                  ..reset()
                  ..start();
                subject.write(bytes);
                stopwatch.stop();
                writeMicros.add(stopwatch.elapsedMicroseconds);
              }
              await _nextFrame();
            }
          }, reportKey: key);
          runs[key] = {
            'scenario': scenario.label,
            'subject': name,
            'pass': pass,
            'frames': _frames,
            'writeMicros': writeMicros,
          };

          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}

String _nameOf(BenchSubject Function() create) {
  final subject = create();
  try {
    return subject.name;
  } finally {
    subject.dispose();
  }
}
