/// The ghostty_dart_flutter demo: a terminal connected to your shell on
/// desktop platforms, and to a fake shell written in Dart on the web.
///
/// ```sh
/// mise run demo:run           # Linux desktop, your $SHELL
/// mise run demo:run --fake    # the web's fake shell (DEMO_SHELL=fake)
/// ```
library;

import 'package:flutter/widgets.dart';

import 'src/demo_app.dart';
import 'src/shell/start_shell.dart';

void main() => runApp(const DemoApp(startShell: startDefaultShell));
