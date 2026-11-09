<!-- Frozen from the 2026-11-09 idiomatic-API plan run. Keep in sync when conventions change; ADR 0006 summarises the key rules. -->

# Contracts: ghostty_dart idiomatic API (frozen by T01)

Every task programs against this file. Signatures here are **frozen**. If one is
unworkable, stop and report `BLOCKED-CONTRACT-CHANGE` with the proposed
signature and the reason (see `roles.md`).

Package root: `packages/ghostty_dart/`. All paths below are relative to it.

---

## 1. Layout and import rules

```
lib/ghostty_dart.dart                 top-level barrel (T01; T10 audits). Exports every module barrel.
lib/src/<m>/<m>.dart                module barrel, owned by the module's task.
                                    Modules: core terminal parsers color unicode input render
                                    grid text selection search snapshot kitty sys
lib/src/core/**                     T01. Public types + internal helpers.
lib/src/core/internal.dart          INTERNAL library. Never exported by any barrel.
lib/src/ffi/bindings.g.dart         raw ffigen bindings. Never edited by hand.
lib/src/terminal/terminal.dart      VtTerminal AND the terminal module barrel (same file).
test/<module>/                      tests of a module (test/core, test/terminal, test/render, ...)
test/support/terminal_support.dart  shared test helpers (T01)
```

- A module barrel is the **only** thing the top-level barrel exports for that
  module. To publish a type, add an `export '...' show A, B;` line to your
  module barrel. Use `show` lists so internal helpers that live in the same
  file as a public type are not exported.
- A module may add any number of files under `lib/src/<m>/`. Only its barrel is
  public.
- Internal imports, in every module source file that needs FFI:
  ```dart
  import 'dart:ffi';
  import '../core/internal.dart';
  import '../ffi/bindings.g.dart';
  ```
  `internal.dart` exports only helpers, not the public core types. Import the
  public core types you need from `'../core/core.dart'` (or the specific file).
- Do not import another wave's module internals. Cross-module access to native
  handles goes through `handleOf` (§4.2) only.
- Tests import `package:ghostty_dart/ghostty_dart.dart` for the public API and may
  import `package:ghostty_dart/src/core/internal.dart` and
  `package:ghostty_dart/src/ffi/bindings.g.dart` for white-box checks.
- `dart:ffi` exports are currently unconditional from `lib/ghostty_dart.dart`
  (no web backend yet). Known debt for the wasm milestone (see §12).

## 2. Hard rules

1. **No `dart:ffi` types in the public API**: no `Pointer`, `Struct`, `Union`,
   `NativeType`, `Finalizable` in public signatures (implementing `Finalizable`
   on a public class is allowed and required, see §4), no ffigen typedefs, no
   raw constants classes (`GhosttyFoo.GHOSTTY_FOO_BAR`).
2. Public enums decoded from native ints have an `unknown` member (§3).
3. Bytes in/out are `Uint8List`; text is `String` decoded as UTF-8 with
   `allowMalformed: true` (terminal content is untrusted).
4. Every native result goes through the core error helpers (§5). No ad-hoc
   `if (rc != 0)` checks.
5. Every owned native object is wrapped with `NativeHandle` (§4): idempotent
   `dispose()`, `isDisposed`, `StateError` after dispose, `NativeFinalizer`.
6. Every public member has dartdoc (`public_member_api_docs` is on). Handle
   docs state ownership/lifetime.
7. Callbacks use `NativeCallable.isolateLocal` and are closed in `dispose()`
   (via `NativeHandle.addCleanup`).
8. No new dependencies. Never edit `bindings.g.dart`, `pubspec.yaml` or another
   task's files.

## 3. Tolerant enum pattern (`lib/src/core/enum_codec.dart`)

```dart
final class RawEnumCodec<E extends Enum> {
  RawEnumCodec(Iterable<E> values, {required int? Function(E value) raw, required E unknown});
  E decode(int raw);      // never throws; unknown raw -> `unknown`
  int encode(E value);    // throws ArgumentError for members with no raw value (unknown)
}
```

Convention (copy exactly):

```dart
/// dartdoc
enum VtCursorStyle {
  /// dartdoc
  bar(0),
  ...
  /// A value added by a later libghostty-vt release.
  unknown(null);

  const VtCursorStyle(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyCursorStyle` values to [VtCursorStyle] and back.
final vtCursorStyleCodec = RawEnumCodec<VtCursorStyle>(
  VtCursorStyle.values, raw: (v) => v._raw, unknown: VtCursorStyle.unknown);
