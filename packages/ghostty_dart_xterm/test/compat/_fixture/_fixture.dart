// Ported from package:xterm 4.0.0 (test/_fixture/_fixture.dart).
// Copyright (c) 2020 xuty. MIT License, see test/compat/LICENSE.xterm.
// Changes: paths point at test/compat/_fixture/ (flutter test runs in the
// package directory); lint ignores for xterm's method name.
import 'dart:io';

abstract class TestFixtures {
  // xterm's name, kept so ported call sites do not change.
  // ignore: non_constant_identifier_names
  static String htop_80x25_3s() {
    return File('test/compat/_fixture/htop_80x25_3s.txt').readAsStringSync();
  }

  static String colors() {
    return File('test/compat/_fixture/colors.txt').readAsStringSync();
  }
}
