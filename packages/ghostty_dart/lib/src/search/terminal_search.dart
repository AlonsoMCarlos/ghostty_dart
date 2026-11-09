/// Searching terminal content (`search.h`): [TerminalSearch].
library;

import 'dart:ffi';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../selection/selection_native.dart'
    show checkNotInTerminalCallback, isLiveGridRef;
import '../selection/vt_selection.dart'
    show VtSelection, VtTerminalSelection, selectionFromNative;
import '../terminal/terminal.dart' show VtTerminal;
import 'search_enums.dart';

/// Finds a string in a terminal: the active area and the scrollback, of
/// the primary and the alternate screen (`GhosttySearch`).
///
/// For a one-off search, set the [needle] and [run]:
///
/// ```dart
/// final search = TerminalSearch(terminal, needle: 'error')..run();
/// print('${search.totalMatches} matches');
/// if (search.selectNext()) terminal.selection = search.selectedMatch;
/// search.dispose();
/// ```
///
/// A find bar over a long scrollback should not block on [run]. Drive the
/// search in small steps instead, e.g. one [step] per frame until the
/// [status] is [SearchStatus.complete], and [feed] again after the
/// terminal receives output so new content is searched too:
///
/// ```dart
/// search.needle = query;
/// while (search.step() != SearchStatus.complete) {
///   await Future<void>.delayed(Duration.zero); // let the UI run
/// }
/// ```
///
/// Matching is byte-exact except for ASCII letters, which match
/// case-insensitively. Matches are borrowed [VtSelection]s; they reflect
/// the terminal as of the last feed ([feed], [run], [step], [selectNext]
/// or [selectPrevious]), so they are stale (`isValid` is `false`) as soon
/// as the terminal changes after it. Feed again to get current ones. Every
/// match read ([selectedMatch], [matches], [viewportMatches]) is also
/// checked against the terminal's pages, because a running search can
/// report matches in scrollback the terminal has already evicted; those
/// come back stale too.
///
/// **Ownership:** a search belongs to the terminal given to its
/// constructor and keeps it reachable. Call [dispose] when done; disposing
/// the terminal disposes it first. A forgotten search is freed some time
/// after it is garbage collected (between event-loop turns). Members throw
/// [StateError] after [dispose] and when called from inside a callback of
/// the terminal.
final class TerminalSearch implements Finalizable {
  /// A search of [terminal], idle until a [needle] is set (here or later).
  ///
  /// Throws [StateError] if [terminal] is disposed, [UnsupportedError] if
  /// the library was built without search, and [GhosttyException] if it
  /// runs out of memory.
  TerminalSearch(VtTerminal terminal, {String? needle})
    : _terminal = terminal,
      _handle = _create(handleOf<GhosttyTerminalImpl>(terminal)) {
    bindHandle(this, _handle);
    final terminalHandle = _terminalHandle;
    terminalHandle.addDependent(_handle);
    _fedEpoch = terminalHandle.epoch;
    // Like a NativeFinalizer, the Dart one watches the handle; dispose()
    // detaches it through a cleanup. The locals keep `this` out of the
    // closure. The token holds the terminal handle, so the terminal cannot
    // be finalized (on another thread) while this search is being freed.
    final handle = _handle;
    _finalizer.attach(handle, (
      search: handle.pointer.address,
      terminal: terminalHandle,
    ), detach: handle);
    handle.addCleanup(() => _finalizer.detach(handle));
    if (needle != null) this.needle = needle;
  }

  static NativeHandle<GhosttySearchImpl> _create(
    NativeHandle<GhosttyTerminalImpl> terminal,
  ) {
    final pointer = createNative<GhosttySearchImpl>(
      'ghostty_search_new',
      (out) => ghostty_search_new(nullptr, out, terminal.pointer),
    );
    return NativeHandle(
      pointer,
      typeName: 'TerminalSearch',
      free: (p) => ghostty_search_free(p),
      finalizer: null,
    );
  }