```

- Raw values are **integer literals** copied from the header, not references to
  the bindings constants. This keeps public type files free of `dart:ffi` (the
  future wasm backend reuses them). Every module adds a test that checks each
  literal against the bindings constant (see `test/core/enum_codec_test.dart`
  helper `_expectCodec`; copy it).
- The codec is a public top-level in the enum's file; the module barrel hides it
  with `show`. Sibling modules import it from the defining file (core codecs
  are re-exported by `internal.dart`).
- Bit-flag sets (e.g. modifiers, style flags) are **not** enums: model them as
  an immutable class over an int that keeps unknown bits (see `KeyModifiers`).
- Dart-only enums never decoded from native (e.g. `VtFeature`) need no
  `unknown`.
- Unknown values never throw on decode; encoding `unknown` throws
  `ArgumentError`.

## 4. Native handles (`lib/src/core/handle.dart`, via `internal.dart`)

### 4.1 API

```dart
final class NativeHandle<T extends NativeType> implements Finalizable {
  NativeHandle(Pointer<T> pointer, {
    required String typeName,                       // public type, for messages
    required void Function(Pointer<T> pointer) free, // called once by dispose()
    required NativeFinalizer? finalizer,             // same _free; null only for multi-arg frees
    int externalSize = 0,
  });                                                // throws ArgumentError on NULL

  final String typeName;
  bool get isDisposed;
  Pointer<T> get pointer;                 // StateError('<typeName> has been disposed') after dispose
  void checkNotDisposed();                // same StateError
  R use<R>(R Function(Pointer<T> pointer) action); // defers a dispose() during action until it returns
  bool get isInUse;                       // inside use(): a native call that may call back is running
  int get epoch;                          // mutation counter for borrowed views
  void bumpEpoch();
  void addCleanup(void Function() cleanup);    // runs after the free, LIFO, once; not on GC
  void addDependent(NativeHandle dependent);   // weak; disposed BEFORE this handle is freed
  A? attachment<A extends Object>(Object key);
  void setAttachment(Object key, Object? value); // null removes
  void dispose();                         // idempotent
}

Pointer<T> createNative<T extends NativeType>(
  String operation, int Function(Pointer<Pointer<T>> out) create);
  // ensureCompatibleLibrary(); allocate out-param; checkResult; NULL -> GhosttyException(invalidValue)

void bindHandle(Object owner, NativeHandle handle);          // once, in the owner's constructor
NativeHandle<T> handleOf<T extends NativeType>(Object owner); // ArgumentError if none bound
```

`dispose()` order: mark disposed → detach finalizer → dispose live dependents →
free (deferred if inside `use`) → run cleanups (LIFO). A throwing cleanup (or a
dependent whose dispose throws) does not stop the others or the free; the first
error is rethrown after everything ran.

### 4.2 Wrapper recipe (every owned object)

```dart
final class Formatter implements Finalizable {        // public, implements Finalizable
  Formatter._(this._terminal, Pointer<GhosttyFormatterImpl> p)
    : _handle = NativeHandle(p,
        typeName: 'Formatter',
        free: (p) => ghostty_formatter_free(p),
        finalizer: _finalizer) {
    bindHandle(this, _handle);                         // lets sibling modules reach it
    handleOf<GhosttyTerminalImpl>(_terminal).addDependent(_handle); // if it borrows a parent
  }

  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttyFormatter)>>(
      ghostty_formatter_free).cast());

  final VtTerminal _terminal;   // strong ref: parent is not GC'd while the child lives
  final NativeHandle<GhosttyFormatterImpl> _handle;

  /// Whether [dispose] has been called.
  bool get isDisposed => _handle.isDisposed;
  /// Frees ... Safe to call more than once.
  void dispose() => _handle.dispose();
}
```

- `Native.addressOf` needs a constant type argument and a direct reference to
  the `@Native` function, so each module writes its own `_finalizer` line.
- The public wrapper itself `implements Finalizable` so a local variable keeps
  it (and its handle) alive during a native call.
- Read `_handle.pointer` immediately before each native call; never cache a raw
  pointer in a field or across calls.
- Use `_handle.use((p) => ...)` for any native call that can invoke Dart
  callbacks (`vt_write`, `resize`, `reset`, setters that fire callbacks).
  Pure getters may use `_handle.pointer`.
- `ghostty_selection_gesture_free(gesture, terminal)` takes two arguments: pass
  `finalizer: null` and free it in `free:`; document that it must be disposed.
- Parents that must outlive children (header: "the terminal must outlive the
  formatter"): the child keeps a strong Dart reference to the parent wrapper AND
  registers `parentHandle.addDependent(childHandle)`. Disposing the parent then
  disposes the child first. (GC finalizer order is not guaranteed if both
  become unreachable together; document "dispose children explicitly".)
- Borrowed handles (render rows/cells, grid refs, kitty images, iterators):
  capture `parentHandle.epoch` when created; every access checks
  `parentHandle.epoch == captured && !parentHandle.isDisposed`, else throws
  `StateError('<Type> is no longer valid: the terminal changed')`. Prefer
  scoped APIs (`void forEachRow(void Function(RenderRow row) f)`) that
  invalidate the view when the scope ends.

### 4.3 Errors from handles
- Use after dispose: `StateError` with message `'<typeName> has been disposed'`.
- Construction failures: `GhosttyException` (via `createNative`), `RangeError`
  / `ArgumentError` for invalid Dart arguments (validate in Dart before calling
  native code whenever the header documents the valid range).

## 5. Errors (`lib/src/core/result.dart`)

Public:

```dart
enum GhosttyResultCode {
  success(0), outOfMemory(-1), invalidValue(-2), outOfSpace(-3), noValue(-4),
  ioError(-5), limitExceeded(-6), rejected(-7), unsupported(-8), unknown(null);
  bool get isError;   // != success
}

