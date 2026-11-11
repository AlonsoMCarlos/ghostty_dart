// Own tests of the ported SuggestionPortal.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/suggestion.dart';

void main() {
  testWidgets('SuggestionPortal shows the popup below the cursor, or above '
      'it when there is no room', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(400, 300);
    addTearDown(tester.view.reset);
    final controller = SuggestionPortalController();
    await tester.pumpWidget(
      MaterialApp(
        home: SuggestionPortal(
          controller: controller,
          overlayBuilder: (_) =>
              const SizedBox(key: ValueKey('popup'), width: 100, height: 50),
          child: const SizedBox.expand(),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('popup')), findsNothing);

    controller.update(const Rect.fromLTWH(20, 30, 10, 10));
    await tester.pump();
    final popup = find.byKey(const ValueKey('popup'));
    // Below the cursor, cursorMargin (4) apart.
    expect(tester.getTopLeft(popup), const Offset(20, 44));

    controller.update(const Rect.fromLTWH(350, 260, 10, 10));
    await tester.pump();
    // No room below: above the cursor; pushed left to fit (padding 8).
    expect(tester.getTopLeft(popup), const Offset(292, 206));

    controller.hide();
    await tester.pump();
    expect(popup, findsNothing);
  });
}