  /// Frees a forgotten search on this isolate's event loop.
  ///
  /// Not a `NativeFinalizer`: while its terminal is alive,
  /// `ghostty_search_free` unregisters the search from it and releases the
  /// cells it tracks there, and a native finalizer may run on any thread
  /// while this isolate is inside a terminal call. A Dart [Finalizer] never
  /// runs while a terminal call is on the stack. (After the terminal is
  /// freed the search is detached and the free touches only its own
  /// memory.)
  static final _finalizer =
      Finalizer<({int search, NativeHandle<GhosttyTerminalImpl> terminal})>(
        (token) => ghostty_search_free(Pointer.fromAddress(token.search)),
      );

  /// Strong reference: the search reads the terminal.
  final VtTerminal _terminal;
  final NativeHandle<GhosttySearchImpl> _handle;

  /// The terminal epoch of the last feed: the results reflect the terminal
  /// as it was then.
  int _fedEpoch = 0;

  NativeHandle<GhosttyTerminalImpl> get _terminalHandle =>
      handleOf<GhosttyTerminalImpl>(_terminal);

  /// Whether [dispose] has been called (directly or by disposing the
  /// terminal).
  bool get isDisposed => _handle.isDisposed;

  /// The string searched for, or `null` when the search is idle.
  ///
  /// Setting a different needle restarts the search and drops all results
  /// (the status becomes [SearchStatus.feedRequired]); setting the same
  /// one again (ignoring ASCII case) keeps them, so a find bar can resubmit
  /// freely. `null` or `''` clears it.
  String? get needle => _read(
    'needle',
    GhosttySearchData.GHOSTTY_SEARCH_DATA_NEEDLE,
    sizeOf<GhosttyString>(),
    (out) => readGhosttyString(out.cast<GhosttyString>().ref),
  );

  set needle(String? value) {
    final search = _pointer('needle');
    const option = GhosttySearchOption.GHOSTTY_SEARCH_OPT_NEEDLE;
    if (value == null || value.isEmpty) {
      return _set(search, option, nullptr);
    }
    withUtf8(value, (data, length) {
      withScratch(sizeOf<GhosttyString>(), (out) {
        out.cast<GhosttyString>().ref
          ..ptr = data
          ..len = length;
        _set(search, option, out.cast());
      });
    });
  }

  /// How far the search has got.
  SearchStatus get status => searchStatusCodec.decode(
    _read(
      'status',
      GhosttySearchData.GHOSTTY_SEARCH_DATA_STATUS,
      sizeOf<UnsignedInt>(),
      (out) => out.cast<UnsignedInt>().value,
    )!,
  );

  /// Does a bounded amount of work on content already read from the
  /// terminal, and returns the new [status]. Call it while the status is
  /// [SearchStatus.running]; at [SearchStatus.feedRequired], [feed].
  SearchStatus tick() {
    final search = _pointer('tick');
    return withScratch(sizeOf<UnsignedInt>(), (out) {
      final status = out.cast<UnsignedInt>();
      checkResult(ghostty_search_tick(search, status), 'ghostty_search_tick');
      return searchStatusCodec.decode(status.value);
    });
  }

  /// Reads the terminal to catch up with it: searches the active area
  /// again, takes the next chunk of scrollback and drops matches whose
  /// content left the scrollback. A bounded amount of work.
  ///
  /// The search only sees terminal changes when fed, so keep feeding
  /// (e.g. after output) while it is in use, even once it is complete.
  void feed() {
    final search = _pointer('feed');
    checkResult(ghostty_search_feed(search), 'ghostty_search_feed');
    _fedEpoch = _terminalHandle.epoch;
  }

  /// One bounded step of an incremental search: [feed] if the search
  /// needs it, then [tick]. Returns the new [status]; repeat until it is
  /// [SearchStatus.complete].
  SearchStatus step() {
    if (status == SearchStatus.feedRequired) feed();
    return tick();
  }

  /// Searches until caught up with the terminal: feeds at least once (so
  /// it also picks up changes since the last feed) and works until the
  /// status is [SearchStatus.complete].
  ///
  /// Blocks for as long as that takes, which can be noticeable for a large
  /// scrollback; interactive callers should use [step].
  void run() {
    final search = _pointer('run');
    checkResult(ghostty_search_run(search), 'ghostty_search_run');
    _fedEpoch = _terminalHandle.epoch;
  }