final class GhosttyException implements Exception {
  GhosttyException(String operation, int rawCode);
  final String operation;          // C function name, e.g. 'ghostty_terminal_resize'
  final GhosttyResultCode code;    // decoded; unknown for codes this package does not know
  final int rawCode;
}
```

Internal (via `internal.dart`) — the only mapping path:

```dart
final RawEnumCodec<GhosttyResultCode> resultCodec;
GhosttyResultCode decodeResult(int raw);         // raw >= 0 -> success; never throws
Object resultError(int raw, String operation);   // -8 -> UnsupportedError, else GhosttyException
void checkResult(int raw, String operation);     // throws resultError for raw < 0
bool checkResultHasValue(int raw, String operation); // NO_VALUE -> false, success -> true
GhosttyResultCode checkResultAllowing(int raw, String operation, Set<GhosttyResultCode> allowed);
```

- `operation` is the C function name.
- `GHOSTTY_UNSUPPORTED` is always `UnsupportedError` (never `GhosttyException`).
- Optional values (`NO_VALUE`) become `null` in the public API (e.g.
  `String? get title`), using `checkResultHasValue`.
- `REJECTED` (paste safety) is a `GhosttyException` unless the API models it as
  a return value; T04 decides and documents.

## 6. Memory and buffers (`lib/src/core/memory.dart`, via `internal.dart`)

```dart
R withNativeBytes<R>(Uint8List bytes, R Function(Pointer<Uint8> data, int length) action);
R withUtf8<R>(String text, R Function(Pointer<Uint8> data, int length) action);   // not NUL-terminated
R withScratch<R>(int size, R Function(Pointer<Uint8> memory) action);  // zeroed, >= size bytes
Uint8List copyBytes(Pointer<Uint8> data, int length);         // length 0 -> empty, NULL ok
String decodeUtf8(Pointer<Uint8> data, int length);           // allowMalformed
String readGhosttyString(GhosttyString string);               // borrowed GhosttyString -> String (copy)
Uint8List takeLibraryBytes(Pointer<Uint8> data, int length);  // copy + ghostty_free(NULL, ...)
Uint8List callAllocating(String operation,
    int Function(Pointer<Pointer<Uint8>> outPtr, Pointer<Size> outLength) call); // *_alloc functions
Uint8List? tryCallWithSizeQuery(String operation,
    int Function(Pointer<Uint8> buffer, int capacity, Pointer<Size> outLength) call,
    {int initialCapacity = 128});                             // null on NO_VALUE
Uint8List callWithSizeQuery(...same...);                      // NO_VALUE -> GhosttyException
Uint8List? tryCallWithBuffer(String operation,
    int Function(Pointer<GhosttyBuffer> buffer) call, {int initialCapacity = 128});
Uint32List? tryCallWithCodepointBuffer(String operation,
    int Function(Pointer<GhosttyCodepointBuffer> buffer) call, {int initialCapacity = 16});
extension SizedStructInit<T extends Struct> on Pointer<T> { void initSized(int size); }
final class GrowableNativeBuffer implements Finalizable {
  GrowableNativeBuffer([int initialCapacity = 256]);
  Pointer<Uint8> get pointer; int get capacity;
  void ensureCapacity(int bytes);   // contents not kept
  void dispose();                   // idempotent; finalizer frees if forgotten
}
```

Rules:
- All `action`/`call` closures must be **synchronous** and must not let the
  pointer escape.
- Scratch blocks come from isolate-global pools. A nested call (e.g. inside a
  `vt_write` callback) gets a fresh temporary block, so nesting is safe.
- Size-query convention (`buf`, `buf_len`, `out_written` → `OUT_OF_SPACE` with
  the required size): the helpers try `initialCapacity` first and retry with the
  reported size (max 4 retries), discarding partial output. Choose an
  `initialCapacity` that fits the common case to make it one native call.
- `*_alloc` outputs: always `callAllocating` (pass `nullptr` as the allocator to
  the C function); it frees with `ghostty_free(nullptr, ptr, len)`.
- Zero-copy: the generated bindings have **no `isLeaf` calls**, so
  `Uint8List.address` cannot be passed. Input bytes are copied once into a
  pooled block (`withNativeBytes`). Output views via `asTypedList` are allowed
  only inside the scope where the memory is valid; copy before returning.
- Hot paths (render cells): keep a per-object `GrowableNativeBuffer` or a
  per-object struct allocated once with `calloc` and freed in `addCleanup`,
  instead of allocating per cell. Allocation-free reads matter more than
  closure overhead.
- Arena (`using((arena) { ... })` from `package:ffi`) is fine for cold paths.

### Sized structs
Structs whose first field is `size_t size` (e.g. `GhosttyTerminalMemoryUsage`,
`GhosttyRenderStateCursor`, write-until result, selection/mouse/paste option
structs) **must** be initialised with:

```dart
final opts = arena<GhosttyFoo>()..initSized(sizeOf<GhosttyFoo>());
```

(`ghostty_sized_init` zeroes the struct and sets `size`). Fixed-layout structs
without a `size` field (`GhosttyStyle`, `GhosttyColorRgb`, `GhosttyPoint`,
`GhosttyCodepointBuffer`) must not be passed to `initSized`. Generic helpers
cannot call `sizeOf<T>()`/`arena<T>()` with a type parameter (Dart requires a
constant type), hence the explicit size argument.

## 7. Library info (`lib/src/core/library_info.dart`)

Public:

```dart
String get libghosttyVtVersion;            // ghostty_version(), e.g. '1.0.0'
final VtBuildInfo libghosttyVtBuildInfo;   // queried once, lazily

