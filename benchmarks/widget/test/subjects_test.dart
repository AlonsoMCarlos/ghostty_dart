// Headless check of the harness wiring (no timing): every widget builds,
// takes the same streams, and ends with the same screen text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_widget_benchmarks/src/frame_streams.dart';
import 'package:ghostty_dart_widget_benchmarks/src/subjects.dart';

const _style = TextStyle(fontFamily: 'monospace', fontSize: 12);

void main() {
  for (final scenario in Scenario.values) {
    testWidgets('all widgets show the same screen after ${scenario.label}', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(4000, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final screens = <String, List<String>>{};
      for (final create in allSubjects) {
        final subject = create();
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: subject.build(_style, 1),
            ),
          ),
        );
        subject.write(setupBytes());
        await tester.pump();
        for (final bytes in frameWrites(scenario, fullScreenCycle + 3)) {
          if (bytes.isNotEmpty) subject.write(bytes);
          await tester.pump();
        }
        screens[subject.name] = [
          for (var row = 0; row < benchRows; row++) subject.rowText(row),
        ];
        expect(tester.takeException(), isNull, reason: subject.name);
        await tester.pumpWidget(const SizedBox());
        subject.dispose();
      }

      final reference = screens.values.first;
      if (scenario != Scenario.scroll) {
        // Every other scenario writes whole rows; scroll writes text lines.
        expect(reference.every((row) => row.length == benchCols), isTrue);
      } else {
        expect(reference.where((row) => row.isNotEmpty), isNotEmpty);
      }
      for (final MapEntry(:key, :value) in screens.entries) {
        expect(value, reference, reason: key);
      }
    });
  }

  test('the ghostty grid size holds exactly 200 x 60 cells', () {
    final size = ghosttyGridSize(_style, 2);
    expect(size.width, greaterThan(0));
    expect(size.height, greaterThan(0));
    // Whole device pixels per cell.
    expect((size.width * 2 / benchCols) % 1, 0);
    expect((size.height * 2 / benchRows) % 1, 0);
  });
}
