import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../controller/terminal_controller.dart';

/// The accessibility layer of the view (ADR 0011, "Accessibility (v1)"):
/// one semantics node whose value is the visible text, plus optional
/// announcements of new output. Never exported.
///
/// Nothing is computed while the platform has no accessibility service
/// running ([SemanticsBinding.semanticsEnabled] is false): the widget does
/// not even listen to [controller] then. While it is on, the visible text
/// is read again at most once per [updateInterval], on controller
/// notifications. With [announceOutput], the lines that are new since the
/// last update are sent with [SemanticsService.sendAnnouncement] at the
/// same rate, at most [maxAnnouncementLength] characters (the newest
/// ones).
class TerminalSemantics extends StatefulWidget {
  /// Semantics for [child], the view of [controller].
  const TerminalSemantics({
    super.key,
    required this.controller,
    required this.label,
    required this.readOnly,
    required this.announceOutput,
    required this.child,
    this.onTap,
  });

  /// The shortest time between two reads of the visible text (and two
  /// announcements).
  static const updateInterval = Duration(milliseconds: 500);

  /// The longest announcement, in UTF-16 code units; longer output is cut
  /// at the start, so the newest lines are read.
  static const maxAnnouncementLength = 1000;

  /// The terminal whose visible text is exposed.
  final VtTerminalController controller;

  /// The node's label (what the screen reader calls the view).
  final String label;

  /// Whether the view takes no input (the node's read-only flag).
  final bool readOnly;

  /// Whether new output is announced.
  final bool announceOutput;

  /// The semantics tap action (focus and show the keyboard).
  final VoidCallback? onTap;

  /// The view.
  final Widget child;

  @override
  State<TerminalSemantics> createState() => _TerminalSemanticsState();
}

class _TerminalSemanticsState extends State<TerminalSemantics> {
  bool _enabled = false;
  bool _initialized = false;
  bool _listening = false;
  bool _dirty = false;
  Timer? _timer;
  TerminalFormatter? _formatter;
  VtTerminalController? _formatterOwner;
  String _text = '';
  List<String> _lines = const [];

  @override
  void initState() {
    super.initState();
    SemanticsBinding.instance.addSemanticsEnabledListener(_onEnabledChanged);
    _enabled = SemanticsBinding.instance.semanticsEnabled;
    if (_enabled) _start();
    _initialized = true;
  }

  @override
  void didUpdateWidget(TerminalSemantics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _stop(oldWidget.controller);
      _lines = const [];
      _text = '';
      if (_enabled) _start();
    }
  }

  @override
  void dispose() {
    SemanticsBinding.instance.removeSemanticsEnabledListener(_onEnabledChanged);
    _stop(widget.controller);
    super.dispose();
  }

  void _onEnabledChanged() {
    final enabled = SemanticsBinding.instance.semanticsEnabled;
    if (enabled == _enabled) return;
    setState(() => _enabled = enabled);
    if (enabled) {
      _start();
    } else {
      _stop(widget.controller);
      _lines = const [];
      _text = '';
    }
  }

  void _start() {
    if (widget.controller.isDisposed) return;
    widget.controller.addListener(_onOutput);
    _listening = true;
    // The first read is not an announcement: it is what was already there.
    _read(announce: false);
  }

  void _stop(VtTerminalController controller) {
    if (_listening) controller.removeListener(_onOutput);
    _listening = false;
    _timer?.cancel();
    _timer = null;
    _dirty = false;
    // Disposing the terminal disposed its formatter already.
    final owner = _formatterOwner;
    if (owner != null && !owner.isDisposed) _formatter?.dispose();
    _formatter = null;
    _formatterOwner = null;
  }

  void _onOutput() {
    _dirty = true;
    _timer ??= Timer(TerminalSemantics.updateInterval, _onTimer);
  }

  void _onTimer() {
    _timer = null;
    if (!mounted || !_dirty) return;
    _read(announce: widget.announceOutput);
  }

  void _read({required bool announce}) {
    _dirty = false;
    final controller = widget.controller;
    if (controller.isDisposed) return;
    final lines = visibleLines(controller, _formatterFor(controller));
    final text = lines.join('\n').trimRight();
    if (announce) {
      final message = newOutput(_lines, lines);
      if (message.isNotEmpty) _announce(message);
    }
    _lines = lines;
    if (text == _text) return;
    // No setState before the first build (initState).
    if (_initialized) {
      setState(() => _text = text);
    } else {
      _text = text;
    }
  }

  TerminalFormatter _formatterFor(VtTerminalController controller) {
    if (!identical(_formatterOwner, controller)) {
      _formatter = TerminalFormatter(controller.terminal);
      _formatterOwner = controller;
    }
    return _formatter!;
  }

  void _announce(String message) {
    final view = View.maybeOf(context);
    if (view == null) return;
    final cut = message.length > TerminalSemantics.maxAnnouncementLength
        ? message.substring(
            message.length - TerminalSemantics.maxAnnouncementLength,
          )
        : message;
    unawaited(
      SemanticsService.sendAnnouncement(
        view,
        cut,
        Directionality.maybeOf(context) ?? TextDirection.ltr,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Always the same widget, so turning accessibility on or off never
    // remounts the view below (pointer state, row pictures). While it is
    // off the annotations carry nothing and cost nothing: there is no
    // semantics owner to read them.
    if (!_enabled) return Semantics(child: widget.child);
    return Semantics(
      container: true,
      label: widget.label,
      value: _text,
      multiline: true,
      readOnly: widget.readOnly,
      onTap: widget.onTap,
      child: widget.child,
    );
  }
}

/// The viewport's rows of [controller]'s terminal as plain text, one
/// string per row, trailing blanks trimmed. Never exported.
@visibleForTesting
List<String> visibleLines(
  VtTerminalController controller,
  TerminalFormatter formatter,
) {
  final vt = controller.terminal;
  final selection = vt.selectRange(
    const GridPoint.viewport(0, 0),
    GridPoint.viewport(vt.cols - 1, vt.rows - 1),
  );
  if (selection == null) return List.filled(vt.rows, '');
  final lines = formatter
      .formatText(selection: selection)
      .split('\n')
      .map((line) => line.trimRight())
      .toList();
  // The formatter drops trailing blank rows; keep one string per row.
  while (lines.length < vt.rows) {
    lines.add('');
  }
  return lines;
}

/// The lines of [after] that are new compared with [before], two
/// snapshots of the viewport, joined with newlines. Never exported.
///
/// Output usually scrolls the screen up: [after] is [before] moved up by
/// some rows, with new rows at the bottom and the cursor row changed. The
/// shift that keeps the most non-blank rows equal is taken as that move
/// (the smallest one on a tie), and every non-blank row of [after] that
/// does not match the row it came from is new.
@visibleForTesting
String newOutput(List<String> before, List<String> after) {
  if (before.isEmpty) {
    return after.where((l) => l.isNotEmpty).join('\n');
  }
  var bestShift = 0;
  var bestMatches = -1;
  for (var shift = 0; shift < before.length; shift++) {
    var matches = 0;
    for (var i = 0; i + shift < before.length && i < after.length; i++) {
      if (after[i].isNotEmpty && after[i] == before[i + shift]) matches++;
    }
    if (matches > bestMatches) {
      bestMatches = matches;
      bestShift = shift;
    }
  }
  final fresh = <String>[];
  for (var i = 0; i < after.length; i++) {
    final line = after[i];
    if (line.isEmpty) continue;
    final from = i + bestShift;
    if (from < before.length && before[from] == line) continue;
    fresh.add(line);
  }
  return fresh.join('\n');
}
