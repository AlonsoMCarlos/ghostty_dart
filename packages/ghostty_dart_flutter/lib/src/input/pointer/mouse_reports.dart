import 'package:ghostty_dart/ghostty_dart.dart';

import '../../seams/terminal_seams.dart';
import '../input_hooks.dart';

/// The view's mouse report hooks (`VtTerminalView.mouseReportFilter` and
/// `onTerminalMouse`), shared by the pointer layer and the scroll router.
/// Never exported.
///
/// Without hooks ([none]) every report is allowed and encoded, exactly as
/// before the hooks existed.
final class MouseReports {
  /// Reports that consult [filter] and go through [hook]; a string from
  /// [hook] is sent with [text].
  const MouseReports({this.filter, this.hook, this.text});

  /// No hooks: every report is allowed and encoded.
  static const none = MouseReports();

  /// Whether a report is sent at all; `null` allows every report.
  final VtTerminalMouseFilter? filter;

  /// Replaces the encoding of a report; `null` always encodes.
  final VtTerminalMouseHook? hook;

  /// Where a string returned by [hook] goes.
  final TerminalTextSink? text;

  /// Whether [event] (a press, a wheel step or motion) may be reported.
  /// Never asked for the release of a reported press.
  bool allows(VtMouseEvent event) => filter?.call(event) ?? true;

  /// Reports [event], over the viewport [cell], through [hook] or, when it
  /// has none or returns `null`, through [pointer]'s encoder.
  void send(TerminalPointerSink pointer, VtMouseEvent event, GridPoint cell) {
    final hook = this.hook;
    if (hook != null) {
      final replacement = hook(event, cell);
      if (replacement != null) {
        final text = this.text;
        if (replacement.isNotEmpty && text != null && !text.isDisposed) {
          text.sendText(replacement);
        }
        return;
      }
    }
    pointer.sendMouse(event);
  }
}
