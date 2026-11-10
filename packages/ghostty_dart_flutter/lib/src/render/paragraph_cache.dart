import 'dart:ui' as ui;

/// The key of one cached paragraph: its text, its colour (ARGB) and its
/// face flags (`TextFace`). Never exported.
typedef ParagraphKey = (String text, int color, int faces);

/// A laid-out paragraph and whether it keeps the grid. Never exported.
final class CachedParagraph {
  /// Wraps [paragraph]; see [onGrid].
  const CachedParagraph(this.paragraph, {required this.onGrid});

  /// The laid-out paragraph. Valid until it leaves the cache.
  final ui.Paragraph paragraph;

  /// For a letter-spaced run: whether it measured exactly one cell width
  /// per character (within half a device pixel), so it can be drawn as one
  /// paragraph. `false` means a glyph came from a font with another
  /// advance (a fallback font, a zero-width format character) and the run
  /// must be drawn cell by cell. Always `true` for single clusters.
  final bool onGrid;
}

/// A least-recently-used cache of laid-out paragraphs of single style runs
/// and clusters (ADR 0011). Never exported.
///
/// Laying a paragraph out is the expensive part of drawing text; drawing a
/// cached one is cheap. Paragraphs are native objects, so every paragraph
/// that leaves the cache (evicted, or [clear]ed) is disposed at once instead
/// of waiting for the garbage collector.
///
/// Disposing a paragraph that was already drawn into a [ui.Picture] is
/// safe: drawing copies the glyph runs into the picture's display list
/// (engine `lib/ui/text/paragraph.cc`, `Paragraph::paint`, Flutter 3.47.9),
/// so the picture does not keep the paragraph alive.
class ParagraphCache {
  /// A cache that keeps at most [capacity] paragraphs and about
  /// [maxBytes] of them (see [estimatedBytes]).
  ParagraphCache({this.capacity = defaultCapacity, int? maxBytes})
    : assert(capacity > 0, 'capacity must be positive'),
      maxBytes = maxBytes ?? defaultMaxBytes;

  /// The default entry limit. Rows with two or more runs are laid out as
  /// one paragraph and kept as pictures (see `RowRecorder.record`), so this
  /// cache holds single-run rows, clusters and the cursor's glyph; the byte
  /// budget ([maxBytes]) usually binds first.
  static const defaultCapacity = 1024;

  /// The largest number of paragraphs kept.
  final int capacity;

  /// The default byte budget: 4 MiB.
  static const defaultMaxBytes = 4 << 20;

  /// About how many bytes of paragraphs are kept. Lowering it takes effect
  /// on the next miss, or at once with [trim].
  int maxBytes;

  /// A rough size of the paragraph of [text]: an 8-character run measured
  /// about 9 KiB of RSS (2026-11-10, Linux, Impeller), and the size grows
  /// with the text. An estimate, used only for the budget.
  static int estimatedBytes(String text) => 4096 + 640 * text.length;

  int _bytes = 0;

  /// The estimated bytes of the cached paragraphs ([estimatedBytes]).
  int get bytes => _bytes;

  // A map literal is a LinkedHashMap, which iterates in insertion order;
  // re-inserting on every hit keeps the least recently used entry first.
  final _entries = <ParagraphKey, CachedParagraph>{};

  int _hits = 0;
  int _misses = 0;

  /// The number of cached paragraphs.
  int get length => _entries.length;

  /// Lookups that found a cached paragraph, since creation or [clear].
  int get hits => _hits;

  /// Lookups that had to build a paragraph, since creation or [clear].
  int get misses => _misses;

  /// The paragraph for [key], from the cache or built (and laid out) by
  /// [build] and cached. The returned paragraph stays valid until the next
  /// call or [clear]: draw it at once, never keep it.
  CachedParagraph get(ParagraphKey key, CachedParagraph Function() build) {
    final cached = _entries.remove(key);
    if (cached != null) {
      _hits++;
      _entries[key] = cached;
      return cached;
    }
    _misses++;
    final built = build();
    final size = estimatedBytes(key.$1);
    // Evict before inserting, so the paragraph just built never goes first.
    while (_entries.isNotEmpty &&
        (_entries.length >= capacity || _bytes + size > maxBytes)) {
      _evictOldest();
    }
    _entries[key] = built;
    _bytes += size;
    return built;
  }

  /// Evicts the least recently used paragraphs until the cache fits
  /// [maxBytes].
  void trim() {
    while (_entries.isNotEmpty && _bytes > maxBytes) {
      _evictOldest();
    }
  }

  void _evictOldest() {
    final oldest = _entries.keys.first;
    _entries.remove(oldest)!.paragraph.dispose();
    _bytes -= estimatedBytes(oldest.$1);
  }

  /// Disposes every cached paragraph and resets the counters.
  void clear() {
    for (final entry in _entries.values) {
      entry.paragraph.dispose();
    }
    _entries.clear();
    _bytes = 0;
    _hits = 0;
    _misses = 0;
  }
}
