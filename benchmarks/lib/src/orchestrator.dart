/// The driving side: builds the AOT executable, spawns one worker process
/// per engine × workload × task, checks the screens agree, and prints the
/// Markdown report.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'engines.dart';
import 'report.dart';
import 'worker.dart';
import 'workloads.dart';

/// Options of a whole benchmark run.
final class BenchOptions {
  BenchOptions.parse(Map<String, String> a)
    : runtimes = (a['runtime'] ?? 'jit,aot').split(','),
      mib = double.parse(a['size'] ?? '16'),
      runs = int.parse(a['runs'] ?? '5'),
      warmup = int.parse(a['warmup'] ?? '1'),
      chunkSizes = (a['chunks'] ?? '4096,65536')
          .split(',')
          .map(int.parse)
          .toList(),
      workloadNames = (a['workloads'] ?? workloads.map((w) => w.name).join(','))
          .split(','),
      engines = (a['engines'] ?? engineNames.join(',')).split(','),
      memory = a['memory'] != 'false',
      out = a['out'];

  /// `jit` and/or `aot`.
  final List<String> runtimes;

  /// Workload size in MiB.
  final double mib;
  final int runs;
  final int warmup;
  final List<int> chunkSizes;
  final List<String> workloadNames;
  final List<String> engines;

  /// Whether to run the RSS measurement processes.
  final bool memory;

  /// Optional file to also write the report to.
  final String? out;

  int get bytes => (mib * 1024 * 1024).round();
}

/// Runs the benchmark and prints the report.
Future<void> runBenchmark(BenchOptions o) async {
  final packageDir = await _packageDir();
  final tmp = await Directory.systemTemp.createTemp('ghostty_bench_');
  final report = Report(o, machineInfo: await _machineInfo());

  try {
    for (final runtime in o.runtimes) {
      final command = await _workerCommand(runtime, packageDir);
      for (final workload in o.workloadNames) {
        for (final engine in o.engines) {
          final screenPath = '${tmp.path}/$runtime-$workload-$engine.json';
          final t = await _spawn(
            command,
            packageDir,
            WorkerOptions(
              engine: engine,
              workload: workload,
              bytes: o.bytes,
              runs: o.runs,
              warmup: o.warmup,
              chunkSizes: o.chunkSizes,
              task: 'throughput',
              screenPath: screenPath,
            ),
          );
          final screen =
              (jsonDecode(File(screenPath).readAsStringSync()) as List)
                  .cast<String>();
          report.addThroughput(runtime, t, screen);
          stderr.writeln('  $runtime $workload $engine done');
        }
      }
      if (o.memory && runtime == o.runtimes.last) {
        for (final workload in o.workloadNames) {
          for (final engine in o.engines) {
            final m = await _spawn(
              command,
              packageDir,
              WorkerOptions(
                engine: engine,
                workload: workload,
                bytes: o.bytes,
                runs: 1,
                warmup: 0,
                chunkSizes: [o.chunkSizes.last],
                task: 'memory',
              ),
            );
            report.addMemory(runtime, m);
          }
        }
      }
    }
  } finally {
    await tmp.delete(recursive: true);
  }

  final markdown = report.toMarkdown();
  stdout.write(markdown);
  if (o.out != null) File(o.out!).writeAsStringSync(markdown);
  if (report.hasRequiredMismatch) {
    stderr.writeln('error: engines disagree on a required workload screen');
    exitCode = 1;
  }
}

Future<String> _packageDir() async {
  final lib = await Isolate.resolvePackageUri(
    Uri.parse('package:ghostty_dart_benchmarks/'),
  );
  return Directory.fromUri(lib!.resolve('..')).path;
}

/// The command that starts a worker for [runtime].
Future<List<String>> _workerCommand(String runtime, String packageDir) async {
  final dart = Platform.resolvedExecutable;
  switch (runtime) {
    case 'jit':
      return [dart, 'run', 'bin/parser_bench.dart'];
    case 'aot':
      stderr.writeln('building AOT executable (dart build cli)...');
      final build = await Process.run(dart, [
        'build',
        'cli',
        '--target=bin/parser_bench.dart',
        '--output=build/parser_bench',
      ], workingDirectory: packageDir);
      if (build.exitCode != 0) {
        throw ProcessException(
          dart,
          ['build', 'cli'],
          '${build.stdout}\n${build.stderr}',
          build.exitCode,
        );
      }
      return ['${packageDir}build/parser_bench/bundle/bin/parser_bench'];
    default:
      throw ArgumentError.value(runtime, 'runtime', 'use jit or aot');
  }
}

Future<Map<String, Object?>> _spawn(
  List<String> command,
  String packageDir,
  WorkerOptions options,
) async {
  final result = await Process.run(command.first, [
    ...command.skip(1),
    '--worker',
    ...options.toArgs(),
  ], workingDirectory: packageDir);
  final out = result.stdout as String;
  if (result.exitCode != 0) {
    throw ProcessException(
      command.first,
      options.toArgs(),
      '$out\n${result.stderr}',
      result.exitCode,
    );
  }
  final line = const LineSplitter()
      .convert(out)
      .lastWhere((l) => l.startsWith('{'));
  return jsonDecode(line) as Map<String, Object?>;
}

Future<Map<String, String>> _machineInfo() async {
  String? cpu;
  String? mem;
  try {
    final cpuinfo = File('/proc/cpuinfo').readAsLinesSync();
    cpu = cpuinfo
        .firstWhere((l) => l.startsWith('model name'))
        .split(':')
        .last
        .trim();
    final meminfo = File('/proc/meminfo').readAsLinesSync();
    final kb = int.parse(
      RegExp(
        r'\d+',
      ).firstMatch(meminfo.firstWhere((l) => l.startsWith('MemTotal')))![0]!,
    );
    mem = '${(kb / 1024 / 1024).toStringAsFixed(1)} GiB';
  } on Object {
    // Not Linux, or /proc is unavailable: leave the fields out.
  }
  return {
    'Date': DateTime.now().toUtc().toIso8601String().substring(0, 10),
    'CPU': '${cpu ?? 'unknown'} (${Platform.numberOfProcessors} logical CPUs)',
    'Memory': ?mem,
    'OS': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'Dart': Platform.version,
    'libghostty-vt': ghosttyBuildDescription(),
  };
}
