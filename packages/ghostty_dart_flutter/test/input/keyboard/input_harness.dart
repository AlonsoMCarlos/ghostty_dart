import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/input/keyboard/terminal_input_scope.dart';
import 'package:ghostty_dart_flutter/src/input/keyboard/terminal_shortcuts.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_geometry.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_seams.dart';

/// 10 × 20 logical-pixel cells at DPR 1.
const testMetrics = VtCellMetrics(
  width: 10,
  height: 20,
  baseline: 15,
  advance: 10,
  devicePixelRatio: 1,
);

/// Where the scope sits in the window, so transforms are not identity.
const scopeOffset = Offset(50, 30);

/// A [TerminalInputScope] over a real controller, inside a [WidgetsApp]
/// (whose default shortcuts move focus on Tab and the arrows) next to a
/// second focusable widget.
final class InputHarness {
  InputHarness._(this.controller, this.seams);

  final VtTerminalController controller;
  final ControllerSeams seams;
  final output = <String>[];
  final composing = <bool>[];
  final focusNode = FocusNode(debugLabel: 'terminal');
  final otherNode = FocusNode(debugLabel: 'other');
  final scopeKey = GlobalKey<TerminalInputScopeState>();

  late final TerminalGeometry geometry = TerminalGeometry(
    metrics: testMetrics,
    cols: controller.cols,
    rows: controller.rows,
  );

  /// Everything sent so far, concatenated.
  String get sent => output.join();

  /// Builds the harness and pumps it, focusing the terminal.
  static Future<InputHarness> pump(
    WidgetTester tester, {
    bool readOnly = false,
    bool hardwareKeyboardOnly = false,
    Map<ShortcutActivator, Intent>? shortcuts,
    FocusOnKeyEventCallback? onKeyEvent,
    TextStyle? textStyle,
    TerminalTextSink? text,
    UnsafePasteCallback? onUnsafePaste,
    ValueGetter<OptionAsAlt>? macosOptionAsAlt,
    bool focus = true,
  }) async {
    final controller = VtTerminalController(cols: 20, rows: 5);
    final harness = InputHarness._(controller, ControllerSeams(controller));
    controller.onOutput = (bytes) =>
        harness.output.add(utf8.decode(bytes, allowMalformed: true));
    addTearDown(() {
      harness.focusNode.dispose();
      harness.otherNode.dispose();
      controller.dispose();
    });
    await tester.pumpWidget(
      harness.build(
        readOnly: readOnly,
        hardwareKeyboardOnly: hardwareKeyboardOnly,
        shortcuts: shortcuts,
        onKeyEvent: onKeyEvent,
        textStyle: textStyle,
        text: text,
        onUnsafePaste: onUnsafePaste,
        macosOptionAsAlt: macosOptionAsAlt,
      ),
    );
    if (focus) {
      harness.focusNode.requestFocus();
      await tester.pump();
    }
    return harness;
  }

  Widget build({
    bool readOnly = false,
    bool hardwareKeyboardOnly = false,
    Map<ShortcutActivator, Intent>? shortcuts,
    FocusOnKeyEventCallback? onKeyEvent,
    TextStyle? textStyle,
    TerminalTextSink? text,
    UnsafePasteCallback? onUnsafePaste,
    TextInputType? keyboardType,
    Brightness keyboardAppearance = Brightness.light,
    bool deleteDetection = true,
    Color? composingBackgroundColor,
    ValueGetter<OptionAsAlt>? macosOptionAsAlt,
    FocusNode? focusNode,
  }) => WidgetsApp(
    color: const Color(0xFF000000),
    builder: (context, _) => Padding(
      padding: EdgeInsets.only(left: scopeOffset.dx, top: scopeOffset.dy),
      child: Align(
        alignment: Alignment.topLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: geometry.viewSize.width,
              height: geometry.viewSize.height,
              child: TerminalInputScope(
                key: scopeKey,
                keys: seams,
                text: text ?? seams,
                geometry: geometry,
                focusNode: focusNode ?? this.focusNode,
                readOnly: readOnly,
                hardwareKeyboardOnly: hardwareKeyboardOnly,
                shortcuts: shortcuts,
                onKeyEvent: onKeyEvent,
                textStyle: textStyle,
                onComposingChanged: composing.add,
                onUnsafePaste: onUnsafePaste,
                keyboardType: keyboardType,
                keyboardAppearance: keyboardAppearance,
                deleteDetection: deleteDetection,
                composingBackgroundColor: composingBackgroundColor,
                macosOptionAsAlt: macosOptionAsAlt,
                child: const SizedBox.expand(),
              ),
            ),
            Focus(focusNode: otherNode, child: const SizedBox(height: 10)),
          ],
        ),
      ),
    ),
  );
}

/// Records the clipboard on [SystemChannels.platform] and serves [paste],
/// after [gate] completes when one is set (a slow clipboard).
final class FakeClipboard {
  FakeClipboard(WidgetTester tester, {this.paste}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            copied.add(
              (call.arguments as Map<Object?, Object?>)['text']! as String,
            );
          case 'Clipboard.getData':
            await gate?.future;
            return paste == null ? null : <String, Object?>{'text': paste};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  String? paste;
  Completer<void>? gate;
  final copied = <String>[];
}

/// Presses and releases [key] with [character], holding [modifiers].
Future<bool> tapKey(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  String? character,
  List<LogicalKeyboardKey> modifiers = const [],
  PhysicalKeyboardKey? physicalKey,
}) async {
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  final handled = await tester.sendKeyDownEvent(
    key,
    character: character,
    physicalKey: physicalKey,
  );
  await tester.sendKeyUpEvent(key, physicalKey: physicalKey);
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier);
  }
  return handled;
}

/// Sends `TextInputClient.updateEditingStateWithDeltas` as the engine does.
Future<void> sendDeltas(
  WidgetTester tester,
  List<Map<String, Object?>> deltas,
) async {
  final client =
      tester.testTextInput.log
              .lastWhere((call) => call.method == 'TextInput.setClient')
              .arguments
          as List<Object?>;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(
      MethodCall('TextInputClient.updateEditingStateWithDeltas', <Object?>[
        client[0],
        <String, Object?>{'deltas': deltas},
      ]),
    ),
    (_) {},
  );
  await tester.pump();
}

Map<String, Object?> delta(
  String oldText,
  String text,
  int start,
  int end, {
  int? caret,
  int composingBase = -1,
  int composingExtent = -1,
}) {
  final newLength = oldText.length - (end - start) + text.length;
  return {
    'oldText': oldText,
    'deltaText': text,
    'deltaStart': start,
    'deltaEnd': end,
    'selectionBase': caret ?? newLength,
    'selectionExtent': caret ?? newLength,
    'selectionAffinity': 'TextAffinity.downstream',
    'selectionIsDirectional': false,
    'composingBase': composingBase,
    'composingExtent': composingExtent,
  };
}
