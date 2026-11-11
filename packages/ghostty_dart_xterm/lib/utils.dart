/// The counterpart of `package:xterm/utils.dart`, which holds xterm's
/// escape-sequence debugger (`TerminalDebugger`, `TerminalDebuggerView`).
///
/// The debugger is built on xterm's Dart parser, which this package does
/// not have (parsing lives in libghostty-vt, ADR 0004), so it is not
/// provided; the library exists so that an import of it keeps compiling.
library;
