// Runs around every test file in this directory (flutter_test picks it up
// by name).
//
// The view delays notifications while output floods it, to a frame a
// whole number of vsyncs after the last paint, timed on
// ControllerSeams.debugNow (the engine's vsync clock). Inside testWidgets
// that clock is the test's fake clock, which is also the timestamp of the
// frames tester.pump draws, so the pacing advances only with `tester.pump`
// and every test sees the same timings on a fast machine and on a slow CI
// runner. Plain `test`s keep the real clock.
//
// Kitty graphics animations run on debugAnimationNow, replaced by the same
// fake clock, so animation frames advance with `tester.pump` too.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/src/controller/controller_internals.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final realNow = ControllerSeams.debugNow;
  final realAnimationNow = debugAnimationNow;
  Duration fakeNow() => binding.inTest
      ? Duration(microseconds: binding.clock.now().microsecondsSinceEpoch)
      : realNow();
  setUp(() {
    ControllerSeams.debugNow = fakeNow;
    debugAnimationNow = () => binding.inTest ? fakeNow() : realAnimationNow();
  });
  tearDown(() {
    ControllerSeams.debugNow = realNow;
    debugAnimationNow = realAnimationNow;
  });
  await testMain();
}
