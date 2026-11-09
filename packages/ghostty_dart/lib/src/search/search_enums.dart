/// The enums of `search.h` and their raw-value codecs.
///
/// Pure Dart: no `dart:ffi`, so a future web backend can reuse it.
library;

import '../core/enum_codec.dart';

/// How far a `TerminalSearch` has got (`GhosttySearchStatus`).
enum SearchStatus {
  /// More work is ready: call `TerminalSearch.tick` (or `step`).
  running(0),

  /// The search needs to read the terminal: call `TerminalSearch.feed`
  /// (or `step`). Also the state right after a needle is set.
  feedRequired(1),

  /// Caught up with the terminal as of the last feed, or idle without a
  /// needle. Later terminal output needs another feed to be searched.
  complete(2),

  /// A status added by a later libghostty-vt release.
  unknown(null);

  const SearchStatus(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttySearchStatus` values to [SearchStatus] and back.
final searchStatusCodec = RawEnumCodec<SearchStatus>(
  SearchStatus.values,
  raw: (v) => v._raw,
  unknown: SearchStatus.unknown,
);

/// Whether selecting a match scrolls the viewport to it
/// (`GhosttySearchScroll`).
enum SearchScroll {
  /// Scroll only when the match is not already visible (the default).
  ifNeeded(0),

  /// Never scroll.
  none(1),

  /// A policy added by a later libghostty-vt release.
  unknown(null);

  const SearchScroll(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttySearchScroll` values to [SearchScroll] and back.
final searchScrollCodec = RawEnumCodec<SearchScroll>(
  SearchScroll.values,
  raw: (v) => v._raw,
  unknown: SearchScroll.unknown,
);
