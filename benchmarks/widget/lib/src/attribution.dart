/// The layers and the report of the attribution benchmark
/// (`lib/attribution_main.dart`): pure functions, tested headlessly.
library;

/// Kitty's CPU time per MB of `tree ~` on the maintainer's machine
/// (3.67 s for 65.5 MB, 2026-11-12): the reference the table compares
/// against.
const kittyMsPerMb = 56.0;

/// The cumulative layers, cheapest first.
enum Layer {
  /// flutter_pty2 reads and acknowledges; the bytes are discarded.
  pty,

  /// Plus `VtTerminalController.writeBytes`, no view.
  parser,

  /// Plus a full-window frame that only fills a rectangle, at the view's
  /// flood cadence.
  blank,

  /// The controller with a full-window `VtTerminalView`.
  view;

  /// Whether the layer draws frames (and so runs once per pacing).
  bool get paints => this == blank || this == view;
}

/// [value] rounded to two decimals.
double round2(num value) => (value * 100).round() / 100;

/// The engine switches the Linux embedder reads from the environment
/// (`FLUTTER_ENGINE_SWITCHES` = n, `FLUTTER_ENGINE_SWITCH_1..n`; profile
/// and debug builds only, `shell/platform/common/engine_switches.cc`).
List<String> engineSwitches(Map<String, String> environment) {
  final count = int.tryParse(environment['FLUTTER_ENGINE_SWITCHES'] ?? '');
  if (count == null) return const [];
  return [
    for (var i = 1; i <= count; i++)
      if (environment['FLUTTER_ENGINE_SWITCH_$i'] case final value?) '--$value',
  ];
}

/// The median of [values] (the mean of the two middle ones when even).
double median(List<num> values) {
  if (values.isEmpty) return double.nan;
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle].toDouble()
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

/// The thread groups the table shows, from a thread name as
/// `threadCpu` gives it (digits replaced by `#`, names cut at 15
/// characters by the kernel: Flutter's raster thread is
/// `io.flutter.rast`).
String threadGroup(String name, String mainThread) {
  // The UI isolate's own thread when it does not run on GTK's
  // (`BENCH_UI_THREAD=separate`).
  if (name == mainThread || name.startsWith('io.flutter.ui')) return 'main';
  if (name.startsWith('io.flutter.rast')) return 'raster';
  if (name.startsWith('DartWorker')) return 'dart workers';
  if (_gpuDriverThreads.hasMatch(name)) return 'gpu driver';
  return 'other';
}

/// Mesa's (and llvmpipe's) worker threads: GL driver work done for the
/// raster and main threads.
final _gpuDriverThreads = RegExp(
  r'^(llvmpipe|gallium|gdrv|radeon|amdgpu|si_|radv|:disk|:sh|:gl|mesa|nv|iris)',
);

const _groups = ['main', 'raster', 'gpu driver', 'dart workers', 'other'];

/// The key of a configuration: the layer, plus the pacing when it paints.
String configKey(Map<String, Object?> result) {
  final pacing = result['pacing'];
  return pacing == null ? '${result['layer']}' : '${result['layer']} $pacing';
}

