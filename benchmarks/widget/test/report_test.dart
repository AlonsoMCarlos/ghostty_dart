import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_widget_benchmarks/src/report.dart';

Map<String, Object?> _summary(List<int> build, List<int> raster) => {
  'frame_count': build.length,
  'frame_rasterizer_count': raster.length,
  'frame_build_times': build,
  'frame_rasterizer_times': raster,
};

RunSummary _run(
  String scenario,
  String subject, {
  int pass = 1,
  required List<int> build,
  required List<int> raster,
  List<int> write = const [],
  int? requested,
}) => RunSummary(
  scenario: scenario,
  subject: subject,
  pass: pass,
  requestedFrames: requested ?? build.length,
  summary: _summary(build, raster),
  writeTimes: write,
);

void main() {
  test('reportKey is file-name safe and unique per pair and pass', () {
    expect(
      reportKey('full screen, warm', 'xterm 4.0.0', 2),
      'full_screen_warm__xterm_4_0_0__p2',
    );
    expect(
      reportKey('3 dirty rows', 'ghostty_dart_flutter', 1),
      '3_dirty_rows__ghostty_dart_flutter__p1',
    );
  });

  test('percentile uses the nearest rank; median', () {
    final sorted = List.generate(100, (i) => i + 1);
    expect(percentile(sorted, 90), 90);
    expect(percentile(sorted, 99), 99);
    expect(percentile(sorted, 100), 100);
    expect(percentile([5], 99), 5);
    expect(() => percentile([], 50), throwsArgumentError);
    expect(median([3, 1, 2]), 2);
    expect(median([4, 1, 2, 3]), 2.5);
  });

  test('Stats converts microseconds to milliseconds', () {
    final stats = Stats.of([1000, 2000, 3000, 10000]);
    expect(stats.average, 4.0);
    expect(stats.p90, 10.0);
    expect(stats.worst, 10.0);
    expect(Stats.of(const []).average, 0);
  });

  test('rendererOf reads the engine event names', () {
    // A category alone names no renderer.
    expect(
      rendererOf([
        {'cat': 'impeller', 'name': 'Render'},
      ]),
      'unknown',
    );
    expect(
      rendererOf([
        {'cat': 'flutter', 'name': 'SkCanvas::Flush'},
      ]),
      'Skia',
    );
    expect(
      rendererOf([
        {'cat': 'Embedder', 'name': 'GPURasterizer::Draw'},
        {'cat': 'Embedder', 'name': 'ReactorGLES::React'},
      ]),
      'Impeller (OpenGL ES)',
    );
    expect(
      rendererOf([
        {'cat': 'Embedder', 'name': 'CreateGlyphAtlas'},
      ]),
      'Impeller',
    );
    expect(rendererOf(const []), 'unknown');
  });

  test('passes: median of averages, pooled percentiles, write + UI', () {
    final report = markdownReport(
      [
        for (final (pass, ui) in [(1, 300), (2, 400), (3, 900)])
          _run(
            'idle',
            'ghostty_dart_flutter',
            pass: pass,
            build: [ui, ui],
            raster: [800, 800],
          ),
        _run(
          '3 dirty rows',
          'ghostty_dart_flutter',
          build: [600, 600],
          raster: [1000, 1000],
          write: [500, 500],
        ),
      ],
      environment: {'Device pixel ratio': '2.0'},
      devicePixelRatio: 2,
    );
    expect(report, contains('| Device pixel ratio | 2.0 |'));
    // idle: median of 0.3, 0.4, 0.9 = 0.4; worst pooled = 0.9; no writes.
    expect(
      report,
      contains(
        '| idle | ghostty_dart_flutter | 3 | 6/6 | 0.40 | 0.90 | 0.90 '
        '| 0.90 | 0.80 | 0.80 | 0.80 | 0.80 | 0.00 | 0.00 | 0.40 '
        '| met (≤ 0.5 / ≤ 1.0) |',
      ),
    );
    // 0.6 UI + 0.5 write = 1.1 > 1.0: the write counts against the target.
    expect(
      report,
      contains(
        '| 0.50 | 0.50 | 1.10 | UI missed, raster met (≤ 1.0 / ≤ 2.0) |',
      ),
    );
    expect(report, isNot(contains('⚠')));
    expect(report, isNot(contains('no verdict')));
    // Per pass: write average + UI average of that pass alone.
    expect(
      report,
      contains('| Scenario | Widget | Pass 1 | Pass 2 | Pass 3 |'),
    );
    expect(
      report,
      contains('| idle | ghostty_dart_flutter | 0.30 | 0.40 | 0.90 |'),
    );
    expect(
      report,
      contains('| 3 dirty rows | ghostty_dart_flutter | 1.10 | – | – |'),
    );
  });

  test('the verdict says which thread missed', () {
    final report = markdownReport(
      [
        _run(
          'idle',
          'ghostty_dart_flutter',
          build: [300, 300],
          raster: [5000, 5000],
        ),
      ],
      environment: const {},
      devicePixelRatio: 2,
    );
    expect(report, contains('| UI met, raster missed (≤ 0.5 / ≤ 1.0) |'));
  });

  test('no verdict away from DPR 2; other widgets never get one', () {
    final report = markdownReport(
      [
        _run('idle', 'ghostty_dart_flutter', build: [1], raster: [1]),
        _run('idle', 'xterm 4.0.0', build: [1], raster: [1]),
      ],
      environment: const {},
      devicePixelRatio: 1,
    );
    expect(report, contains('| n/a (DPR 1.0) |'));
    expect(report, contains('| idle | xterm 4.0.0 | 1 | 1/1 |'));
    expect(report, contains('no verdict is given'));
  });

  test('runs with under 95% of the frames are flagged', () {
    final run = _run(
      'idle',
      'xterm 4.0.0',
      build: List.filled(94, 1),
      raster: List.filled(100, 1),
      requested: 100,
    );
    expect(run.complete, isFalse);
    final report = markdownReport(
      [run],
      environment: const {},
      devicePixelRatio: 2,
    );
    expect(report, contains('94/100 ⚠'));
    expect(report, contains('do not publish'));
  });

  group('frameGapRegularity', () {
    const vsync = Duration(microseconds: 16667);
    test('a steady cadence has no jitter and no irregular gaps', () {
      final r = frameGapRegularity([
        33300,
        33400,
        33334,
        33350,
      ], vsyncPeriod: vsync);
      expect(r.jitterMs, lessThan(0.1));
      expect(r.irregularPercent, 0);
    });

    test('counts gaps of another whole number of vsyncs', () {
      final r = frameGapRegularity([
        33333,
        33333,
        66667,
        33333,
      ], vsyncPeriod: vsync);
      expect(r.irregularPercent, 25);
      expect(r.jitterMs, closeTo(14.43, 0.01));
    });

    test('is zero with fewer than two gaps', () {
      final r = frameGapRegularity([50000], vsyncPeriod: vsync);
      expect(r.jitterMs, 0);
      expect(r.irregularPercent, 0);
    });
  });
}
