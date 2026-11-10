import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The idle text of the hidden editing state when Backspace detection is
/// on: two spaces with the caret after them, as xterm.dart's
/// `deleteDetection` (`lib/src/ui/custom_text_edit.dart`, `_initEditingState`,
/// xterm 4.0.0). Never exported.
///
/// Many Android keyboards send nothing for Backspace on an empty field
/// (https://github.com/TerminalStudio/xterm.dart/issues/201), so there must
/// always be something to delete. Two characters also bound how many
/// Backspaces one `deleteSurroundingText` can produce.
const deleteDetectionSentinel = '  ';

/// What the terminal should receive for one editing step: [backspaces]
/// Backspace presses, then [text]. Never exported.
@immutable
final class SentinelEdit {
  /// [backspaces] Backspace presses, then [text] (possibly empty).
  const SentinelEdit({this.backspaces = 0, this.text = ''});

  /// How many characters (grapheme clusters) were deleted.
  final int backspaces;

  /// The committed text to send, with soft-keyboard newlines as `\r`.
  final String text;

  /// Whether there is nothing to send.
  bool get isEmpty => backspaces == 0 && text.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is SentinelEdit &&
      other.backspaces == backspaces &&
      other.text == text;

  @override
  int get hashCode => Object.hash(backspaces, text);

  @override
  String toString() => 'SentinelEdit(backspaces: $backspaces, text: $text)';
}

/// The hidden editing state behind the terminal's text input (ADR 0011,
/// Input). Never exported.
///
/// A terminal has no text to edit, but soft keyboards and IMEs need one, so
/// the state idles at [sentinel] with the caret after it (see
/// [deleteDetectionSentinel]). The composing region is the IME's preedit:
/// it sends nothing until the IME commits it.
///
/// - **Delta updates** ([applyDeltas]) are turned into edits from the
///   deltas themselves: inserted text is committed, deleted text becomes
///   one Backspace per grapheme, a replacement is both, and a composing
///   region that ends is committed. Deltas carry their own `oldText`, so a
///   delta the platform sent before our reset to the sentinel reached it
///   still yields exactly its own change.
/// - **Whole-value updates** ([update], platforms without the delta model)
///   are diffed against the last state outside the composing region, by
///   common prefix and suffix.
///
/// Soft-keyboard `\n` (and `\r\n`) becomes `\r`. Once nothing is composing,
/// the owner resets the platform to [idleValue] ([needsReset]).
final class SentinelEditor {
  /// An editor idling at [sentinel]; empty turns Backspace detection off.
  SentinelEditor({this.sentinel = deleteDetectionSentinel})
    : _value = _idle(sentinel);

  /// The idle text.
  final String sentinel;

  TextEditingValue _value;

  static TextEditingValue _idle(String sentinel) => TextEditingValue(
    text: sentinel,
    selection: TextSelection.collapsed(offset: sentinel.length),
  );

  /// The idle editing value: the sentinel, caret at its end.
  TextEditingValue get idleValue => _idle(sentinel);

  /// The editing state as the platform last reported it.
  TextEditingValue get value => _value;

  /// Whether the IME is composing (the composing region is not empty).
  bool get isComposing => _isComposing(_value);

  /// The text being composed (the IME preedit), or `''`.
  String get composingText =>
      isComposing ? _value.composing.textInside(_value.text) : '';

  /// Whether the state differs from [idleValue] while nothing is
  /// composing, so the platform must be reset to it.
  bool get needsReset => !isComposing && _value != idleValue;

  static bool _isComposing(TextEditingValue value) =>
      value.composing.isValid &&
      !value.composing.isCollapsed &&
      value.composing.end <= value.text.length;

  /// Back to the idle state, for a new connection or after [needsReset].
  void reset() => _value = idleValue;