  /// The number of matches found so far on the active screen.
  int get totalMatches => _read(
    'totalMatches',
    GhosttySearchData.GHOSTTY_SEARCH_DATA_TOTAL_MATCHES,
    sizeOf<Size>(),
    (out) => out.cast<Size>().value,
  )!;

  /// The index of the selected match in [matches] (0 is the newest), or
  /// `null` when none is selected. A find bar shows
  /// "`selectedIndex + 1` of [totalMatches]".
  int? get selectedIndex => _read(
    'selectedIndex',
    GhosttySearchData.GHOSTTY_SEARCH_DATA_SELECTED_INDEX,
    sizeOf<Size>(),
    (out) => out.cast<Size>().value,
  );

  /// The selected match, or `null` when none is selected. Highlight it by
  /// assigning it to [VtTerminalSelection.selection].
  VtSelection? get selectedMatch => _read(
    'selectedMatch',
    GhosttySearchData.GHOSTTY_SEARCH_DATA_SELECTED_MATCH,
    sizeOf<GhosttySelection>(),
    (out) => _match(out.cast<GhosttySelection>().ref),
  );

  /// Every match found on the active screen, newest first: from the bottom
  /// of the active area up through the scrollback. A new, unmodifiable
  /// list, indexed like [selectedIndex] and as long as [totalMatches].
  ///
  /// While a search is still running, output that evicts scrollback can
  /// leave matches on pages that no longer exist; those come back already
  /// stale (`isValid` is `false`) until the search completes and drops
  /// them. That check costs two walks of the terminal's page list per end
  /// of every match, so reading this list is O(matches × pages): prefer
  /// [viewportMatches] for drawing, and read [matches] once per feed.
  List<VtSelection> get matches =>
      _readMatches(GhosttySearchData.GHOSTTY_SEARCH_DATA_MATCHES);

  /// The matches on the pages that cover the viewport, for drawing
  /// highlights, as of the last feed. A new, unmodifiable list.
  ///
  /// Matches are found a page at a time, so the list may include matches
  /// just outside the viewport. Skip those whose
  /// `start.pointIn(PointSpace.viewport)` is `null`.
  List<VtSelection> get viewportMatches =>
      _readMatches(GhosttySearchData.GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES);

  /// Selects the next match toward older content (up from the bottom of
  /// the screen into the scrollback), wrapping from the oldest to the
  /// newest. Catches up with the terminal first, then scrolls the viewport
  /// to the match as [selectScroll] says. Returns `false` when there are
  /// no matches.
  ///
  /// Scrolling changes the terminal: earlier selections and grid
  /// references become stale.
  bool selectNext() => _select(
    'selectNext',
    'ghostty_search_select_next',
    ghostty_search_select_next,
  );

  /// Like [selectNext], toward newer content, wrapping from the newest to
  /// the oldest match.
  bool selectPrevious() => _select(
    'selectPrevious',
    'ghostty_search_select_prev',
    ghostty_search_select_prev,
  );

  /// Whether [selectNext] and [selectPrevious] scroll the viewport to the
  /// selected match; [SearchScroll.ifNeeded] by default.
  ///
  /// Throws [ArgumentError] when set to [SearchScroll.unknown].
  SearchScroll get selectScroll => searchScrollCodec.decode(
    _read(
      'selectScroll',
      GhosttySearchData.GHOSTTY_SEARCH_DATA_SELECT_SCROLL,
      sizeOf<UnsignedInt>(),
      (out) => out.cast<UnsignedInt>().value,
    )!,
  );

  set selectScroll(SearchScroll value) {
    final raw = searchScrollCodec.encode(value);
    final search = _pointer('selectScroll');
    withScratch(sizeOf<UnsignedInt>(), (out) {
      out.cast<UnsignedInt>().value = raw;
      _set(
        search,
        GhosttySearchOption.GHOSTTY_SEARCH_OPT_SELECT_SCROLL,
        out.cast(),
      );
    });
  }