/// The markdown report of [results] (the `ATTRIBUTION` lines' maps):
/// medians per configuration, then each layer's increment per pacing,
/// per MB and per frame.
///
/// [mainThread] is the name of the thread that runs the UI isolate and
/// presents frames (the process's own on Linux).
List<String> attributionTable(
  List<Map<String, Object?>> results, {
  required String mainThread,
  required String title,
}) {
  final byConfig = <String, List<Map<String, Object?>>>{};
  for (final result in results) {
    (byConfig[configKey(result)] ??= []).add(result);
  }
  double perMb(Map<String, Object?> r, num ms) => ms / (r['MB']! as num);
  final cpuPerMb = <String, double>{};
  final framesPerMb = <String, double>{};
  final lines = <String>[
    '### $title',
    '',
    '| configuration | runs | CPU ms/MB (min-max) | main (GTK + UI isolate) | raster '
        '| gpu driver | dart workers | other (pty reactor, exited threads) '
        '| frames/s | wall s |',
    '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|',
  ];
  String fmt(double value) => value.toStringAsFixed(1);
  for (final MapEntry(key: config, value: runs) in byConfig.entries) {
    final cpu = [for (final r in runs) perMb(r, r['cpu ms']! as num)];
    final groups = <String, List<double>>{};
    for (final r in runs) {
      final sums = {for (final g in _groups) g: 0};
      final threads = (r['thread cpu ms']! as Map).cast<String, num>();
      for (final MapEntry(:key, :value) in threads.entries) {
        final group = threadGroup(key, mainThread);
        if (group != 'other') sums[group] = sums[group]! + value.toInt();
      }
      final named = sums.values.fold(0, (a, b) => a + b);
      // Everything else, exited threads included.
      sums['other'] = (r['cpu ms']! as num).toInt() - named;
      for (final MapEntry(:key, :value) in sums.entries) {
        (groups[key] ??= []).add(perMb(r, value));
      }
    }
    final fps = [
      for (final r in runs) (r['frames']! as num) / (r['wall s']! as num),
    ];
    final wall = [for (final r in runs) r['wall s']! as num];
    cpuPerMb[config] = median(cpu);
    framesPerMb[config] = median([
      for (final r in runs) perMb(r, r['frames']! as num),
    ]);
    final sorted = [...cpu]..sort();
    lines.add(
      '| $config | ${runs.length} | ${fmt(median(cpu))} '
      '(${fmt(sorted.first)}-${fmt(sorted.last)}) '
      '| ${_groups.map((g) => fmt(median(groups[g]!))).join(' | ')} '
      '| ${fmt(median(fps))} | ${fmt(median(wall))} |',
    );
  }
  final pacings = <String>{
    for (final r in results)
      if (r['pacing'] case final String pacing) pacing,
  };
  final pty = cpuPerMb['pty'];
  final parser = cpuPerMb['parser'];
  String cell(double? value) => value == null ? '-' : fmt(value);
  double? minus(double? a, double? b) => a == null || b == null ? null : a - b;
  // CPU ms per frame of [config] over the parser layer: what each frame
  // costs, comparable across machines that draw different frame rates.
  double? perFrame(String config) {
    final cpu = cpuPerMb[config];
    final frames = framesPerMb[config];
    if (cpu == null || parser == null || frames == null || frames == 0) {
      return null;
    }
    return (cpu - parser) / frames;
  }

  lines
    ..add('')
    ..add(
      '| increment (medians) | '
      '${pacings.isEmpty ? 'all' : pacings.join(' | ')} |',
    )
    ..add('|---|${'---:|' * (pacings.isEmpty ? 1 : pacings.length)}');
  String row(String label, double? Function(String pacing) value) =>
      '| $label | '
      '${(pacings.isEmpty ? [''] : pacings).map((p) => cell(value(p))).join(' | ')} |';
  lines
    ..add(row('pty (L0), ms/MB', (_) => pty))
    ..add(
      row('parser + controller (L1 - L0), ms/MB', (_) => minus(parser, pty)),
    )
    ..add(
      row(
        'Flutter frame (L2 - L1), ms/MB',
        (p) => minus(cpuPerMb['blank $p'], parser),
      ),
    )
    ..add(
      row(
        'widget (L3 - L2), ms/MB',
        (p) => minus(cpuPerMb['view $p'], cpuPerMb['blank $p']),
      ),
    )
    ..add(row('total (L3), ms/MB', (p) => cpuPerMb['view $p']))
    ..add(
      row('total / Kitty (${fmt(kittyMsPerMb)} ms/MB)', (p) {
        final total = cpuPerMb['view $p'];
        return total == null ? null : total / kittyMsPerMb;
      }),
    )
    ..add(row('Flutter frame, ms/frame', (p) => perFrame('blank $p')))
    ..add(
      row(
        'widget, ms/frame',
        (p) => minus(perFrame('view $p'), perFrame('blank $p')),
      ),
    )
    ..add(row('frames/MB (view)', (p) => framesPerMb['view $p']));
  return lines;
}
