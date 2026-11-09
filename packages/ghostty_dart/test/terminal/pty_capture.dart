// Test-only helpers for terminal effects: capture what a terminal writes
// back to its pty (paste output, query replies) through
// `VtTerminalEffects.onWritePty`, and collect the errors callbacks report.

import 'dart:async';
import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';

import '../support/terminal_support.dart';

/// Captures everything [terminal] writes to its pty while [body] runs and
/// returns it, restoring the previous `onWritePty` callback afterwards.
///
/// [onWrite], if given, runs inside every callback (i.e. inside the native
/// call that wrote), after the bytes are recorded.
List<int> capturePty(
  VtTerminal terminal,
  void Function() body, {
  void Function()? onWrite,
}) {
  final output = <int>[];
  final previous = terminal.onWritePty;
  terminal.onWritePty = (data) {
    output.addAll(data);
    onWrite?.call();
  };
  try {
    body();
  } finally {
    if (!terminal.isDisposed) terminal.onWritePty = previous;
  }
  return output;
}

/// What [terminal] writes to the pty while [text] is written to it, one
/// character per byte.
String ptyReply(VtTerminal terminal, String text) =>
    latin1.decode(capturePty(terminal, () => writeText(terminal, text)));

/// Runs [body] in a zone that collects uncaught errors and returns them.
///
/// Callbacks report their errors to the zone they were set in, so set them
/// inside [body] and check the list after triggering them.
List<Object> errorsDuring(void Function() body) {
  final errors = <Object>[];
  runZonedGuarded(body, (error, _) => errors.add(error));
  return errors;
}