enum OptimizeMode { debug(0), releaseSafe(1), releaseSmall(2), releaseFast(3), unknown(null) }

enum VtFeature { kittyGraphics, snapshot, formatter, selection, search, renderState,
                 inputEncode, color, gridIntrospection, glyphProtocol }

final class VtBuildInfo {
  final String version; final int major, minor, patch;
  final String preRelease;     // '' for releases
  final String buildMetadata;  // '' if none
  final OptimizeMode optimizeMode;
  final bool simd, tmuxControlMode;
  final Set<VtFeature> features;
  bool supports(VtFeature feature);
}

final class IncompatibleLibraryException implements Exception {
  IncompatibleLibraryException(String version, String reason);
  final String version; final String reason;
}
```

Internal: `void ensureCompatibleLibrary()` (cached; throws
`IncompatibleLibraryException` unless `>=1.0.0 <2.0.0`, rejecting `1.0.0-*`
pre-releases), `String? libraryVersionProblem(int major, int minor, int patch,
{String preRelease = ''})`, `optimizeModeCodec`.

`createNative` runs the check. Stateless entry points that never create an
object (parsers-free functions such as colour parsing or unicode width) call
`ensureCompatibleLibrary()` once at their entry if they want the clear error;
it is cheap after the first call.

## 8. Shared value types (public, pure Dart, `lib/src/core/`)

All immutable, `==`/`hashCode`/`toString` implemented. None imports `dart:ffi`.

### Colours — `color.dart`
```dart
sealed class ColorRef { const ColorRef(); }
final class DefaultColor extends ColorRef { const DefaultColor(); }      // "use the terminal default"
final class PaletteColor extends ColorRef {
  const PaletteColor(int index);        // 0-255 (assert)
  final int index;
  static const black, red, green, yellow, blue, magenta, cyan, white,
      brightBlack, brightRed, brightGreen, brightYellow, brightBlue,
      brightMagenta, brightCyan, brightWhite;   // indices 0-15
}
final class RgbColor extends ColorRef {
  const RgbColor(int r, int g, int b);  // 0-255 each (assert)
  const RgbColor.fromValue(int value);  // 0xRRGGBB, higher bits ignored
  final int r, g, b;
  int get value;                        // 0xRRGGBB
  String toHex();                       // '#rrggbb'
}
```
- `RgbColor` is used standalone (palettes, default fg/bg, colour utilities in
  T03, OSC colour reports) and as a `ColorRef`.
- An unknown `GhosttyStyleColor` tag decodes to `DefaultColor` (documented;
  renderers always get something drawable).
- A palette is `List<RgbColor>` of length 256.

### Style — `style.dart`
```dart
enum UnderlineStyle { none(0), single(1), double(2), curly(3), dotted(4), dashed(5), unknown(null) }
final RawEnumCodec<UnderlineStyle> underlineStyleCodec;   // GhosttySgrUnderline; T03 SGR reuses it

final class CellStyle {
  const CellStyle({ColorRef foreground = const DefaultColor(),
      ColorRef background = const DefaultColor(), ColorRef underlineColor = const DefaultColor(),
      bool bold = false, bool italic = false, bool faint = false, bool blink = false,
      bool inverse = false, bool invisible = false, bool strikethrough = false,
      bool overline = false, UnderlineStyle underline = UnderlineStyle.none});
  final ColorRef foreground, background, underlineColor;
  final bool bold, italic, faint, blink, inverse, invisible, strikethrough, overline;
  final UnderlineStyle underline;
  bool get isDefault;
  CellStyle copyWith({...same names, all nullable});
}
```

### Grid point — `point.dart`
```dart
enum PointSpace { active(0), viewport(1), screen(2), history(3), unknown(null) }
final RawEnumCodec<PointSpace> pointSpaceCodec;

