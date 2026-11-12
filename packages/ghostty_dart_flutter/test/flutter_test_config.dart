// Runs around every test file in this directory (flutter_test picks it up
// by name).
//
// The view delays notifications while output floods it, measured on
// ControllerSeams.debugNow (a monotonic clock). Inside testWidgets that
// clock is the test's fake clock, so the flood interval advances only with
// `tester.pump` and every test sees the same timings on a fast machine and
// on a slow CI runner. Plain `test`s keep the real clock.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final realNow = ControllerSeams.debugNow;
  Duration fakeNow() => binding.inTest
      ? Duration(microseconds: binding.clock.now().microsecondsSinceEpoch)
      : realNow();
  setUp(() => ControllerSeams.debugNow = fakeNow);
  tearDown(() => ControllerSeams.debugNow = realNow);
  await testMain();
}
