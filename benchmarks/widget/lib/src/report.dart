/// Turns `flutter_driver` timeline summaries into the Markdown report.
///
/// Pure Dart (no `dart:ui`), so the driver script on the host can use it.
library;

/// Report key of one measured run: `<scenario>__<subject>__p<pass>`,
/// file-name safe.
String reportKey(String scenario, String subject, int pass) =>
    '${_slug(scenario)}__${_slug(subject)}__p$pass';

String _slug(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

/// ADR 0011 targets for ghostty_dart_flutter, UI and raster thread, in ms,
/// stated at device pixel ratio 2.
const targets = <String, (double ui, double raster)>{
  'idle': (0.5, 1.0),
  '3 dirty rows': (1.0, 2.0),
  // ADR 0011 states "full screen, warm cache": caches warmed by the same
  // kind of output, which the fresh stream is after its warm-up. The
  // replay scenario gets the same target for comparison only.
  'full screen, fresh': (4.0, 4.0),
  'full screen, warm (cache replay)': (4.0, 4.0),
};

/// The device pixel ratio the ADR 0011 targets are stated for.
const targetDevicePixelRatio = 2.0;

/// One run: a scenario on a subject in one pass, from a
/// `TimelineSummary.summaryJson` plus the harness's own write timings.
final class RunSummary {
  /// Reads the fields the report uses from [summary].
  RunSummary({
    required this.scenario,
    required this.subject,
    required this.pass,
    required this.requestedFrames,
    required Map<String, Object?> summary,
    this.writeTimes = const [],
  }) : frames = (summary['frame_count'] as num?)?.toInt() ?? 0,
       rasterFrames = (summary['frame_rasterizer_count'] as num?)?.toInt() ?? 0,
       buildTimes = _micros(summary['frame_build_times']),
       rasterTimes = _micros(summary['frame_rasterizer_times']);

  /// Scenario label (see `Scenario.label`).
  final String scenario;

  /// Subject name.
  final String subject;

  /// Pass number, from 1.
  final int pass;

  /// Frames the benchmark drove.
  final int requestedFrames;

  /// Frames the timeline recorded (UI thread).
  final int frames;

  /// Rasterizations the timeline recorded.
  final int rasterFrames;

  /// Per-frame UI-thread times, microseconds.
  final List<int> buildTimes;

  /// Per-frame raster times, microseconds.
  final List<int> rasterTimes;

  /// Per-step time of the synchronous write (parsing plus whatever the
  /// widget does on a write before the frame), microseconds; empty for
  /// steps that write nothing.
  final List<int> writeTimes;

  /// Whether at least 95% of the requested frames were recorded on both
  /// threads; runs below that are flagged in the report.
  bool get complete =>
      frames >= requestedFrames * 0.95 &&
      rasterFrames >= requestedFrames * 0.95;

  static List<int> _micros(Object? value) =>
      value is List ? [for (final v in value) (v as num).toInt()] : const [];
}

/// Statistics of a list of microsecond samples, in milliseconds.
final class Stats {
  /// Computes the statistics of [micros] (all zero when empty).
  factory Stats.of(List<int> micros) {
    if (micros.isEmpty) return const Stats._(0, 0, 0, 0);
    final sorted = [...micros]..sort();
    double ms(num us) => us / 1000;
    final mean = sorted.reduce((a, b) => a + b) / sorted.length;
    return Stats._(
      ms(mean),
      ms(percentile(sorted, 90)),
      ms(percentile(sorted, 99)),
      ms(sorted.last),
    );
  }

  const Stats._(this.average, this.p90, this.p99, this.worst);

  /// Mean.
  final double average;

  /// 90th percentile.
  final double p90;

  /// 99th percentile.
  final double p99;

  /// Maximum.
  final double worst;
}

/// The [p]th percentile of the ascending [sorted] samples, nearest rank
/// (the same rule as flutter_driver's `TimelineSummary`).
int percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) throw ArgumentError.value(sorted, 'sorted', 'empty');
  final rank = (sorted.length * p / 100).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