  /// Frees the native search. Safe to call more than once.
  void dispose() => _handle.dispose();

  /// Runs a `select_next`/`select_prev` [call]. It feeds and may scroll
  /// the viewport, so the terminal epoch moves on and the results are
  /// current for the new epoch.
  bool _select(
    String member,
    String operation,
    int Function(Pointer<GhosttySearchImpl> search) call,
  ) {
    final search = _pointer(member);
    final raw = call(search);
    final terminal = _terminalHandle..bumpEpoch();
    _fedEpoch = terminal.epoch;
    return checkResultHasValue(raw, operation);
  }

  /// Wraps a match the library returned, valid while the terminal has not
  /// changed since the last feed.
  ///
  /// libghostty-vt 1.0.0 drops scrollback matches whose pages were evicted
  /// only when the scrollback search completes or a match is selected: a
  /// feed in the middle of a search keeps them, and a tick can even add
  /// some, with page pointers the terminal has freed. Using one would read
  /// freed memory, so a match whose ends are no longer cells of the active
  /// screen ([isLiveGridRef]) is returned already stale.
  VtSelection _match(GhosttySelection selection) {
    final terminal = _terminalHandle;
    final live =
        terminal.epoch == _fedEpoch &&
        isLiveGridRef(terminal, selection.start) &&
        isLiveGridRef(terminal, selection.end);
    return selectionFromNative(
      terminal,
      selection,
      epoch: live ? _fedEpoch : _staleEpoch,
    );
  }

  /// An epoch no terminal ever has: selections made with it are stale.
  static const _staleEpoch = -1;

  /// Reads search data [key] (for the getter [member]) into [size] bytes of scratch memory; `null`
  /// for `GHOSTTY_NO_VALUE`.
  R? _read<R extends Object>(
    String member,
    int key,
    int size,
    R Function(Pointer<Uint8> out) decode,
  ) {
    final search = _pointer(member);
    return withScratch(size, (out) {
      final hasValue = checkResultHasValue(
        ghostty_search_get(search, key, out.cast()),
        'ghostty_search_get',
      );
      return hasValue ? decode(out) : null;
    });
  }

  /// Reads a `GhosttySelectionBuffer` key, growing the buffer to the size
  /// the library reports when it is too small.
  List<VtSelection> _readMatches(int key) {
    final search = _pointer('matches');
    var capacity = _initialMatchCapacity;
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      final result = using((arena) {
        final buffer = arena<GhosttySelectionBuffer>();
        final entries = arena<GhosttySelection>(capacity);
        buffer.ref
          ..ptr = entries
          ..cap = capacity
          ..len = 0;
        final code = checkResultAllowing(
          ghostty_search_get(search, key, buffer.cast()),
          'ghostty_search_get',
          const {GhosttyResultCode.outOfSpace},
        );
        if (code == GhosttyResultCode.outOfSpace) {
          capacity = math.max(buffer.ref.len, capacity + 1);
          return null;
        }
        return List<VtSelection>.unmodifiable([
          for (var i = 0; i < buffer.ref.len; i++) _match(entries[i]),
        ]);
      });
      if (result != null) return result;
    }
    throw GhosttyException(
      'ghostty_search_get',
      resultCodec.encode(GhosttyResultCode.outOfSpace),
    );
  }

  static void _set(
    Pointer<GhosttySearchImpl> search,
    int option,
    Pointer<Void> value,
  ) => checkResult(
    ghostty_search_set(search, option, value),
    'ghostty_search_set',
  );

  /// The native search, after checking that it is not disposed and its
  /// terminal is not running a callback ([member] names the caller).
  Pointer<GhosttySearchImpl> _pointer(String member) {
    final pointer = _handle.pointer;
    checkNotInTerminalCallback(_terminalHandle, 'TerminalSearch.$member');
    return pointer;
  }

  /// Covers a typical find bar in one call; more take a second call.
  static const _initialMatchCapacity = 64;

  /// Matches only grow between attempts if the search ticks in between,
  /// which it cannot; one retry is normal.
  static const _maxRetries = 4;
}
