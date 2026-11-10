# R2: input, IME, mobile, mouse, scrolling, a11y, PTY and API shape for `ghostty_dart_flutter`

Researcher: stage 0. Date: **2026-11-09** (everything below was read or run that day).

Tags: **[V]** verified at the source (file, URL or a probe run on this machine), **[I]** inferred or from memory, which needs checking on a device.

Sources used throughout:
- **ghostty_dart**: `packages/ghostty_dart/lib/src/{input,selection,search,terminal}/` at commit `32af562`.
- **C headers**: `.native-cache/host/include/ghostty/vt/` (libghostty-vt 1.0.0).
- **Flutter**: the 3.47.9 framework at `~/.local/share/mise/installs/flutter/3.47.9/packages/flutter/lib/src/`, shortened to `F/` below.
- **xterm 4.0.0**: `~/.pub-cache/hosted/pub.dev/xterm-4.0.0/lib/src/`, shortened to `X/`.
- **xterm2 5.4.0** (released 2026-10-21): `~/.pub-cache/hosted/pub.dev/xterm2-5.4.0/`, shortened to `X2/`.
- **xterm.dart issues**: `gh issue list --repo TerminalStudio/xterm.dart`, run 2026-11-09.
- **Probes**: two temporary `dart test` files were run inside `packages/ghostty_dart` against the host library and deleted afterwards. The working tree is clean.

---

## 1. Hardware keyboard

### 1.1 What `KeyEncoder` needs (`VtKeyEvent`, `lib/src/input/key.dart`) [V]

| Field | Meaning | Flutter source |
|---|---|---|
| `key: VtKey` | **Physical** key. It follows the W3C `KeyboardEvent.code` values, so it does not depend on the layout. | `KeyEvent.physicalKey` (`PhysicalKeyboardKey.usbHidUsage`, a USB HID code; `F/services/keyboard_key.g.dart:3545`). Needs a **static table** of about 150 entries mapping `PhysicalKeyboardKey` to `VtKey`, because both follow W3C/HID naming. Unmapped keys become `VtKey.unidentified`. |
| `action` | `press`, `repeat` or `release`. | `KeyDownEvent`, `KeyRepeatEvent` or `KeyUpEvent` (`F/services/hardware_keyboard.dart:259-306`). |
| `modifiers: KeyModifiers` | shift, ctrl, alt, super, capsLock, numLock, plus the right-side bits. | `HardwareKeyboard.instance.isShiftPressed` and the other modifier getters. Use `isLogicalKeyPressed(shiftRight)` etc. for the side bits, and `lockModesEnabled` for Caps Lock and Num Lock (`hardware_keyboard.dart:454-503`). |
| `consumedModifiers` | Modifiers the OS already used to produce `text`. | Flutter does not provide this. Use a heuristic (§1.3). |
| `isComposing` | The key is part of an IME composition sequence. The encoder outputs nothing for it [V probe]. | From our own IME state (§2). Flutter's `KeyEvent` has no such field. |
| `text` | The text for the current layout, **before** Ctrl/Meta are applied. Never a C0 control character, and never a macOS PUA code (U+F700–U+F8FF). | `KeyEvent.character`, filtered. It is `null` on key-up and for dead keys (`hardware_keyboard.dart:185-206`). |
| `unshiftedCodepoint` | The codepoint of the key with no modifiers. Used by the Kitty protocol and by modifier encodings. | `logicalKey.keyId` when `keyId & LogicalKeyboardKey.planeMask == unicodePlane` (`keyboard_key.g.dart:278-288`). For printable keys this is the lowercase character of the key, ignoring modifiers (`keyLabel` dartdoc, lines 118-135). [I] On desktop, Flutter maps non-Latin layouts to US-equivalent logical keys. Verify this on a Russian layout. |

Always call `setFromTerminal(terminal)` before encoding, because the program may have changed modes. `setFromTerminal` resets `macosOptionAsAlt`, so call `configure(macosOptionAsAlt:)` again afterwards (`key_encoder.dart:172-186`) [V].

### 1.2 Probe results (Linux host library, 2026-11-09) [V]