/// The median of [values] (mean of the middle two for an even count).
double median(List<double> values) {
  if (values.isEmpty) throw ArgumentError.value(values, 'values', 'empty');
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// The renderer a timeline shows, from engine event names (the VM files
/// every engine event under the `Embedder` stream category, so categories
/// say nothing about the renderer).
///
/// Verified on Linux only (Flutter 3.47.9, Impeller's OpenGL ES backend,
/// 2026-11-10): every traced frame has `ReactorGLES::React` and
/// `RenderPassGLES::EncodeCommandsInReactor`, which also name the backend,
/// and frames that draw text have the typographer's `CreateGlyphAtlas`.
/// Metal and Vulkan event names are not known yet (no run on those
/// backends): such a run reads `Impeller` only through `CreateGlyphAtlas`.
/// Skia's rasterizer records `SkCanvas::Flush`, but only with
/// `--trace-skia`, so a Skia run usually reads `unknown`.
String rendererOf(List<Map<String, Object?>> traceEvents) {
  var impeller = false;
  var skia = false;
  for (final event in traceEvents) {
    final name = '${event['name']}';
    if (name.startsWith('ReactorGLES') || name.startsWith('RenderPassGLES')) {
      return 'Impeller (OpenGL ES)';
    }
    if (name == 'CreateGlyphAtlas') impeller = true;
    if (name == 'SkCanvas::Flush') skia = true;
  }
  if (impeller) return 'Impeller';
  return skia ? 'Skia' : 'unknown';
}

/// All passes of one scenario on one subject.
final class _Pair {
  _Pair(this.scenario, this.subject);

  final String scenario;
  final String subject;
  final runs = <RunSummary>[];

  List<int> _pool(List<int> Function(RunSummary) of) => [
    for (final run in runs) ...of(run),
  ];

  double _median(List<int> Function(RunSummary) of) =>
      median([for (final run in runs) Stats.of(of(run)).average]);
}

String _f(double ms) => ms.toStringAsFixed(2);

/// The Markdown report: one row per scenario and widget, over every pass.
///
/// Averages are the median of the per-pass averages; percentiles and the
/// worst frame pool every pass's frames. "Write + UI" adds the median write
/// time to the median UI frame time: work a widget does synchronously on a
/// write is on the UI thread too, so the ADR 0011 UI target is checked
/// against it. The verdict is printed only for runs at
/// [targetDevicePixelRatio], the ratio the targets are stated for.
String markdownReport(
  List<RunSummary> runs, {
  required Map<String, String> environment,
  required double devicePixelRatio,
}) {
  final pairs = <String, _Pair>{};
  for (final run in runs) {
    pairs
        .putIfAbsent(
          '${run.scenario}\n${run.subject}',
          () => _Pair(run.scenario, run.subject),
        )
        .runs
        .add(run);
  }
  final atTarget = devicePixelRatio == targetDevicePixelRatio;

  final out = StringBuffer()
    ..writeln('### Environment')
    ..writeln()
    ..writeln('| | |')
    ..writeln('|---|---|');
  for (final MapEntry(:key, :value) in environment.entries) {
    out.writeln('| $key | $value |');
  }
  out
    ..writeln()
    ..writeln('### Frame times (ms)')
    ..writeln()
    ..writeln(
      'UI = frame build time (build, layout, paint on the UI thread); '
      'raster = rasterizer time; write = the synchronous write before the '
      'frame. avg = median of the per-pass averages; p90, p99 and worst '
      'pool all passes.',
    )
    ..writeln()
    ..writeln(
      '| Scenario | Widget | Passes | Frames | UI avg | UI p90 | UI p99 '
      '| UI worst | Raster avg | Raster p90 | Raster p99 | Raster worst '
      '| Write avg | Write p99 | Write + UI avg | ADR target |',
    )
    ..writeln(
      '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:'
      '|---:|---:|---:|---|',
    );
  for (final pair in pairs.values) {
    final ui = Stats.of(pair._pool((r) => r.buildTimes));
    final raster = Stats.of(pair._pool((r) => r.rasterTimes));
    final write = Stats.of(pair._pool((r) => r.writeTimes));
    final uiAvg = pair._median((r) => r.buildTimes);
    final rasterAvg = pair._median((r) => r.rasterTimes);
    final writeAvg = pair._median((r) => r.writeTimes);
    final target = targets[pair.scenario];
    var verdict = '–';
    if (pair.subject.startsWith('ghostty') && target != null) {
      if (atTarget) {
        final uiOk = writeAvg + uiAvg <= target.$1;
        final rasterOk = rasterAvg <= target.$2;
        final which = uiOk == rasterOk
            ? (uiOk ? 'met' : 'missed')
            : 'UI ${uiOk ? 'met' : 'missed'}, raster '
                  '${rasterOk ? 'met' : 'missed'}';
        verdict = '$which (≤ ${target.$1} / ≤ ${target.$2})';
      } else {
        verdict = 'n/a (DPR $devicePixelRatio)';
      }
    }
    final frames = pair.runs.fold(0, (sum, r) => sum + r.frames);
    final requested = pair.runs.fold(0, (sum, r) => sum + r.requestedFrames);
    final complete = pair.runs.every((r) => r.complete);
    out.writeln(
      '| ${pair.scenario} | ${pair.subject} | ${pair.runs.length} '
      '| $frames/$requested${complete ? '' : ' ⚠'} '
      '| ${_f(uiAvg)} | ${_f(ui.p90)} | ${_f(ui.p99)} | ${_f(ui.worst)} '
      '| ${_f(rasterAvg)} | ${_f(raster.p90)} | ${_f(raster.p99)} '
      '| ${_f(raster.worst)} | ${_f(writeAvg)} | ${_f(write.p99)} '
      '| ${_f(writeAvg + uiAvg)} | $verdict |',
    );
  }
  final passes = runs.fold(0, (most, r) => r.pass > most ? r.pass : most);
  out
    ..writeln()
    ..writeln('### Write + UI average per pass (ms)')
    ..writeln()
    ..writeln(
      '| Scenario | Widget | '
      '${[for (var p = 1; p <= passes; p++) 'Pass $p'].join(' | ')} |',
    )
    ..writeln('|---|---|${'---:|' * passes}');
  for (final pair in pairs.values) {
    final cells = [
      for (var p = 1; p <= passes; p++)
        switch (pair.runs.where((r) => r.pass == p).firstOrNull) {
          null => '–',
          final run => _f(
            Stats.of(run.writeTimes).average + Stats.of(run.buildTimes).average,
          ),
        },
    ];
    out.writeln(
      '| ${pair.scenario} | ${pair.subject} | ${cells.join(' | ')} |',
    );
  }
  if (!atTarget) {
    out
      ..writeln()
      ..writeln(
        'The ADR 0011 targets are stated at DPR $targetDevicePixelRatio; '
        'this run used DPR $devicePixelRatio, so no verdict is given.',
      );
  }
  if (runs.any((r) => !r.complete)) {
    out
      ..writeln()
      ..writeln(
        '⚠ fewer than 95% of the driven frames were recorded: do not '
        'publish these numbers.',
      );
  }
  return out.toString();
}