  /// Applies the platform's [deltas] and returns what to send, in order.
  List<SentinelEdit> applyDeltas(List<TextEditingDelta> deltas) {
    final edits = <SentinelEdit>[];
    void commit(String text) {
      if (text.isNotEmpty) edits.add(SentinelEdit(text: _crlf(text)));
    }

    void delete(String text) {
      final count = text.characters.length;
      if (count > 0) edits.add(SentinelEdit(backspaces: count));
    }

    for (final delta in deltas) {
      final oldText = delta.oldText;
      // Our composing region applies only if the delta starts from the
      // state we know; a stale delta did not see it.
      final oldComposing = _value.text == oldText && _isComposing(_value)
          ? _value.composing
          : TextRange.empty;
      final preedit = oldComposing.isCollapsed || !oldComposing.isValid
          ? ''
          : oldComposing.textInside(oldText);
      final next = _applied(delta);
      final composing = _isComposing(next);

      // The preedit with [range] (in old-text coordinates, inside it)
      // replaced by [text].
      String preeditWith(TextRange range, String text) =>
          preedit.substring(0, range.start - oldComposing.start) +
          text +
          preedit.substring(range.end - oldComposing.start);

      switch (delta) {
        case TextEditingDeltaNonTextUpdate():
          // Android's finishComposingText: the preedit stays as text.
          if (!composing) commit(preedit);
        case TextEditingDeltaInsertion(
          :final textInserted,
          :final insertionOffset,
        ):
          if (composing) break; // the preedit grows
          final at = TextRange.collapsed(insertionOffset);
          if (preedit.isNotEmpty && _within(oldComposing, at)) {
            commit(preeditWith(at, textInserted));
          } else {
            commit(preedit);
            commit(textInserted);
          }
        case TextEditingDeltaDeletion(:final deletedRange):
          if (composing) break; // the preedit shrinks
          if (preedit.isNotEmpty && _within(oldComposing, deletedRange)) {
            commit(preeditWith(deletedRange, ''));
          } else {
            commit(preedit);
            delete(deletedRange.textInside(oldText));
          }
        case TextEditingDeltaReplacement(
          :final replacedRange,
          :final replacementText,
        ):
          final inPreedit =
              preedit.isNotEmpty && _within(oldComposing, replacedRange);
          if (composing) {
            // A new preedit over text that was already sent replaces it.
            if (!inPreedit) delete(replacedRange.textInside(oldText));
            break;
          }
          if (inPreedit) {
            commit(preeditWith(replacedRange, replacementText));
          } else {
            commit(preedit);
            delete(replacedRange.textInside(oldText));
            commit(replacementText);
          }
      }
      _value = next;
    }
    return edits;
  }

  /// Takes [next] as the platform's new state (no delta model) and returns
  /// what to send.
  SentinelEdit update(TextEditingValue next) {
    final before = _settledText(_value);
    final after = _settledText(next);
    _value = next;
    if (before == after) return const SentinelEdit();
    var prefix = 0;
    final shorter = before.length < after.length ? before.length : after.length;
    while (prefix < shorter &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    // Back off to a character boundary of the old text, so a surrogate
    // pair or a grapheme cluster is deleted as one Backspace.
    var start = 0;
    for (final character in before.characters) {
      if (start + character.length > prefix) break;
      start += character.length;
    }
    var suffix = 0;
    while (suffix < before.length - start &&
        suffix < after.length - start &&
        before.codeUnitAt(before.length - 1 - suffix) ==
            after.codeUnitAt(after.length - 1 - suffix)) {
      suffix++;
    }
    final removed = before.substring(start, before.length - suffix);
    final added = after.substring(start, after.length - suffix);
    return SentinelEdit(
      backspaces: removed.characters.length,
      text: _crlf(added),
    );
  }

  /// Text outside the composing region.
  static String _settledText(TextEditingValue value) {
    if (!_isComposing(value)) return value.text;
    return value.composing.textBefore(value.text) +
        value.composing.textAfter(value.text);
  }

  static bool _within(TextRange outer, TextRange inner) =>
      inner.start >= outer.start && inner.end <= outer.end;

  static String _crlf(String text) =>
      text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');

  /// The value after [delta], computed on its own `oldText` (as
  /// [TextEditingDelta.apply] does, without its debug asserts), with the
  /// ranges clamped so a malformed delta cannot throw.
  static TextEditingValue _applied(TextEditingDelta delta) {
    final old = delta.oldText;
    int clamp(int offset) => offset.clamp(0, old.length);
    String replace(TextRange range, String text) =>
        old.substring(0, clamp(range.start)) +
        text +
        old.substring(clamp(range.end));
    final text = switch (delta) {
      TextEditingDeltaInsertion(:final textInserted, :final insertionOffset) =>
        replace(TextRange.collapsed(insertionOffset), textInserted),
      TextEditingDeltaDeletion(:final deletedRange) => replace(
        deletedRange,
        '',
      ),
      TextEditingDeltaReplacement(
        :final replacedRange,
        :final replacementText,
      ) =>
        replace(replacedRange, replacementText),
      _ => old,
    };
    return TextEditingValue(
      text: text,
      selection: delta.selection,
      composing: delta.composing.isValid && delta.composing.end <= text.length
          ? delta.composing
          : TextRange.empty,
    );
  }
}