final class GridPoint {
  const GridPoint(PointSpace space, int x, int y);   // x: uint16, y: uint32 (assert)
  const GridPoint.active(int x, int y);
  const GridPoint.viewport(int x, int y);
  const GridPoint.screen(int x, int y);
  const GridPoint.history(int x, int y);
  final PointSpace space; final int x; final int y;
}
```
A plain cursor position may be returned as `GridPoint.active(x, y)`.

### Modifiers — `modifiers.dart`
```dart
final class KeyModifiers {
  const KeyModifiers({bool shift = false, bool ctrl = false, bool alt = false,
      bool superKey = false, bool capsLock = false, bool numLock = false,
      bool rightShift = false, bool rightCtrl = false, bool rightAlt = false,
      bool rightSuper = false});
  static const none, shift, ctrl, alt, superKey, capsLock, numLock;
  bool get hasShift, hasCtrl, hasAlt, hasSuper, hasCapsLock, hasNumLock;
  bool get isRightShift, isRightCtrl, isRightAlt, isRightSuper;
  bool get isEmpty;
  bool containsAll(KeyModifiers other);
  KeyModifiers operator |(KeyModifiers other);
  KeyModifiers operator &(KeyModifiers other);
}
// internal: int keyModifiersToRaw(KeyModifiers m); KeyModifiers keyModifiersFromRaw(int raw);
```
Mouse events (T04) reuse `KeyModifiers`. Unknown bits round-trip.

### Terminal mode — `mode.dart`
```dart
final class TerminalMode {
  const TerminalMode.dec(int value);   // DEC private, 0-32767
  const TerminalMode.ansi(int value);  // ANSI, 0-32767
  final int value; final bool isAnsi;
  // ANSI:  disableKeyboard insert sendReceive linefeed
  // DEC:   cursorKeys column132 slowScroll reverseColors origin wraparound autorepeat
  //        mouseEventX10 cursorBlinking cursorVisible enableMode3 reverseWrap
  //        altScreenLegacy keypadKeys backarrowKey enableLeftAndRightMargin
  //        mouseEventNormal mouseEventButton mouseEventAny focusEvent mouseFormatUtf8
  //        mouseFormatSgr mouseAlternateScroll mouseFormatUrxvt mouseFormatSgrPixels
  //        ignoreKeypadWithNumLock altEscPrefix altSendsEscape reverseWrapExtended
  //        altScreen saveCursor altScreenSaveCursorClearEnter bracketedPaste
  //        synchronizedOutput graphemeCluster reportColorScheme reportVisibility
  //        inBandSizeReports kittyPasteEvents
  static const List<TerminalMode> named;   // all of the above, header order
}
// internal: int terminalModeToRaw(TerminalMode m)   == ghostty_mode_new(value, ansi)
//           TerminalMode terminalModeFromRaw(int raw)
```
`GhosttyModeReportState` (DECRPM) is **not** in core: T04 (reports) owns
`ModeReportState`.

### Cursor style / active screen — `terminal_enums.dart`
```dart
enum VtCursorStyle { bar(0), block(1), underline(2), blockHollow(3), unknown(null) }
enum TerminalScreen { primary(0), alternate(1), unknown(null) }
final RawEnumCodec<VtCursorStyle> vtCursorStyleCodec;   // renamed by T10 (xterm clash)
final RawEnumCodec<TerminalScreen> terminalScreenCodec;
```

### FFI conversions (internal, `native_convert.dart`, exported by `internal.dart`)
```dart
RgbColor rgbFromNative(GhosttyColorRgb color);
void rgbToNative(RgbColor color, GhosttyColorRgb out);          // RangeError if > 255
ColorRef styleColorFromNative(GhosttyStyleColor color);         // unknown tag -> DefaultColor
void styleColorToNative(ColorRef color, GhosttyStyleColor out); // zeroes unused value bytes
CellStyle cellStyleFromParts({required int flags, required ColorRef foreground,
    required ColorRef background, required ColorRef underlineColor});
