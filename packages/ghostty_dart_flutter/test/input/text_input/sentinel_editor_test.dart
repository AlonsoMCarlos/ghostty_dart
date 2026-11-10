import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/src/input/text_input/sentinel_editor.dart';

TextEditingValue _value(String text, {TextRange composing = TextRange.empty}) =>
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: composing,
    );

void main() {
  late SentinelEditor editor;
  setUp(() => editor = SentinelEditor()..reset());

  test('starts at the sentinel with the caret at its end', () {
    expect(editor.value.text, '  ');
    expect(editor.value.selection, const TextSelection.collapsed(offset: 2));
    expect(editor.needsReset, isFalse);
  });

  test('typed text is committed and the state asks for a reset', () {
    expect(editor.update(_value('  ab')), const SentinelEdit(text: 'ab'));
    expect(editor.needsReset, isTrue);
    editor.reset();
    expect(editor.update(_value('  c')), const SentinelEdit(text: 'c'));
  });

  test('deleting the sentinel is one Backspace per character', () {
    expect(editor.update(_value(' ')), const SentinelEdit(backspaces: 1));
    editor.reset();
    expect(editor.update(_value('')), const SentinelEdit(backspaces: 2));
  });

  test('a deleted emoji or cluster is one Backspace', () {
    editor.update(_value('  👍🏽'));
    expect(editor.update(_value('  ')), const SentinelEdit(backspaces: 1));
  });

  test('soft-keyboard newlines become carriage returns', () {
    expect(editor.update(_value('  ls\n')), const SentinelEdit(text: 'ls\r'));
  });

  test('the composing region sends nothing until it is committed', () {
    expect(
      editor.update(
        _value('  に', composing: const TextRange(start: 2, end: 3)),
      ),
      const SentinelEdit(),
    );
    expect(editor.isComposing, isTrue);
    expect(editor.composingText, 'に');
    expect(editor.needsReset, isFalse);
    expect(
      editor.update(
        _value('  にほ', composing: const TextRange(start: 2, end: 4)),
      ),
      const SentinelEdit(),
    );
    // The IME replaces the preedit with the conversion and commits it.
    expect(editor.update(_value('  日本')), const SentinelEdit(text: '日本'));
    expect(editor.isComposing, isFalse);
  });

  test('a composing region that collapses commits its text (Android)', () {
    editor.update(
      _value('  hel', composing: const TextRange(start: 2, end: 5)),
    );
    expect(editor.update(_value('  hel')), const SentinelEdit(text: 'hel'));
  });

  test('a composition cancelled with Backspace sends nothing', () {
    editor.update(_value('  a', composing: const TextRange(start: 2, end: 3)));
    expect(editor.update(_value('  ')), const SentinelEdit());
  });

  test('deltas are applied to the current value', () {
    final edit = editor.applyDeltas([
      const TextEditingDeltaInsertion(
        oldText: '  ',
        textInserted: 'é',
        insertionOffset: 2,
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ),
    ]);
    expect(edit, [const SentinelEdit(text: 'é')]);
    editor.reset();
    expect(
      editor.applyDeltas([
        const TextEditingDeltaDeletion(
          oldText: '  ',
          deletedRange: TextRange(start: 0, end: 2),
          selection: TextSelection.collapsed(offset: 0),
          composing: TextRange.empty,
        ),
      ]),
      [const SentinelEdit(backspaces: 2)],
    );
  });

  test('a delta sent before the reset reached the platform counts once', () {
    // "a" was committed and the editor reset to the sentinel, but the
    // platform typed "b" on top of "  a" before it saw the reset.
    editor.applyDeltas([
      const TextEditingDeltaInsertion(
        oldText: '  ',
        textInserted: 'a',
        insertionOffset: 2,
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ),
    ]);
    editor.reset();
    expect(
      editor.applyDeltas([
        const TextEditingDeltaInsertion(
          oldText: '  a',
          textInserted: 'b',
          insertionOffset: 3,
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange.empty,
        ),
      ]),
      [const SentinelEdit(text: 'b')],
    );
  });

  test('delta composition: preedit, then replacement commits', () {
    expect(
      editor.applyDeltas([
        const TextEditingDeltaInsertion(
          oldText: '  ',
          textInserted: 'に',
          insertionOffset: 2,
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 2, end: 3),
        ),
      ]),
      isEmpty,
    );
    expect(editor.composingText, 'に');
    expect(
      editor.applyDeltas([
        const TextEditingDeltaReplacement(
          oldText: '  に',
          replacementText: '日本',
          replacedRange: TextRange(start: 2, end: 3),
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange.empty,
        ),
      ]),
      [const SentinelEdit(text: '日本')],
    );
  });

  test('delta composition ended by an insertion commits both, in order', () {
    editor.applyDeltas([
      const TextEditingDeltaInsertion(
        oldText: '  ',
        textInserted: 'hel',
        insertionOffset: 2,
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 2, end: 5),
      ),
    ]);
    expect(
      editor.applyDeltas([
        const TextEditingDeltaNonTextUpdate(
          oldText: '  hel',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange.empty,
        ),
        const TextEditingDeltaInsertion(
          oldText: '  hel',
          textInserted: ' ',
          insertionOffset: 5,
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange.empty,
        ),
      ]),
      [const SentinelEdit(text: 'hel'), const SentinelEdit(text: ' ')],
    );
  });

  test('a replacement outside the preedit is Backspaces then text', () {
    expect(
      editor.applyDeltas([
        const TextEditingDeltaReplacement(
          oldText: '  ',
          replacementText: 'xy',
          replacedRange: TextRange(start: 1, end: 2),
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange.empty,
        ),
      ]),
      [const SentinelEdit(backspaces: 1), const SentinelEdit(text: 'xy')],
    );
  });

  test('whole value: a caret move with an insertion sends no Backspace', () {
    expect(
      editor.update(
        const TextEditingValue(
          text: 'x  ',
          selection: TextSelection.collapsed(offset: 1),
        ),
      ),
      const SentinelEdit(text: 'x'),
    );
  });

  test('an empty sentinel turns Backspace detection off', () {
    final bare = SentinelEditor(sentinel: '')..reset();
    expect(bare.update(_value('x')), const SentinelEdit(text: 'x'));
    bare.reset();
    expect(bare.update(_value('')), const SentinelEdit());
  });
}
