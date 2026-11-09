// Keeps the benchmark runnable: runs each scenario briefly. The real
// numbers come from `dart run test/render/render_benchmark.dart`.

import 'package:test/test.dart';

import 'render_benchmark.dart';

void main() {
  test('the render benchmark runs', () {
    final results = runRenderBenchmark(
      duration: const Duration(milliseconds: 20),
      report: (_) {},
    );
    expect(results, hasLength(4));
    for (final result in results) {
      expect(result.frames, greaterThan(0), reason: result.name);
      expect(result.rowsPerSecond, greaterThan(0), reason: result.name);
    }
  });
}
