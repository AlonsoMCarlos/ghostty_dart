import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_widget_benchmarks/src/attribution.dart';

Map<String, Object?> _result(
  String layer,
  int cpuMs, {
  String? pacing,
  Map<String, int> threads = const {},
}) => {
  'layer': layer,
  'pacing': pacing,
  'MB': 10.0,
  'cpu ms': cpuMs,
  'frames': 600,
  'wall s': 10.0,
  'thread cpu ms': threads,
};

void main() {
  test('engine switches come from the environment like the embedder reads '
      'them', () {
    expect(engineSwitches({}), isEmpty);
    expect(
      engineSwitches({
        'FLUTTER_ENGINE_SWITCHES': '1',
        'FLUTTER_ENGINE_SWITCH_1': 'enable-impeller=false',
      }),
      ['--enable-impeller=false'],
    );
  });

  test('median of odd and even lists', () {
    expect(median([3, 1, 2]), 2);
    expect(median([4, 1, 2, 3]), 2.5);
  });

  test('threads are grouped by role', () {
    expect(threadGroup('app', 'app'), 'main');
    expect(threadGroup('io.flutter.ui', 'app'), 'main');
    expect(threadGroup('io.flutter.rast', 'app'), 'raster');
    expect(threadGroup('llvmpipe-#', 'app'), 'gpu driver');
    expect(threadGroup('DartWorker', 'app'), 'dart workers');
    expect(threadGroup('pty-reactor', 'app'), 'other');
  });

  test('the table reports medians and each layer increment', () {
    final lines = attributionTable(
      [
        for (final run in [0, 10, 20]) ...[
          _result('pty', 40 + run),
          _result('parser', 100 + run),
          _result(
            'blank',
            500 + run,
            pacing: 'smooth',
            threads: {
              'app': 300,
              'io.flutter.rast': 50,
              'llvmpipe-#': 30,
              'DartWorker': 20,
            },
          ),
          _result('view', 900 + run, pacing: 'smooth'),
        ],
      ],
      mainThread: 'app',
      title: 'test',
    );
    final table = lines.join('\n');
    // Medians: pty 5, parser 11, blank 51, view 91 ms/MB.
    expect(table, contains('| pty | 3 | 5.0 (4.0-6.0) |'));
    expect(
      table,
      contains(
        '| blank smooth | 3 | 51.0 (50.0-52.0) | 30.0 | 5.0 | 3.0 | 2.0 '
        '| 11.0 | 60.0 | 10.0 |',
      ),
    );
    expect(table, contains('| pty (L0), ms/MB | 5.0 |'));
    expect(table, contains('| parser + controller (L1 - L0), ms/MB | 6.0 |'));
    expect(table, contains('| Flutter frame (L2 - L1), ms/MB | 40.0 |'));
    expect(table, contains('| widget (L3 - L2), ms/MB | 40.0 |'));
    expect(table, contains('| total (L3), ms/MB | 91.0 |'));
    // 60 frames per MB: (51 - 11) / 60 and (91 - 11) / 60 - that.
    expect(table, contains('| Flutter frame, ms/frame | 0.7 |'));
    expect(table, contains('| widget, ms/frame | 0.7 |'));
    expect(table, contains('| frames/MB (view) | 60.0 |'));
  });
}
