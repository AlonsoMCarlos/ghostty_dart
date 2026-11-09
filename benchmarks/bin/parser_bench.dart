// Parser/throughput benchmark: ghostty_dart vs xterm 4.0.0 vs xterm2_core.
//
// Run from the repository root:  mise run bench:parser
// Options (all `--key=value`): --runtime=jit,aot  --size=<MiB>  --runs=N
//   --warmup=N  --chunks=4096,65536  --workloads=ascii,sgr,...
//   --engines=ghostty_dart,xterm,xterm2_core  --memory=false  --out=<file>
//
// See README.md for the methodology.

import 'package:ghostty_dart_benchmarks/src/orchestrator.dart';
import 'package:ghostty_dart_benchmarks/src/worker.dart';

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  var worker = false;
  for (final arg in args) {
    if (arg == '--worker') {
      worker = true;
      continue;
    }
    final match = RegExp(r'^--([a-z]+)=(.*)$').firstMatch(arg);
    if (match == null) {
      throw ArgumentError.value(arg, 'argument', 'expected --key=value');
    }
    options[match[1]!] = match[2]!;
  }
  if (worker) {
    runWorker(WorkerOptions.parse(options));
  } else {
    await runBenchmark(BenchOptions.parse(options));
  }
}
