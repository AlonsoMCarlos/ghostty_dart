import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/src/render/paragraph_cache.dart';

class _FakeParagraph extends Fake implements ui.Paragraph {
  _FakeParagraph(this.name);

  final String name;
  bool disposed = false;

  @override
  void dispose() {
    expect(disposed, isFalse, reason: '$name disposed twice');
    disposed = true;
  }
}

void main() {
  test('returns the cached paragraph for an equal key', () {
    final cache = ParagraphCache(capacity: 4);
    final a = _FakeParagraph('a');
    expect(
      cache.get(('a', 1, 0), () => CachedParagraph(a, onGrid: true)).paragraph,
      same(a),
    );
    expect(cache.get(('a', 1, 0), () => fail('rebuilt')).paragraph, same(a));
    expect(cache.hits, 1);
    expect(cache.misses, 1);
  });

  test('colour and faces are part of the key', () {
    final cache = ParagraphCache(capacity: 4);
    cache
      ..get((
        'a',
        1,
        0,
      ), () => CachedParagraph(_FakeParagraph('a'), onGrid: true))
      ..get((
        'a',
        2,
        0,
      ), () => CachedParagraph(_FakeParagraph('a2'), onGrid: true))
      ..get((
        'a',
        1,
        1,
      ), () => CachedParagraph(_FakeParagraph('a bold'), onGrid: true));
    expect(cache.length, 3);
    expect(cache.misses, 3);
  });

  test('evicts the least recently used paragraph and disposes it', () {
    final cache = ParagraphCache(capacity: 2);
    final a = _FakeParagraph('a');
    final b = _FakeParagraph('b');
    final c = _FakeParagraph('c');
    cache
      ..get(('a', 0, 0), () => CachedParagraph(a, onGrid: true))
      ..get(('b', 0, 0), () => CachedParagraph(b, onGrid: true))
      ..get(('a', 0, 0), () => fail('a was evicted')) // a is now recent
      ..get(('c', 0, 0), () => CachedParagraph(c, onGrid: true));
    expect(b.disposed, isTrue);
    expect(a.disposed, isFalse);
    expect(c.disposed, isFalse);
    expect(cache.length, 2);
  });

  test('clear disposes everything and resets the counters', () {
    final cache = ParagraphCache(capacity: 4);
    final a = _FakeParagraph('a');
    final b = _FakeParagraph('b');
    cache
      ..get(('a', 0, 0), () => CachedParagraph(a, onGrid: true))
      ..get(('b', 0, 0), () => CachedParagraph(b, onGrid: true))
      ..get(('b', 0, 0), () => CachedParagraph(b, onGrid: true))
      ..clear();
    expect(a.disposed && b.disposed, isTrue);
    expect(cache.length, 0);
    expect(cache.hits, 0);
    expect(cache.misses, 0);
  });
}
