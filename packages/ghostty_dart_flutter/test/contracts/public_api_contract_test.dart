// Contract tests of the public value types and the view skeleton
// (ADR 0011).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

void main() {
  group('VtCellMetrics', () {
    test('aligned rounds width and baseline, ceils height, per device', () {
      final metrics = VtCellMetrics.aligned(
        advance: 8.4287,
        ascent: 13.03,
        descent: 3.3,
        devicePixelRatio: 1.5,
      );
      expect(metrics.widthPx, 13); // 12.64 -> 13
      expect(metrics.width, closeTo(13 / 1.5, 1e-12));
      expect(metrics.heightPx, 25); // 24.495 -> 25
      expect(metrics.height, closeTo(25 / 1.5, 1e-12));
      // leading 0.3367 / 2 + ascent 13.03 = 13.198 -> 19.8 -> 20 px
      expect(metrics.baseline, closeTo(20 / 1.5, 1e-12));
      expect(metrics.letterSpacing, closeTo(13 / 1.5 - 8.4287, 1e-12));
    });

    test('aligned keeps at least one device pixel', () {
      final metrics = VtCellMetrics.aligned(
        advance: 0.1,
        ascent: 0.1,
        descent: 0.1,
        devicePixelRatio: 1,
      );
      expect((metrics.widthPx, metrics.heightPx), (1, 1));
    });

    test('aligned rejects bad input', () {
      expect(
        () => VtCellMetrics.aligned(
          advance: 1,
          ascent: 1,
          descent: 1,
          devicePixelRatio: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => VtCellMetrics.aligned(
          advance: 0,
          ascent: 1,
          descent: 1,
          devicePixelRatio: 1,
        ),
        throwsArgumentError,
      );
    });

    test('measure returns device-aligned metrics', () {
      for (final dpr in [1.0, 1.5, 2.0, 2.625]) {
        final metrics = VtCellMetrics.measure(
          const TextStyle(fontSize: 14),
          devicePixelRatio: dpr,
        );
        expect(metrics.width * dpr, closeTo(metrics.widthPx, 1e-9));
        expect(metrics.height * dpr, closeTo(metrics.heightPx, 1e-9));
        expect(metrics.baseline, lessThanOrEqualTo(metrics.height));
        expect(metrics.devicePixelRatio, dpr);
      }
    });

    test('value equality', () {
      const a = VtCellMetrics(
        width: 8,
        height: 16,
        baseline: 12,
        advance: 8,
        devicePixelRatio: 1,
      );
      const b = VtCellMetrics(
        width: 8,
        height: 16,
        baseline: 12,
        advance: 8,
        devicePixelRatio: 1,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.size, const Size(8, 16));
    });
  });

  group('VtTerminalTheme', () {
    test('matches xterm 4.0.0 defaultTheme values', () {
      const theme = VtTerminalTheme.defaultTheme;
      expect(theme.background, const Color(0xFF1E1E1E));
      expect(theme.foreground, const Color(0xFFCCCCCC));
      expect(theme.cursor, const Color(0xAAAEAFAD));
      expect(theme.ansiColors, hasLength(16));
      expect(theme.ansiColors[9], theme.brightRed);
    });

    test('toPalette has 256 opaque colours', () {
      final palette = VtTerminalTheme.defaultTheme.toPalette();
      expect(palette, hasLength(256));
      expect(palette[0], const RgbColor(0, 0, 0));
      expect(palette[1], const RgbColor(0xCD, 0x31, 0x31));
      expect(palette[17], const RgbColor(0, 0, 95));
      expect(palette[196], const RgbColor(255, 0, 0));
    });

    test('copyWith and equality', () {
      const theme = VtTerminalTheme.defaultTheme;
      final changed = theme.copyWith(red: const Color(0xFF000001));
      expect(changed, isNot(theme));
      expect(changed.copyWith(red: theme.red), theme);
      expect(changed.copyWith(red: theme.red).hashCode, theme.hashCode);
    });
  });

  group('VtTerminalView', () {
    testWidgets('builds with a controller', (tester) async {
      final controller = VtTerminalController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: VtTerminalView(controller: controller),
        ),
      );
      expect(find.byType(VtTerminalView), findsOneWidget);
    });

    testWidgets('VtTerminalKeyToolbar builds', (tester) async {
      final controller = VtTerminalController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(VtTerminalKeyToolbar(controller: controller));
      expect(find.byType(VtTerminalKeyToolbar), findsOneWidget);
    });
  });
}
