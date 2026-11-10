import 'package:flutter/widgets.dart';

/// The IME preedit drawn in place at the cursor cell, underlined, in the
/// grid's font (ADR 0011, Input). It is not part of the terminal: nothing
/// is sent until the IME commits. Never exported.
///
/// Positioned inside the input layer's `Stack`; it ignores pointers and is
/// clipped by the view.
class ComposingOverlay extends StatelessWidget {
  /// Shows [text] with its top-left at [origin] (local coordinates).
  const ComposingOverlay({
    super.key,
    required this.text,
    required this.origin,
    this.style,
    this.backgroundColor,
  });

  /// The preedit text.
  final String text;

  /// The top-left corner of the cursor cell.
  final Offset origin;

  /// The grid's font; the ambient [DefaultTextStyle] when `null`.
  final TextStyle? style;

  /// The fill behind the text, or none.
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    final textWidget = Text(
      text,
      key: const ValueKey('ghostty_dart_flutter.composing'),
      style: base.copyWith(
        decoration: TextDecoration.underline,
        decorationColor: base.color,
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
    );
    return Positioned(
      left: origin.dx,
      top: origin.dy,
      child: IgnorePointer(
        child: backgroundColor == null
            ? textWidget
            : ColoredBox(color: backgroundColor!, child: textWidget),
      ),
    );
  }
}