| Input | Output |
|---|---|
| `alt+a`, `text: 'a'` | `ESC a` |
| `ctrl+v`, `text: 'v'` | `^V` |
| `numpadEnter` | `^M` (xterm bug #137 does not apply to us) |
| Release in legacy mode | empty |
| `isComposing: true` | empty |
| `unidentified`, `text: 'ü'` | `ü` |
| Kitty flags 11: press `a` | `CSI 97u` |
| Kitty flags 11: release `a` | `CSI 97;1:3u` |
| Kitty flags 11: `shiftLeft` | `CSI 57441;2u` |
| Kitty flags 11: shift+a, `text: 'A'`, consumed shift | `CSI 97;2u` |

The encoder already handles Kitty release events and modifier-key events, so `KeyUpEvent` **must** reach the encoder.

**AltGr pitfall:** Windows reports AltGr as Ctrl+Alt.
- `ctrl+alt+q` with `text: '@'` gives `ESC ^@`.
- The same event with `consumedModifiers: ctrl|alt` gives `^@`. **Both are wrong.**
- Fix: when AltGr is active, **remove ctrl and alt from `modifiers`** before encoding. This is what xterm2 does in `_isAltGraphActive` (`X2/lib/src/terminal_view.dart:752-825`). It treats AltGr as active when any of these holds:
  - `LogicalKeyboardKey.altGraph` is pressed;
  - right Alt plus Ctrl are pressed;
  - it never applies on macOS.

**macOS Option:** with `macosOptionAsAlt: both`, `alt+a` with `text: 'å'` gave `ESC å` on the Linux build. The option is probably only honoured on macOS targets. [I] Verify on the macOS CI runner. Until then:
- Option-as-Alt **off**: send `text: 'å'` and add alt to `consumedModifiers`.
- Option-as-Alt **on**: send `text = String.fromCharCode(unshiftedCodepoint)` with the alt modifier.

### 1.3 Heuristics for `consumedModifiers` [I]
- Shift is consumed when `character` is not empty and differs from the unshifted character.
- On macOS, Alt is consumed when Option produced a character and Option-as-Alt is off.
- AltGr: see §1.2. Strip the modifiers rather than marking them consumed.
- Ghostty's macOS apprt computes this from `NSEvent` translation. Flutter gives us no equivalent, so cover the heuristic with tests.

### 1.4 Flow with an IME attached (desktop) [I, verify]
On desktop, Flutter sends `KeyEvent`s to the focused `Focus.onKeyEvent` first. If the handler returns `ignored`, the engine passes the native event on to the text input plugin, which does dead-key and CJK composition and calls `updateEditingValue`.

Recommended policy, matching the shape of xterm2's `_handleKeyEvent`:
1. While IME composing is active, return `skipRemainingHandlers`. xterm does this (`X/ui/custom_text_edit.dart`, `_onKeyEvent`).
2. Non-text keys (arrows, F-keys, Enter, Tab, Esc, Backspace), any key with ctrl, alt or super held (after the AltGr strip), every `KeyUpEvent`, and every key when the Kitty "report all keys as escape codes" flag is set: encode the key and return `handled`.
3. A plain printable key with `character != null`: either encode it with `text`, or return `ignored` and let the text input deliver it.
   - Recommended: **encode it ourselves when no IME composition is active**, so the Kitty press and release events pair up.
   - A dead key (`character == null`, non-text logical key) must return `ignored` so the IME composes it.

**Return `handled` for every key we encode.** Otherwise `WidgetsApp` default shortcuts take it:
- Tab → `NextFocusIntent`;
- arrows → `DirectionalFocusIntent`;
- Esc → `DismissIntent`;
- Enter and Space → `ActivateIntent`;
- Ctrl+arrows → `ScrollIntent`.

[V] `F/widgets/app.dart:1263-1293`. xterm's own approach (logical key, bool modifiers, no release events) is in `X/terminal_view.dart:393-430`.

### 1.5 Known key bugs elsewhere [V, gh, 2026-11-09]

**xterm.dart (open unless marked closed):**

| Issue | Date | Problem |
|---|---|---|
| #164 | 2023-02-27 | Korean IME is broken. |
| #137 | 2022-10 | Numpad Enter does not work (fixed in xterm2's changelog). |
| #155 | 2023-02 | Ctrl+L does not clear the screen. |
| #57 | 2021-08 | Ctrl+C does not work. |
| #173 (closed) | 2023-04 | Ctrl+C does not work on Windows. |
| #79 | 2021-12 | Space does not work on Chrome. |
| #30 | 2021-04 | The input handler fires endlessly on macOS embedding. |

**Root causes in xterm 4.0.0:**
- Keys are mapped by `logicalKey`, so non-QWERTY layouts and AltGr break.
- No meta modifier.
- No release events.
- DECCKM is wired to the wrong mode (see the earlier research doc).

**xterm2 changelog (`X2/CHANGELOG.md`):** "Preserve AltGr-composed text on Windows and Linux keyboards", "Report kitty key releases only when the application asks", "Keep IME composition text on the active row", and a `viewId` fix for Flutter 3.44+ (`X2/lib/src/ui/custom_text_edit.dart:18-25`).

**Our requirement:** pass `TextInputConfiguration(viewId: View.of(context).viewId)`. [V] The field exists in `F/services/text_input.dart:546`.

### 1.6 Shortcut policy (AGENTS.md: Ctrl+V and Ctrl+A go to the shell)

**xterm 4.0.0 violates it.** Its `defaultTerminalShortcuts` on Linux, Windows and Android bind Ctrl+V to paste and Ctrl+A to select all (`X/ui/shortcut/shortcuts.dart:18-25`) [V]. Our default deliberately diverges. The `ghostty_dart_xterm` adapter has to pass xterm's map explicitly to stay compatible: a ⚠️ row in COMPATIBILITY.md, or keep xterm's default in the adapter only.

**xterm2 5.4.0 already moved to the convention we want** (`X2/lib/src/ui/shortcut/shortcuts.dart`) [V]:
- Linux and Windows: Ctrl+Shift+C and Ctrl+Insert copy; Ctrl+Shift+V and Shift+Insert paste; Ctrl+Shift+A selects all.
- Apple: Cmd+C, Cmd+V and Cmd+A.
- Shift+PgUp, PgDn, Home and End scroll the scrollback.
- It also adds "Ctrl+C copies when a selection exists" on non-Apple platforms (`_shouldCopySelectionWithControlC`, line 867), as Windows Terminal does.

**Recommended design:**
- `VtTerminalView` takes `shortcuts: Map<ShortcutActivator, Intent>?`, defaulting to the platform map above.
- Intents: `CopySelectionTextIntent`, `PasteTextIntent`, `SelectAllTextIntent`, plus our own `ScrollTerminalIntent`.
- Matching:
  - xterm calls `ShortcutManager.handleKeypress` from inside its `onKeyEvent` (`X/terminal_view.dart:400`). Shortcuts run **before** encoding and only match the explicit map, so nothing else is stolen.
  - Wrap the view in `Actions` with overridable `Action`s, so apps can use `Actions.overridable` or their own `Shortcuts` above.
- Make Ctrl+C-copies-selection an opt-in flag, off by default. It changes shell semantics.
- On the web, the browser keeps Ctrl+W, Ctrl+T and Ctrl+N. This cannot be fixed; document it.

---

## 2. IME and text input

**`TextInputClient` or `DeltaTextInputClient`.** Both exist in 3.47.9 [V]. `DeltaTextInputClient` (`F/services/text_input.dart:1518`) receives `TextEditingDeltaInsertion`, `Deletion`, `Replacement` and `NonTextUpdate` once `TextInputConfiguration.enableDeltaModel` is true (lines 770-788).

**Recommendation:** use `DeltaTextInputClient`, with a hidden editing state that holds a sentinel. An insertion delta becomes text to the pty. A deletion before the caret becomes a Backspace key event (§3). xterm uses a plain `TextInputClient` and diffs the length against the sentinel (`X/ui/custom_text_edit.dart`, `updateEditingValue`), which breaks when a keyboard replaces text: xterm #143 "Composing range breaks key input on Android" (2022-11, open) and #176 (Gboard autocorrect, 2023-07, open). [I] Delta-model support differs by platform and engine version. Test on Android, iOS, web, macOS, Linux and Windows, and keep a non-delta fallback path.

**Composed text.** While `composing` is not collapsed, show the preedit and send nothing. When it collapses, send the committed text with `vt.pasteText(text, source: PasteSource.other)`. That writes it as text, never as a paste event (`terminal/paste.dart:43`). The alternative is to encode each grapheme through `KeyEncoder` with `VtKey.unidentified` and `text` (the probe shows `ü`). Then reset the editing state to the sentinel. The emoji picker and macOS Fn+E arrive the same way, as an insertion.

**Preedit display.**
- Draw the composing string over the cell at the cursor, underlined.
- xterm 4 does this with `composingText` passed to the renderer.
- xterm2 keeps it on the active row at the right edge.
- The renderer needs a `composingText` input.

**Candidate window position.** This is where xterm and xterm2 are both buggy. Each calls `setEditableSizeAndTransform(rect.size, Matrix4.translationValues(0,0,0))`, an identity transform (`X/ui/custom_text_edit.dart`, `setEditableRect`; same in `X2/.../custom_text_edit.dart:125-136`), so the IME window lands at the window origin whenever the view is not at (0, 0). Do what `EditableText` does [V `F/widgets/editable_text.dart:4999-5129`]:
- `setEditableSizeAndTransform(size, renderBox.getTransformTo(null))`;
- `setComposingRect(cursorCellRect)`;
- `setCaretRect(cursorCellRect)`.

Call these after layout whenever the cursor cell, the font metrics or the transform change. A post-frame callback works, as EditableText does.

**Configuration:**

```dart
TextInputConfiguration(
  viewId: ..., inputType: keyboardType, inputAction: TextInputAction.newline,
  autocorrect: false, enableSuggestions: false, enableIMEPersonalizedLearning: false,
  smartDashesType: SmartDashesType.disabled, smartQuotesType: SmartQuotesType.disabled,
  textCapitalization: TextCapitalization.none, enableDeltaModel: true,
)
```

The fields exist in `F/services/text_input.dart:520-683` [V]. xterm sets the first three (`X/ui/custom_text_edit.dart`, `_openInputConnection`) but leaves smart quotes and dashes on, so iOS can turn `"` into `"`.

---

## 3. Mobile soft keyboard

**Showing and hiding.**
- Show it with `TextInputConnection.show()` when the view gains focus or is tapped. Hide it by closing the connection.
- xterm exposes `requestKeyboard()` and `closeKeyboard()` on `TerminalViewState`, and opens the connection on focus via `consumeKeyboardToken` (`X/ui/custom_text_edit.dart`).
- It also has a `hardwareKeyboardOnly` flag (no connection, `CustomKeyboardListener`) and a `readOnly` flag.
- Mirror all of these.
- Handle insets from `MediaQuery.viewInsets` by resizing the grid and scrolling to the cursor. xterm calls `_scrollToBottom` on keyboard show. xterm #212 (2025-12, open): the view is shifted down on Android and iOS because of `MediaQuery` padding.

**Missing keys (Esc, Ctrl, Alt, Tab, arrows).**
- **Termux** (`termux-shared/.../TermuxPropertyConstants.java:329`, read with `gh api`) [V]:
  - Two default rows: `ESC / - HOME UP END PGUP` and `TAB CTRL ALT LEFT DOWN RIGHT PGDN`.
  - Ctrl and Alt are sticky toggles.
  - `-` has a popup that gives `|`.
  - Users configure the rows with `extra-keys` in `termux.properties`.
- **Blink**: the "Smart Keys" bar has sticky Ctrl and Alt plus Esc, and hides when a hardware keyboard is connected. Sources: docs.blink.sh/basics/customize and the blinksh/blink wiki, via web search on 2026-11-09 [V, secondary].
- **a-Shell**: not verified.

Recommendation for v1: ship a separate, optional `TerminalKeyToolbar` widget (not built into the view), backed by a controller API for sticky modifiers. The view consults the sticky modifiers when it encodes the next key or the next IME insertion: Ctrl plus a letter becomes `VtKeyEvent(key, ctrl)`. xterm has no toolbar. Issue #141 (closed, 2022) asked for Ctrl on soft keyboards.

**Autocorrect and suggestions off.** Use the configuration above. Termux uses `InputType.TYPE_NULL`, or falls back to `TYPE_TEXT_VARIATION_VISIBLE_PASSWORD | TYPE_TEXT_FLAG_NO_SUGGESTIONS` when "enforce char-based input" is on (`terminal-view/.../TerminalView.java:308-341`) [V]. Flutter has no `TYPE_NULL`. The closest is `TextInputType.visiblePassword` with `enableSuggestions: false`.
- [I] Flutter's Android `TextInputPlugin` maps `visiblePassword` to `TYPE_TEXT_VARIATION_VISIBLE_PASSWORD` and `enableSuggestions: false` to `NO_SUGGESTIONS`. Verify in the engine source.
- xterm defaults to `TextInputType.emailAddress` (`X/terminal_view.dart:42`).
- Recommended default: `visiblePassword` on Android, `text` elsewhere. Expose `keyboardType` and `keyboardAppearance` as xterm does.

**Backspace on an empty buffer.** Many Android IMEs (AOSP, Gboard) send no key event and no deletion when the editable is empty.
- xterm #201 "Backspace doesn't work on AOSP-based keyboards" (2024-08, open); #204 (iOS, 2025-05, closed); #11 (2021).
- **Fix:** keep a sentinel in the editing state, so there is always something to delete. xterm's `deleteDetection: true` uses the text `'  '` with the caret at 2 (`X/ui/custom_text_edit.dart`, `_initEditingState`). It defaults to `false`; ours should default to `true` on Android and iOS.
- On any shrink or deletion delta, send Backspace (`VtKey.backspace` through the encoder, which respects DECBKM), then restore the sentinel.
- Samsung sends `deleteSurroundingText(n > 1)`. Termux sends n key events for it (`TerminalView.java`, `deleteSurroundingText`) [V]. Do the same: one Backspace per deleted grapheme.
- The AOSP keyboard sends `\n` as text. Map Enter to `\r` (Termux does this in `sendTextToTerminal`). Also handle `performAction(newline)`, as xterm does.

---

## 4. Mouse and touch

**Encoder contract** (`input/mouse_encoder.dart`, `input/mouse.dart`) [V]:
- Positions are surface pixels, padding included.
- Call `configure(size: MouseEncoderSize(...))` on every layout or font change, and `configure(anyButtonPressed:)` on every button change.
- Call `setFromTerminal()` before encoding.
- `encode()` returns empty bytes when tracking is off or the event kind is not reported. The tracking modes are DEC 9, 1000, 1002 and 1003; the formats are X10, UTF-8, SGR, URxvt and SGR-Pixels.
- Wheel events are buttons 4–7, with `MouseAction.press`.
- `trackLastCell` drops motion that stays in the same cell.

**Pointer mapping:**

| Flutter | `VtMouseEvent` |
|---|---|
| `PointerDownEvent` | press, button from `event.buttons` (`kPrimaryButton`, `kSecondaryButton`, `kMiddleMouseButton`, `kBackMouseButton`) |
| `PointerUpEvent` | release |
| `PointerMoveEvent` / `PointerHoverEvent` | motion |
| `PointerScrollEvent.scrollDelta` | wheel, one report per line-height of accumulated delta |
| `PointerPanZoomUpdateEvent.panDelta` (trackpads) | wheel, same accumulation |

- The pan-zoom classes are in `F/gestures/events.dart:1880-2417` [V].
- Use a `Listener`, not a `GestureDetector`, while tracking is on. xterm2's changelog says "Report mouse buttons immediately without gesture-recognizer delays".
- Modifiers come from `HardwareKeyboard`.

**Who gets the mouse.** When `vt.isMouseTracking` is true (`terminal.dart:478`), events go to the program. Selection then needs **Shift held**, which bypasses reporting: xterm2 `shiftOverridesMouseReporting`, Ghostty's default. The C API has no shift-capture option (no `shift` in `mouse/encoder.h` or `terminal.h`) [V], so the widget implements it.

**Wheel routing** (xterm2 5.4.0 changelog) [V]:
- Mouse tracking on: send wheel reports.
- Alternate screen with tracking off:
  - if DEC **1007** (`GHOSTTY_MODE_MOUSE_ALTERNATE_SCROLL`, `modes.h:78`) is set, send up and down arrow keys through the `KeyEncoder`, which is what xterm's `simulateScroll` does (`X/ui/scroll_handler.dart`);
  - otherwise do nothing.
- Primary screen: scroll the viewport.
- Shift+wheel always scrolls the scrollback.

**Selection gestures.** `SelectionGesture` (`selection/selection_gesture.dart`) [V] implements Ghostty's behaviour:
- `press(cell, position:, time:)` counts single, double and triple clicks (cells, words, lines), given `repeatInterval` and `repeatDistance`. Use `kDoubleTapTimeout` (300 ms) and `kDoubleTapSlop`, or the platform values.
- `drag(cell, geometry:, rectangle: alt)` makes a block selection while Alt is held.
- `autoscroll` and `autoscrollTick()` from a timer during an edge drag.
- `release()`; `deepPress()` for force touch.
- The gesture never installs the selection: the widget assigns it with `terminal.selection = …`.
- Extras: `selectWord`, `selectLine` (with `semanticPromptBoundary`), `selectAll`, `selectOutput` (OSC 133).
- **Shift-click to extend** is not part of the gesture. Build it with `selectRange(currentSelection.start, clickedCell)`. xterm #205 (closed, 2025-05) added it to xterm.
- Copy with `TerminalFormatter(vt).formatText(selection:)` (see `example/main.dart`).
- [I] Matching the double click needs a monotonic time. `PointerEvent.timeStamp` is a `Duration` and works.

**Touch:**
- xterm maps long press to word select and long-press-move to extend, and double tap to word select (`X/ui/gesture/gesture_handler.dart:159-182`).
- It has **no selection handles and no mobile context menu**: xterm #217 (2026-02, open), and #241 (2026-08, custom double-tap).
- Recommended for v1: long press selects a word, a drag extends it, and `contextMenuBuilder` takes an `EditableTextState`-free builder that shows Copy, Paste and Select all.
  - The widget package should depend only on `widgets`. The demo can supply `AdaptiveTextSelectionToolbar.buttonItems`.
- Defer draggable selection handles to v1.1.
- Two-finger scroll is not a terminal concept on touch. A one-finger vertical drag scrolls the scrollback, or sends arrows or wheel reports on the alternate screen, as xterm does. Two-finger pan and zoom can map to font size later.

**Right click and `SelectionArea`:**
- Right click: when tracking is on, report it to the program (unless Shift is held). Otherwise fire `onSecondaryTapDown`/`Up` (xterm has these callbacks) or open the context menu.
- On the web, call `BrowserContextMenu.disableContextMenu()` while the view is hovered (`F/services/browser_context_menu.dart`) [V].
- **Do not take part in `SelectionArea`.** The terminal owns its own selection model. Wrap the view so that an ancestor `SelectionArea` does not grab drags. [I] `SelectionContainer.disabled` should do it.

---

## 5. Scrolling

**APIs** [V]:
- `vt.scrollbar` returns a `ViewportScrollbar(total, offset, length, isAtBottom)`. The dartdoc says it is cheap: "poll it once per frame" (`terminal.dart:590`).
- `vt.scrollViewport(ViewportScroll.top() | .bottom() | .delta(n) | .row(r) | .prompts(n))`. `.prompts` jumps between shell prompts.

**Probe on 2026-11-09** [V]:
- A 20×5 terminal after 50 lines: `total 51, offset 46`.
- After `delta(-10)`: `offset 36`.
- After 5 more lines of output: `total 56`, **offset still 36**. libghostty pins a scrolled-up viewport by itself, so no anchoring work is needed.
- After `ESC[?1049h` (alternate screen): `total 5, offset 0`. The alternate screen has no scrollback.

**Recommendation:**
- Keep the viewport position in libghostty, not in a Flutter `ScrollPosition`. xterm's `InfiniteScrollView` and `Scrollable` approach causes its scroll bugs:
  - #243 (2026-09): gestures die when the `ScrollPosition` is replaced.
  - #239 (2026-08): alternate-screen scroll detaches lines.
  - #222 (2026-03): `scrollUp` corrupts the circular buffer.
- Drive scrolling from pointer deltas, with fractional-row accumulation.
- For momentum on touch and trackpads, use a `ScrollPhysics`/`Simulation` (`ClampingScrollSimulation` or `BouncingScrollSimulation` for each platform) ticking a `Ticker`.
- Draw a thin custom scrollbar from `ViewportScrollbar`, so the Material `Scrollbar` and its `ScrollController` coupling are not needed.
- Snap to the bottom on user input. Make this an option: xterm #218 (2026-02, open) asks for it. xterm's adapter `scrollController` parameter becomes ⚠️ (see §8).

---

## 6. Accessibility

[V] xterm 4.0.0 and xterm2 5.4.0 contain no `Semantics` widget (`grep -rl Semantics` finds only `gesture_detector.dart`, which is recognizers, not semantics nodes). xterm.dart has no accessibility issue filed.

**Minimal useful v1:**
1. Wrap the view in `Semantics(textField: true, multiline: true, readOnly: false, focused: …, label: title)` with `value` set to the visible text of the viewport. Get the text from `TerminalFormatter` over the viewport rows, throttled to about 2 Hz and only while `MediaQuery.accessibleNavigation` is true, so it costs nothing otherwise.
2. Announce new output with `SemanticsService.sendAnnouncement`. `announce` is `@Deprecated` in 3.47.9 (`F/semantics/semantics_service.dart:51-81`) [V]. Announcements are debounced and limited to the newly written lines. Or use `liveRegion: true` on a child that holds the last line: a polite announcement on Android and iOS (`F/semantics/semantics.dart:1948`) [V].

Recommendation: ship (1) in v1, because it is cheap and pana and users notice it. Put (2) behind an `announceOutput` flag, off by default. Defer full screen-reader navigation (cursor review, line by line) and record that in an ADR.

---

## 7. PTY

pub.dev API, `GET /api/packages/<name>` and `/score`, 2026-11-09 [V]:

| Package | Latest (date) | Platforms | Native build | Licence | Notes |
|---|---|---|---|---|---|
| `flutter_pty` | 0.4.2 (2025-01-06) | Android, iOS, Linux, macOS, Windows | **Flutter ffiPlugin (CMake compiles C on the user's machine)** | MIT | TerminalStudio, used by xterm's example. **ConPTY on Windows** (`CreatePseudoConsole`, `src/flutter_pty_win.c:312`). 150/160 points, about 11.1k downloads in 30 days. Last pushed 2025-01-06, 18 open issues. xterm #202: `flutter_pty.dll` error 127. |
| `pty2` | 0.8.0 (2026-11-04, **younger than the 3-day cooldown**) | Linux, macOS, Windows | Build hook + `native_toolchain_c` (compiles C) | MIT | jtmcdole/termui. ConPTY plus legacy pipes, and `forkpty` on Unix. 160/160, about 35.7k downloads in 30 days. Dart CLI and Flutter. No mobile. |
| `flutter_pty2` | 3.0.0 (2026-10-21) | Android, iOS, Linux, macOS, Windows | Build hook + `native_toolchain_c` (needs clang, gcc or MSVC) | MIT | SoFluffyOS. 150/160, 489 downloads in 30 days. Its page says some operations are unsupported on Windows. |
| `portable_pty` | 0.0.5 (2026-05-02) | Native + web (WebSocket/WebTransport to a remote pty server) | Build hook + `native_toolchain_rust` (**compiles Rust crates**) | MIT | kingwill101. 130/160, 157 downloads in 30 days. |
| `pty` / `dart_pty` | 0.1.1 (2021) / 0.0.4 (2021) | – | – | – | Dead: Dart 2 SDK constraint. |
| `dartssh2` | 4.1.0 (2026-09-04) | All, web included | Pure Dart | MIT | 160/160, about 107k downloads in 30 days. SSH, the common remote alternative. |

**Every local PTY package compiles native code on the user's machine** (CMake, a C build hook or a Rust build hook). Under our supply-chain rules this is build-time third-party code, so:

- **The widget must not depend on a PTY package.** Confirmed. Keep it pty-agnostic:
  - Input: the app calls `controller.write(Uint8List)`, or the controller takes a `Stream<Uint8List>`.
  - Output: an `onOutput(Uint8List)` callback, which is `VtTerminal.onWritePty` re-exposed for both key input and terminal replies.
  - Resize: an `onResize(cols, rows, cellW, cellH)` callback.
  - This matches xterm's model (`onOutput` and `onResize`; earlier research doc §3) and keeps `ghostty_dart_flutter` free of native build steps beyond our own hook.
- **Demo app, native:** `flutter_pty` 0.4.2. It is the most proven, has ConPTY, and is older than the cooldown. Pin it in `pubspec.lock` and note in the PR that its CMake build runs on our CI machines. Alternative: `pty2`, desktop only, once 0.8.0 has aged past 2026-11-07. Document how users wire either one (and `dartssh2`) in the README.
- **Web demo (GitHub Pages, `--wasm`):** there is no backend, so use an **in-process fake shell**: a small Dart REPL that echoes, with `help`, `colors` (an SGR and 256-colour showcase), `vttest`-style demos, `cat` of a bundled ANSI art file, and `top`-like alternate-screen animation, all pure Dart. A WebSocket echo needs a server we would have to host and secure, so treat it as optional and later.

---

## 8. API shape

**What xterm 4.0.0 has** (earlier research doc §3; `X/terminal_view.dart`; `X/ui/controller.dart`) [V]:
- `Terminal` is the **model**:
  - `write(String)`, `keyInput`, `textInput`, `paste`, `resize`;
  - `onOutput`, `onBell`, `onTitleChange`, `onResize`;
  - `buffer`;
  - it is `Observable`.
- xterm's `TerminalController` is **only selection and highlights**: `selection`, `setSelection`, `clearSelection`, `highlights`, `pointerInput`, `suspendedPointerInputs`.
- `TerminalView(terminal, {controller, theme, textStyle, padding, scrollController, autofocus, focusNode, keyboardType, shortcuts, onKeyEvent, readOnly, hardwareKeyboardOnly, deleteDetection, simulateScroll, cursorType, alwaysShowCursor, backgroundOpacity, onTapUp, onSecondaryTapDown/Up, mouseCursor, textScaler, autoResize})`.

**Naming** (conventions §11: use `Vt` when the bare name collides with xterm): the adapter will export xterm's `Terminal`, `TerminalController`, `TerminalView` and `TerminalTheme`, so ours must be prefixed:
- **`VtTerminalController`** (a `ChangeNotifier`);
- **`VtTerminalView`**;
- **`VtTerminalTheme`**.

A user importing both packages then sees no clash.

**`VtTerminalController` owns `VtTerminal`, `RenderState`, `KeyEncoder`, `MouseEncoder` and one `SelectionGesture`, and exposes:**
- **Construction:** `VtTerminalController({int maxScrollbackBytes, …})`, or `adopt(VtTerminal)`.
- **Ownership:** `dispose()` frees everything it created.
- **Data in:** `write(Uint8List)`, `writeString(String)`, `attach(Stream<Uint8List>)`.
- **Data out:** `onOutput`, which is `onWritePty`, buffered. Writing back from inside a callback throws, so queue and flush after `write` returns, as `example/main.dart` warns.
- **Effects** as `ValueListenable`s or callbacks:
  - `title` / `onTitleChanged`, `onBell`, `onPwdChanged`;
  - `onClipboardWrite` and `onClipboardRead` (OSC 52), opt-in;
  - `onDesktopNotification`;
  - `mouseShape`.
- **Size:** `resize(cols, rows, cellPx)`, called by the view. `onResize` lets the app resize the pty.
- **Input** (the adapter needs these):
  - `sendKey(VtKeyEvent)`;
  - `sendText(String)`;
  - `paste(String)` returning `PasteResult`, with an unsafe-paste confirmation hook;
  - `sendMouse(VtMouseEvent)`;
  - `sendFocus(bool)`, which sends only when mode 1004 is set.
- **Selection:**
  - `selection`, `selectRange`, `selectWord`, `selectLine`, `selectAll`, `clearSelection`;
  - `selectedText` (via `TerminalFormatter`);
  - `ValueListenable<VtSelection?>`.
- **Viewport:** `scrollbar`, `scrollTo(ViewportScroll)`, `isAlternateScreen`.
- **Search:** a `TerminalSearch` wrapper with incremental `step()` per frame and highlight ranges.
- **Modes:** `isModeEnabled`, `isMouseTracking`, `kittyFlags`.
- **Notifications:** notify listeners at most once per frame, coalescing writes, and expose dirty-row info for the painter.

**`VtTerminalView(controller, {theme, textStyle/fontFamily+fontSize, padding, autofocus, focusNode, readOnly, hardwareKeyboardOnly, keyboardType, keyboardAppearance, deleteDetection (default true on mobile), shortcuts, onKeyEvent (pre-handler, like xterm), macosOptionAsAlt, cursorStyle override, cursorBlink, backgroundOpacity, mouseCursor, onSecondaryTap*, contextMenuBuilder, scrollOnInput, shiftOverridesMouse (true), semanticsMode})`.**
- `VtTerminalViewState` exposes `requestKeyboard()` and `closeKeyboard()`, as xterm does.

**So that the adapter stays thin:**
- Key input by xterm `TerminalKey` plus bools. The adapter maps about 270 `TerminalKey` values to `VtKey`, a static table. We must accept a `VtKeyEvent` without a platform event: `sendKey`.
- `textInput` and `charInput` map to `sendText`.
- String `write` maps to `writeString`. UTF-8 is decoded incrementally; libghostty takes bytes, so the adapter encodes.
- xterm `Buffer`/`BufferLine` reads (cell access, `getText(BufferRange)`) need a **read API over grid points**:
  - the controller exposes the `VtTerminal` (it is public) and a `TerminalFormatter`;
  - the adapter builds the xterm `Buffer` lazily from the grid/render APIs, and `COMPATIBILITY.md` marks it ⚠️.
- `onResize(w, h, pw, ph)` maps directly.
- `TerminalController.setSelection(CellAnchor, CellAnchor, mode)` maps to `selectRange` and `TrackedGridRef` (`selectTrackedRange`).
- `highlights` map to a controller `highlights` list, which the painter needs anyway for search.
- `scrollController` and `simulateScroll` are ⚠️. Offer a `ScrollController`-shaped shim, or document the difference.
- xterm's default shortcut map (Ctrl+V and Ctrl+A on Linux/Windows) is applied by the adapter only (§1.6).

---

## Open items for the planner
1. Check on the macOS CI runner how `macosOptionAsAlt` behaves with `text` and `unshiftedCodepoint` (§1.2).
2. Check delta-model support and the sentinel backspace on an Android emulator (Gboard, AOSP) and an iOS simulator.
3. Check Flutter's Android `TextInputPlugin` mapping for `visiblePassword` and `enableSuggestions` in the engine source.
4. Check the logical-key fallback for non-Latin layouts (`unshiftedCodepoint` for the Kitty protocol).
5. ADR candidates:
   - the widget is pty-agnostic;
   - the default shortcut map diverges from xterm;
   - accessibility scope for v1;
   - the viewport lives in libghostty, not in a `ScrollPosition`.
