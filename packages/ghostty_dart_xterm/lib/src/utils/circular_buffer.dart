// Ported from package:xterm 4.0.0 (lib/src/utils/circular_buffer.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.
// Changed: a read-only view of lines that libghostty-vt stores, not a
// circular buffer: no mutators, and [IndexedItem.attached] turns false once
// the terminal changes (a line is a snapshot of one moment, ADR 0013).

/// The lines of a `Buffer` (`Terminal.lines`, `Buffer.lines`), read-only:
/// [length], `[]`, [forEach] and [toList], as xterm's circular buffer.
///
/// The terminal keeps its lines in libghostty-vt. Each line read through
/// this view is a snapshot made on first access and reused until the
/// terminal changes (a write, a resize, a scroll); read it again after
/// that.
class IndexAwareCircularBuffer<T extends IndexedItem> {
  /// Creates a view of the lines [source] provides.
  IndexAwareCircularBuffer(this._source);

  final IndexedItemSource<T> _source;

  /// The most lines the buffer keeps: the terminal's `maxLines`.
  int get maxLength => _source.maxLength;

  /// The number of lines, scrollback included.
  int get length => _source.length;

  /// Whether the scrollback is full (more output drops its oldest lines).
  bool get isFull => length >= maxLength;

  /// Calls [callback] with each line, oldest first.
  void forEach(void Function(T item) callback) {
    final length = this.length;
    for (var i = 0; i < length; i++) {
      callback(_source.itemAt(i));
    }
  }

  /// The line at [index] (0 is the oldest scrollback line). Throws
  /// [RangeError] when [index] is out of bounds.
  T operator [](int index) {
    RangeError.checkValueInInterval(index, 0, length - 1, 'index');
    return _source.itemAt(index);
  }

  /// Every line, oldest first, in a new list.
  List<T> toList() {
    return List<T>.generate(length, (index) => this[index]);
  }
}

/// Provides the lines of an [IndexAwareCircularBuffer].
abstract interface class IndexedItemSource<T> {
  /// The most lines the buffer keeps.
  int get maxLength;

  /// The number of lines.
  int get length;

  /// The line at [index], which is in bounds.
  T itemAt(int index);
}

/// Owns [IndexedItem]s and says whether they are still current.
abstract interface class IndexedItemOwner {
  /// Whether items attached at [epoch] still show the terminal.
  bool isCurrent(int epoch);
}

/// An item (a `BufferLine`) that knows its position in its buffer.
mixin IndexedItem {
  IndexedItemOwner? _owner;

  int _index = 0;

  int _epoch = 0;

  /// The index of this item in the buffer (0 is the oldest scrollback
  /// line). Must only be accessed when [attached] is true; throws
  /// [StateError] otherwise.
  int get index {
    if (!attached) {
      throw StateError('the line is not attached to a buffer');
    }
    return _index;
  }

  /// Whether this item is currently stored in a buffer: a line read from a
  /// terminal stays attached until the terminal changes.
  bool get attached => _owner?.isCurrent(_epoch) ?? false;
}

/// Attaches [item] to [owner] at [index] for [epoch].
void attachIndexedItem(
  IndexedItem item,
  IndexedItemOwner owner,
  int index,
  int epoch,
) {
  item
    .._owner = owner
    .._index = index
    .._epoch = epoch;
}

/// The owner [item] was attached to, current or not.
IndexedItemOwner? indexedItemOwner(IndexedItem item) => item._owner;
