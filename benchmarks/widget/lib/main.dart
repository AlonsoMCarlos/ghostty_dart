/// Shows one benchmark subject running one scenario, to look at what the
/// frame benchmark measures. The measurement itself is
/// `integration_test/frame_bench_test.dart` (`mise run bench:widget`).
///
/// ```sh
/// flutter run --profile -d linux \
///   --dart-define=SUBJECT=1 --dart-define=SCENARIO=fullScreen
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'src/frame_streams.dart';
import 'src/subjects.dart';

const _subject = int.fromEnvironment('SUBJECT');
const _scenario = String.fromEnvironment('SCENARIO', defaultValue: 'dirtyRows');

void main() => runApp(const _Viewer());

class _Viewer extends StatefulWidget {
  const _Viewer();

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  final _subjectInstance = _subject >= 0 && _subject < allSubjects.length
      ? allSubjects[_subject]()
      : throw ArgumentError.value(
          _subject,
          'SUBJECT',
          '0 = ghostty_dart_flutter, 1 = xterm 4.0.0, 2 = xterm2 5.4.0',
        );
  late final _writes = frameWrites(
    Scenario.values.byName(_scenario),
    fullScreenCycle * 30,
  );
  var _frame = 0;

  @override
  void initState() {
    super.initState();
    _subjectInstance.write(setupBytes());
    SchedulerBinding.instance.addPersistentFrameCallback(_tick);
  }

  void _tick(Duration _) {
    if (!mounted) return;
    final bytes = _writes[_frame++ % _writes.length];
    // After the frame: writing marks the terminal for the next one.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (bytes.isNotEmpty) _subjectInstance.write(bytes);
      SchedulerBinding.instance.scheduleFrame();
    });
  }

  @override
  void dispose() {
    _subjectInstance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Align(
      alignment: Alignment.topLeft,
      child: _subjectInstance.build(
        const TextStyle(fontFamily: 'monospace', fontSize: 12),
        View.of(context).devicePixelRatio,
      ),
    ),
  );
}
