// Host side of `mise run bench:widget`: receives the traced timelines,
// writes build/<key>.timeline{,_summary}.json, and the Markdown report
// build/widget_bench.md (also printed).
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:ghostty_dart_widget_benchmarks/src/report.dart';
import 'package:integration_test/integration_test_driver.dart';

String _cpu() {
  try {
    if (Platform.isMacOS) {
      final result = Process.runSync('sysctl', [
        '-n',
        'machdep.cpu.brand_string',
      ]);
      return '${result.stdout}'.trim();
    }
    final line = File(
      '/proc/cpuinfo',
    ).readAsLinesSync().firstWhere((l) => l.startsWith('model name'));
    return line.split(':').last.trim();
  } on Object {
    return 'unknown';
  }
}

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null) throw StateError('the benchmark reported no data');
    final meta = data['bench_meta'] as Map<String, dynamic>;
    final runs = <RunSummary>[];
    final renderers = <String>{};
    for (final MapEntry(:key, :value)
        in (meta['runs'] as Map<String, dynamic>).entries) {
      final info = value as Map<String, dynamic>;
      final json = data[key] as Map<String, dynamic>;
      renderers.add(
        rendererOf([
          for (final event in (json['traceEvents'] as List<dynamic>? ?? []))
            (event as Map<String, dynamic>).cast<String, Object?>(),
        ]),
      );
      final summary = TimelineSummary.summarize(Timeline.fromJson(json));
      await summary.writeTimelineToFile(key, pretty: true);
      runs.add(
        RunSummary(
          scenario: info['scenario'] as String,
          subject: info['subject'] as String,
          pass: info['pass'] as int,
          requestedFrames: info['frames'] as int,
          summary: summary.summaryJson,
          writeTimes: [
            for (final us in info['writeMicros'] as List<dynamic>) us as int,
          ],
        ),
      );
    }
    final requested = '${meta['renderer']}';
    final environment = {
      'Date': DateTime.now().toUtc().toIso8601String().substring(0, 10),
      'CPU': _cpu(),
      'Renderer': '${renderers.join(', ')} (timeline; requested: $requested)',
      ...(meta['environment'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, '$v'),
      ),
    };
    final report = markdownReport(
      runs,
      environment: environment,
      devicePixelRatio: (meta['devicePixelRatio'] as num).toDouble(),
    );
    File('build/widget_bench.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(report);
    stdout.write(report);
  },
);
