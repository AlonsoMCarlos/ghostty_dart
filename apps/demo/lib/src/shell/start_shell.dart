// Picks the shell for the platform at compile time: flutter_pty needs
// dart:io and dart:ffi, so the web build only ever sees the fake shell.
export 'start_shell_fake.dart' if (dart.library.io) 'start_shell_native.dart';