int cellStyleFlags(CellStyle style);                            // GhosttyStyleFlags; ArgumentError for underline unknown
CellStyle cellStyleFromNative(GhosttyStyle style);
void cellStyleToNative(CellStyle style, GhosttyStyle out);      // reserved = 0
GridPoint gridPointFromNative(GhosttyPoint point);
void gridPointToNative(GridPoint point, GhosttyPoint out);      // ArgumentError unknown, RangeError x/y
```
Pass struct views (`pointer.ref`). Renderers (T05) may cache decoded styles by
their raw 16 bytes to avoid allocating a `CellStyle` per cell.

## 9. `VtTerminal` (`lib/src/terminal/terminal.dart`)

```dart
final class VtTerminal implements Finalizable {
  VtTerminal({required int cols, required int rows});  // each 1-65535 (RangeError);
                                                        // GhosttyException / IncompatibleLibraryException
  bool get isDisposed;
  int get cols;                     // read from native each call (DECCOLM can change it)
  int get rows;
  void write(Uint8List bytes);      // ghostty_terminal_vt_write; StateError if re-entered from
                                    // a callback of the same terminal, or after dispose
  void resize(int cols, int rows, {int? cellWidthPx, int? cellHeightPx});
                                    // omitted px keep the cell size of the last resize
                                    // (0x0 initially; tracked in Dart, see below);
                                    // RangeError: cells 1-65535, px 0-0xFFFFFFFF
  void dispose();                   // idempotent; deferred free if inside a callback
}
```

Internals other modules rely on:
- `handleOf<GhosttyTerminalImpl>(terminal)` returns its `NativeHandle`
  (`typeName: 'VtTerminal'`).
- `write` and `resize` call the native function inside `handle.use(...)` and
  then `handle.bumpEpoch()`.
- `write` is the reentrancy guard: it throws `StateError` when
  `handle.isInUse` (the header forbids `vt_write` from callbacks).
- The cell pixel size is kept in private `VtTerminal` fields set by each
  successful `resize`: the library stores only the total pixel size, and
  DECCOLM changes `cols` without updating it, so total ÷ cols is wrong after
  DECCOLM. T02 must keep this when it edits `resize`.

### How T02 and T07 extend it without conflicting

- **T02 (wave 1) owns `lib/src/terminal/**` except `effects*.dart`**, including
  `terminal.dart`. It adds state getters, options, modes, scroll, reset,
  compress, continuation as members of `VtTerminal` or in new files under
  `lib/src/terminal/` exported from `terminal.dart`. Rules for T02:
  - Every mutating native call (reset, scroll_viewport, set options that
    change content, vt_write_until, continuation writes, compress) runs inside
    `_handle.use(...)` and is followed by `_handle.bumpEpoch()`.
  - Getters use `_handle.pointer` + `withScratch` / `ghostty_terminal_get`
    (`get_multi` for batches).
  - Do not change the signatures in §9; add members only.
  - Do **not** add callback/effect setters (`OPT_WRITE_PTY`, `OPT_BELL`,
    `OPT_TITLE_CHANGED`, clipboard, render hold, ... and `OPT_USERDATA`). Those
    belong to T07.
- **T07 (wave 2) owns `lib/src/terminal/effects*.dart`** and implements every
  callback as an extension (or a class reached from one) on `VtTerminal`, with
  no state in `VtTerminal` itself:
  ```dart
  extension VtTerminalEffects on VtTerminal {
    set onBell(void Function()? callback) { ... }
    ...
  }
  ```
  - State per terminal lives in `handleOf<GhosttyTerminalImpl>(this)`
    attachments (`attachment` / `setAttachment` with a private
    `final _effectsKey = Object();`).
  - Each `NativeCallable.isolateLocal` is closed through
    `handle.addCleanup(callable.close)` (register once; replacing a callback
    closes the previous callable after `ghostty_terminal_set` installs the new
    one; setting `null` passes NULL to restore the default and closes it).
  - No userdata pointer is needed: closures capture state. Do not capture the
    `VtTerminal` **or its `NativeHandle`** strongly in the closure: an open
    `NativeCallable` is a GC root, so either would keep the handle reachable
    forever and its `NativeFinalizer` would never free a forgotten terminal.
    Capture a `WeakReference` to the handle (or to the terminal) instead.
    (Review fix T01: the earlier text allowed capturing the handle.)
  - The only edit T07 may make to `terminal.dart` is adding
    `export 'effects.dart' show VtTerminalEffects, ...;`. If T07 needs
    constructor-time options, it adds a separate factory in `effects.dart`
    (e.g. `VtTerminal withEffects(...)`), not a new `VtTerminal` constructor
    parameter.
  - Callbacks fire synchronously inside `write`/`resize`/`reset`; a callback
    calling `dispose()` is safe (deferred free); calling `write()` throws.

## 10. Test support (`test/support/terminal_support.dart`)

```dart
R withTerminal<R>(int cols, int rows, R Function(VtTerminal terminal) body); // disposes after
void writeText(VtTerminal terminal, String text);                           // UTF-8 write
String screenText(VtTerminal terminal); // raw formatter, plain text, default options
                                        // (trailing blanks trimmed, rows joined by '\n')
int terminalDataUint16(VtTerminal terminal, int key); // raw ghostty_terminal_get of a uint16
int terminalDataUint32(VtTerminal terminal, int key); // same for a uint32 (e.g. WIDTH_PX)
```
Modules may add their own helpers under their own `test/<module>/` directory;
`test/support/` stays T01's.

## 11. Naming

- Public wrappers of native objects: noun, prefixed with `Vt` only when the
  bare name collides with Dart/Flutter/xterm names (`VtTerminal`, `VtBuildInfo`,
  `VtFeature`). Otherwise plain names (`CellStyle`, `GridPoint`,
  `KeyModifiers`, `RenderState`, `KeyEncoder`, `OscParser`). Avoid `Color`,
  `TextStyle`, `Point`, `Offset`, `Size`, `Key`, `KeyEvent`, `Selection`, `CursorStyle` as bare
  names (Flutter/dart:math clashes): use `KeyEvent` → `VtKeyEvent`, etc.
- Prefixes, the complete scheme (no other prefixes):
  - `Vt`: the emulator or the loaded library as a whole, or a bare name that
    is too generic or collides (`VtTerminal`, `VtBuildInfo`, `VtFeature`,
    `VtKeyEvent`).
  - `Ghostty`: reserved for the error vocabulary named after the library,
    like `SqliteException` (`GhosttyException`, `GhosttyResultCode`; the
    `Code` suffix keeps it distinct from the raw `GhosttyResult`). Modules do
    not add new public `Ghostty*` types; every other `Ghostty*` name is a raw
    C binding.
  - `libghosttyVt`: process-wide top-level getters (`libghosttyVtVersion`,
    `libghosttyVtBuildInfo`).
  - Process-wide *settings* (T09 standards review, `sys.h`) are top-level
    functions named verb + `Vt` + noun: `setVtLogHandler`,
    `useVtStderrLogging`, `setVtPngDecoder`, `setVtSecureRandomSource`. They
    are methods, not setters, because they are write-only; top-level, not
    statics of a namespace class (Effective Dart: avoid static-only
    classes); `Vt` keeps generic names like `setLogHandler` from clashing
    in user code. Their types use `Vt` only where the bare name is generic
    (`VtLogLevel`, `VtLogHandler`, `VtPngDecoder`, `VtSecureRandomSource`;
    `RgbaImage` is already specific).
  - Members a module adds to `VtTerminal` through an extension carry the
    module's noun so they read clearly on the terminal: `kittyImage`,
    `kittyPlacements`, `kittyGraphicsGeneration`, `tickKittyAnimations`
    (an action, so verb first), `encodeSnapshot`; consistent with T02's
    `kittyImageStorageLimit` / `isKittyImageFileMediumEnabled`.
- Qualified nouns vs prefixes (T08 standards review). A `Terminal…`
  compound is not a prefix: it names an object *of* a terminal, the way the
  C API does (`ghostty_formatter_terminal_new`, a search bound to one
  terminal), like T02's `TerminalCursor`, `TerminalScreen`,
  `TerminalMemoryUsage`. Use it when the bare noun is too generic to name
  the thing (`TerminalFormatter`, `TerminalSearch`). Use `Vt` instead when
  the natural name itself is on the collision list (`Selection` →
  `VtSelection`, not `TerminalSelection`, which would read like the
  extension below). Checked against xterm 4.0.0's exported names
  (pub.dev API docs, 2026-11-09): no clash for `TerminalFormatter`,
  `TerminalSearch`, `VtSelection`. Extensions that add a module to the
  terminal are `VtTerminal<Module>` (`VtTerminalSelection`,
  `VtTerminalGrid`, `VtTerminalEffects`, `VtTerminalSnapshot`), and their
  members start with the module's verb or noun (`selectWord`,
  `selectRange`, `selection`).
- Errors: library failures are `GhosttyException` (operation + code); misuse
  is a Dart `Error` (`StateError` after dispose / reentrancy, `RangeError` /
  `ArgumentError` for bad arguments, `UnsupportedError` for
  `GHOSTTY_UNSUPPORTED`). A new `Exception` class only for a recoverable
  condition callers must catch by type (`IncompatibleLibraryException`).
- Enum members: lowerCamelCase from the C suffix (`GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW`
  → `blockHollow`). Every decoded enum has `unknown`.
- Getters for C `*_DATA_*` keys: lowerCamelCase of the suffix
  (`GHOSTTY_TERMINAL_DATA_CURSOR_X` → `cursorX`). Booleans read as questions
  (`isCursorVisible`, `hasStyling`).
- Options (C `*_OPT_*`) follow Effective Dart ("avoid a setter without a
  getter"; properties for cheap state, methods for actions). Added by the T02
  standards review:
  - An option the library can also read back (a matching `*_DATA_*` key) is a
    read/write property named after the data key: `scrollbackMaxBytes`,
    `title`, `colorForegroundDefault`, `isKittyImageFileMediumEnabled`.
  - A write-only option (no data key) is a `set<Name>(value)` method:
    `setTitleReportEnabled(bool)`, `setApcMaxBytes(int?)`,
    `setDefaultCursorStyle(VtCursorStyle?)`. A switch that turns a protocol
    or report on/off is `set<Feature>Enabled(bool)`; a behaviour flag keeps
    its C name (`setResizePullScrollback(bool)`).
  - A keyed option is a method with the key first: `setMode(mode, enabled:)`.
  - `null` restores the library default (or means "no limit" where the C
    side uses `SIZE_MAX`/`GHOSTTY_NO_VALUE`); each member documents which.
  - Actions with side effects stay methods even when cheap (`reset`,
    `scrollViewport`, `compress`).
- Raw C values of public enums stay private (`final int? _raw`), read through
  a codec or a hidden top-level `<enumName>ToRaw` function (e.g.
  `compressionModeToRaw`), never a public `raw` field.
- Error `operation` strings: the C function name.
- Codecs: `<enumName>Codec` (lowerCamelCase), public top-level in the enum file,
  hidden from barrels with `show`.
- Files: snake_case; tests `test/<module>/<file>_test.dart`; reviewers add
  `test/<module>/<module>_review_test.dart`.

## 12. Known debt / notes for later tasks

- Conditional export for web (`if (dart.library.js_interop)`) is not in place;
  `lib/ghostty_dart.dart` exports FFI-backed files unconditionally. The wasm
  milestone must split public types (pure Dart, already ffi-free in
  `core/{color,style,point,modifiers,mode,terminal_enums,result,enum_codec}.dart`)
  from FFI implementations.
- `NativeHandle` cleanups (e.g. closing `NativeCallable`s) run only on
  `dispose()`, not on GC.
- `kittyGraphics` is an optional build feature; tests that need it must skip
  when `!libghosttyVtBuildInfo.supports(VtFeature.kittyGraphics)`.

## §4.2a Addendum (orchestrator, after T06 review): finalizers for objects whose free touches another object
`NativeFinalizer` callbacks may run on any thread at any time, including while this isolate is inside a terminal call.
- **Rule:** if a `_free` function mutates another live native object (e.g. `ghostty_tracked_grid_ref_free` unregisters itself from its terminal), you must not use a `NativeFinalizer` for it.
- **Instead:**
  1. create the handle with `finalizer: null`;
  2. attach a Dart `Finalizer` (it runs as an event on the owning isolate, never mid-call);
  3. detach that `Finalizer` in a cleanup on dispose.
- **Reference implementation:** `lib/src/grid/tracked_grid_ref.dart`.
- **Before choosing, read the upstream Zig `_free`** (`src/terminal/c/`). Check at least: search (T08), selection gestures (T08), kitty graphics iterators (T09) and snapshot decoders (T09).
- Objects whose free only releases their own memory, such as encoders, parsers and render state (a copy), keep `NativeFinalizer`.

## §9a Amendment (orchestrator, after T07 review): callable lifetime
- **Lifetime:** each callback option's `NativeCallable.isolateLocal` is created on the first non-null set and reused on replace. Clearing it passes NULL to the library but keeps the callable. It is closed only on terminal dispose, or by a Dart `Finalizer` when the terminal is collected undisposed.
  - Reason: closing a callable while native code is running on it (e.g. a callback clearing itself) is undefined behaviour.
- **Every callable sets `keepIsolateAlive = false`.** This applies to any module that creates callables (sys logging in T09, writer callbacks in T08).

## §9b Amendment (orchestrator, T09 contract-change request): adopting native terminals
- `VtTerminal._adopt(Pointer<GhosttyTerminalImpl>)` is a private constructor. Next to it, `terminal.dart` has a top-level internal function `VtTerminal adoptNativeTerminal(Pointer<GhosttyTerminalImpl>)`.
- `lib/ghostty_dart.dart` exports `terminal.dart` with `hide adoptNativeTerminal`.
- An adopted terminal owns the pointer (finalizer plus `ghostty_terminal_free`). Its cell pixel size starts unknown and is derived from the library.
- Used by the snapshot decoder (T09). Approved; T09 makes these two edits.

## §4.2b Addendum (T10): dependent frees wait for the owner's `use()`
- `addDependent(dependent)` records the owner on the dependent (one owner per handle; a second, different owner is a `StateError`).
- A dependent disposed while its owner `isInUse` (directly, or through the owner's `dispose()` from inside a callback) is marked disposed at once, but its native free is queued on the owner and runs when the owner's outermost `use()` returns, **before** the owner's own deferred free. A dependent that is itself in `use()` waits for both.
- Reason: `ghostty_search_free`, `ghostty_tracked_grid_ref_free` and `ghostty_selection_gesture_free` write to their live terminal; freeing them from a callback ran that write while `vt_write` was still on the stack.
- Outside any `use()` nothing changes: dependents are freed at once, before the owner. Tests: `test/core/handle_test.dart` ("dependent frees wait for the owner"), `test/e2e/e2e_test.dart` ("dispose ordering").
- Every Dart `Finalizer` token of an object whose free touches its terminal (search, selection gesture, tracked grid ref) holds the terminal's `NativeHandle`, so the terminal's `NativeFinalizer` cannot run before (or concurrently with) that object's free.

## §12a Addendum (T10): renames and shared helpers
- `CursorStyle` → `VtCursorStyle`, `cursorStyleCodec` → `vtCursorStyleCodec` (clash with `package:xterm`'s `CursorStyle`; added to the §11 collision list).
- `listEquals<T>` lives in `lib/src/core/list_equality.dart` (pure Dart, also re-exported by `internal.dart`); it replaces `parsers/list_equality.dart`'s `intListEquals`, `effects_types.dart`'s `_listEqual` and the `RenderColors` loop.
- `PackedCell` (extension type in `render/cell_layout.dart`) is the one decoder of canonical packed cells, used by `RenderRow` and `GridRef`.
- Test helpers: `test/support/expect_support.dart` (`expectCodec`, `showEscapes`) and `test/support/selection_support.dart` (moved from `test/selection/`).
- Public API audit: `test/e2e/public_api_test.dart` (analyzer-based) fails on any `dart:ffi`/binding type or unexported package type in a public signature, on internal-only names, on duplicate exports across module barrels and on unexported public types not in its internal allow-list.

## §4.2b clarification (orchestrator, after T10 review)
If an owner is disposed while one of its dependents is inside that dependent's own `use()`, the owner keeps its native memory until that dependent has been freed. Implemented via `_busyDependents` / `_releaseWhenIdle` in `core/handle.dart`.
