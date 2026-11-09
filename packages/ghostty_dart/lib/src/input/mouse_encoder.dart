/// The mouse encoder (`mouse/encoder.h`): turns [VtMouseEvent]s into mouse
/// reports in the X10, UTF-8, SGR, URxvt or SGR-Pixels format.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../terminal/terminal.dart';
import 'encode_buffer.dart';
import 'mouse.dart';

/// Encodes mouse events into terminal mouse reports
/// (`GhosttyMouseEncoder`), following the tracking mode and format the
/// program asked for.
///
/// ```dart
/// final encoder = MouseEncoder()
///   ..configure(
///     size: const MouseEncoderSize(
///       screenWidth: 800, screenHeight: 480, cellWidth: 10, cellHeight: 20,
///     ),
///   )
///   ..setFromTerminal(terminal);
/// final bytes = encoder.encode(const VtMouseEvent(
///   action: MouseAction.press, button: MouseButton.left, x: 15, y: 25,
/// )); // e.g. ESC [ < 0 ; 2 ; 2 M with SGR mode on
/// if (bytes.isNotEmpty) pty.write(bytes);
/// ```
///
/// Events produce no output (an empty list) while the program has not
/// enabled mouse tracking, or when the tracking mode does not report that
/// kind of event.
///
/// ## Ownership
///
/// The encoder owns a native encoder, a native mouse event that it reuses
/// for every [encode], and a reusable output buffer, so encoding allocates
/// no native memory. Call [dispose] when done; a finalizer frees everything
/// if you forget. After [dispose], every member except [isDisposed] and
/// [dispose] throws [StateError]. The encoder does not keep a reference to
/// any terminal.
final class MouseEncoder implements Finalizable {
  /// Creates an encoder with default options: tracking off
  /// ([MouseTrackingMode.none]), [MouseFormat.x10], a 1×1 pixel screen with
  /// 1×1 pixel cells, no button pressed, no motion deduplication.
  ///
  /// Throws [GhosttyException] if the library fails to allocate it and
  /// [IncompatibleLibraryException] if the loaded libghostty-vt is not a
  /// supported 1.x version.
  MouseEncoder() : _handle = _createEncoder() {
    try {
      _event = _createEvent();
    } catch (_) {
      _handle.dispose();
      rethrow;
    }
    bindHandle(this, _handle);
    _handle
      ..addCleanup(_event.dispose)
      ..addCleanup(_output.dispose);
  }

  static final _encoderFinalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttyMouseEncoder)>>(
      ghostty_mouse_encoder_free,
    ).cast(),
  );

  static final _eventFinalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttyMouseEvent)>>(
      ghostty_mouse_event_free,
    ).cast(),
  );

  static NativeHandle<GhosttyMouseEncoderImpl> _createEncoder() => NativeHandle(
    createNative<GhosttyMouseEncoderImpl>(
      'ghostty_mouse_encoder_new',
      (out) => ghostty_mouse_encoder_new(nullptr, out),
    ),
    typeName: 'MouseEncoder',
    free: (p) => ghostty_mouse_encoder_free(p),
    finalizer: _encoderFinalizer,
  );

  static NativeHandle<GhosttyMouseEventImpl> _createEvent() => NativeHandle(
    createNative<GhosttyMouseEventImpl>(
      'ghostty_mouse_event_new',
      (out) => ghostty_mouse_event_new(nullptr, out),
    ),
    typeName: 'MouseEncoder',
    free: (p) => ghostty_mouse_event_free(p),
    finalizer: _eventFinalizer,
  );

  final NativeHandle<GhosttyMouseEncoderImpl> _handle;
  late final NativeHandle<GhosttyMouseEventImpl> _event;
  final EncodeBuffer _output = EncodeBuffer();

  /// The event last copied into the native event, so [encode] only calls
  /// the setters for fields that changed. `null` until the first [encode].
  VtMouseEvent? _applied;

  /// The size last accepted by the library, used to clamp positions (see
  /// [_clampPosition]).
  MouseEncoderSize _size = _defaultSize;

  /// The library's default size (`mouse/encoder.h`).
  static const _defaultSize = MouseEncoderSize(
    screenWidth: 1,
    screenHeight: 1,
    cellWidth: 1,
    cellHeight: 1,
  );

  /// The largest pixel value [configure] accepts for a size field, and the
  /// magnitude positions are clamped to. Integers up to 2^24 are exact in
  /// the native `float` position, and the library's conversions to `u16`
  /// cells and `i32` pixels stay in range below it.
  static const _maxPixels = 1 << 24;

  /// The most cells per row or column the library's `u16` grid can hold.
  static const _maxCells = 0xFFFF;

  /// Whether [dispose] has been called.
  bool get isDisposed => _handle.isDisposed;

  /// Sets encoder options. Only the arguments you pass change; the others
  /// keep their current values.
  ///
  /// - [trackingMode]: which events are reported (from the terminal's
  ///   modes; prefer [setFromTerminal]).
  /// - [format]: how reports are encoded (also from the terminal).
  /// - [size]: the rendered geometry, used to turn pixels into cells. Set it
  ///   whenever the view or font size changes; the terminal does not know it.
  /// - [anyButtonPressed]: whether any mouse button is currently held. Keep
  ///   it up to date: button-event tracking reports motion only while a
  ///   button is held.
  /// - [trackLastCell]: drop motion events that stay in the same cell as
  ///   the last reported one.
  ///
  /// Validates everything before changing anything: throws [ArgumentError]
  /// for `unknown` enum values and [RangeError] for [size] values outside
  /// 0–2^24 (16777216) pixels, a zero cell dimension, or a screen more than
  /// 65535 cells wide or high. These limits are stricter than the C
  /// `uint32_t` fields because larger values overflow the library's
  /// internal float-to-integer conversions. A [GhosttyException] means the
  /// library rejected a value; options set before it keep their new value.
  void configure({
    MouseTrackingMode? trackingMode,
    MouseFormat? format,
    MouseEncoderSize? size,
    bool? anyButtonPressed,
    bool? trackLastCell,
  }) {
    final rawMode = trackingMode == null
        ? null
        : mouseTrackingModeCodec.encode(trackingMode);
    final rawFormat = format == null ? null : mouseFormatCodec.encode(format);
    if (size != null) _checkSize(size);
    final encoder = _handle.pointer;
    withScratch(sizeOf<GhosttyMouseEncoderSize>(), (memory) {
      void setInt(int option, int? value) {
        if (value == null) return;
        memory.cast<Int32>().value = value;
        _set(encoder, option, memory.cast());
      }

      void setBool(int option, bool? value) {
        if (value == null) return;
        memory.cast<Bool>().value = value;
        _set(encoder, option, memory.cast());
      }

      setInt(_Option.event, rawMode);
      setInt(_Option.format, rawFormat);
      setBool(_Option.anyButtonPressed, anyButtonPressed);
      setBool(_Option.trackLastCell, trackLastCell);
      if (size != null) {
        final native = memory.cast<GhosttyMouseEncoderSize>();
        _writeSize(native, size);
        _set(encoder, _Option.size, native.cast());
        _sizeChanged(size);
      }
    });
  }

  /// Puts every option back to its default, as on a new encoder (see the
  /// constructor).
  void resetOptions() {
    final encoder = _handle.pointer;
    for (final option in _Option.all) {
      _set(encoder, option, nullptr);
    }
    _sizeChanged(_defaultSize);
  }

  /// Copies the mouse tracking mode and format of [terminal] into the
  /// encoder, and clears the motion deduplication state (as [reset] does).
  /// The size and `anyButtonPressed` options are not changed.
  ///
  /// Call it before encoding whenever the terminal may have received output
  /// since the last call. The terminal is read once; no reference to it is
  /// kept. Throws [StateError] if either object is disposed.
  void setFromTerminal(VtTerminal terminal) {
    final terminalPointer = handleOf<GhosttyTerminalImpl>(terminal).pointer;
    checkResult(
      ghostty_mouse_encoder_set_from_terminal(_handle.pointer, terminalPointer),
      'ghostty_mouse_encoder_set_from_terminal',
    );
  }

  /// Clears the motion deduplication state (the last reported cell), so the
  /// next motion event is reported even if it is in the same cell.
  void reset() => checkResult(
    ghostty_mouse_encoder_reset(_handle.pointer),
    'ghostty_mouse_encoder_reset',
  );

  /// Encodes [event] with the current options and returns the bytes to send
  /// to the pty, or an empty list if the event is not reported.
  ///
  /// Positions far outside the screen are clamped to a range the library
  /// can convert safely (at most 2^24 pixels, and no further right or down
  /// than the 65535th cell); they still report as outside the viewport.
  ///
  /// Throws [ArgumentError] for `unknown` action or button values or a
  /// non-finite (NaN or infinite) position, and [StateError] after
  /// [dispose].
  Uint8List encode(VtMouseEvent event) {
    _apply(event);
    final encoder = _handle.pointer;
    final nativeEvent = _event.pointer;
    return _output.encode(
      'ghostty_mouse_encoder_encode',
      (buffer, capacity, written) => ghostty_mouse_encoder_encode(
        encoder,
        nativeEvent,
        buffer,
        capacity,
        written,
      ),
    );
  }

  /// Frees the encoder and its buffers. Safe to call more than once.
  void dispose() => _handle.dispose();

  /// Copies the fields of [event] that differ from [_applied] into the
  /// native event. Validates everything first, so a bad event leaves the
  /// native event unchanged.
  void _apply(VtMouseEvent event) {
    _handle.checkNotDisposed();
    final previous = _applied;
    if (previous == event) return;
    final action = mouseActionCodec.encode(event.action);
    final button = event.button;
    final rawButton = button == null ? null : mouseButtonCodec.encode(button);
    _checkFinite(event.x, 'event.x');
    _checkFinite(event.y, 'event.y');
    final p = _event.pointer;
    // Forget the cache first: if a setter throws, the next encode must set
    // every field again.
    _applied = null;
    if (previous?.action != event.action) {
      checkResult(
        ghostty_mouse_event_set_action(p, action),
        'ghostty_mouse_event_set_action',
      );
    }
    if (previous == null || previous.button != button) {
      _setButton(p, rawButton);
    }
    if (previous?.modifiers != event.modifiers) {
      checkResult(
        ghostty_mouse_event_set_mods(p, keyModifiersToRaw(event.modifiers)),
        'ghostty_mouse_event_set_mods',
      );
    }
    if (previous?.x != event.x || previous?.y != event.y) {
      _setPosition(p, event.x, event.y);
    }
    _applied = event;
  }

  /// Records [size] and forgets the cached event, whose native position
  /// was clamped for the previous size.
  void _sizeChanged(MouseEncoderSize size) {
    _size = size;
    _applied = null;
  }

  /// Sets the native event's button, or clears it for a `null` [rawButton]
  /// (no button, as for plain motion).
  static void _setButton(Pointer<GhosttyMouseEventImpl> event, int? rawButton) {
    if (rawButton == null) {
      checkResult(
        ghostty_mouse_event_clear_button(event),
        'ghostty_mouse_event_clear_button',
      );
    } else {
      checkResult(
        ghostty_mouse_event_set_button(event, rawButton),
        'ghostty_mouse_event_set_button',
      );
    }
  }

  /// Sets the native event's position to ([x], [y]), clamped for the
  /// current size (see [_clampPosition]).
  void _setPosition(Pointer<GhosttyMouseEventImpl> event, double x, double y) {
    withScratch(sizeOf<GhosttyMousePosition>(), (memory) {
      final position = memory.cast<GhosttyMousePosition>().ref
        ..x = _clampPosition(x, _size.paddingLeft, _size.cellWidth)
        ..y = _clampPosition(y, _size.paddingTop, _size.cellHeight);
      checkResult(
        ghostty_mouse_event_set_position(event, position),
        'ghostty_mouse_event_set_position',
      );
    });
  }

  /// Rejects NaN and infinities: they reach float-to-integer conversions in
  /// the library that are undefined for them (garbage coordinates in the
  /// report).
  static void _checkFinite(double value, String name) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, name, 'must be finite');
    }
  }

  /// Clamps one coordinate so the library's conversions stay defined: the
  /// cell index (`(position - padding) / cell`) must fit its `u16` grid and
  /// the pixel value its `i32`. The upper bound is still beyond the screen
  /// ([_checkSize] keeps the screen within 65535 cells), so a clamped
  /// position stays outside the viewport.
  static double _clampPosition(double position, int padding, int cell) {
    final upper = math.min(padding + _maxCells * cell, _maxPixels);
    return position.clamp(-_maxPixels, upper).toDouble();
  }

  /// Checks [size] against the limits documented on [configure]: every
  /// field within 0–[_maxPixels], non-zero cells, and a screen of at most
  /// [_maxCells] cells per axis.
  static void _checkSize(MouseEncoderSize size) {
    void check(int value, String name, {int min = 0}) =>
        RangeError.checkValueInInterval(value, min, _maxPixels, name);
    check(size.screenWidth, 'screenWidth');
    check(size.screenHeight, 'screenHeight');
    check(size.cellWidth, 'cellWidth', min: 1);
    check(size.cellHeight, 'cellHeight', min: 1);
    check(size.paddingTop, 'paddingTop');
    check(size.paddingBottom, 'paddingBottom');
    check(size.paddingLeft, 'paddingLeft');
    check(size.paddingRight, 'paddingRight');
    RangeError.checkValueInInterval(
      size.screenWidth,
      0,
      _maxCells * size.cellWidth,
      'screenWidth',
      'more than $_maxCells cells wide',
    );
    RangeError.checkValueInInterval(
      size.screenHeight,
      0,
      _maxCells * size.cellHeight,
      'screenHeight',
      'more than $_maxCells cells high',
    );
  }

  /// Fills the sized struct [native] from [size].
  static void _writeSize(
    Pointer<GhosttyMouseEncoderSize> native,
    MouseEncoderSize size,
  ) {
    native.initSized(sizeOf<GhosttyMouseEncoderSize>());
    native.ref
      ..screen_width = size.screenWidth
      ..screen_height = size.screenHeight
      ..cell_width = size.cellWidth
      ..cell_height = size.cellHeight
      ..padding_top = size.paddingTop
      ..padding_bottom = size.paddingBottom
      ..padding_left = size.paddingLeft
      ..padding_right = size.paddingRight;
  }

  static void _set(
    Pointer<GhosttyMouseEncoderImpl> encoder,
    int option,
    Pointer<Void> value,
  ) => checkResult(
    ghostty_mouse_encoder_set(encoder, option, value),
    'ghostty_mouse_encoder_set',
  );
}

/// `GhosttyMouseEncoderOption` values.
abstract final class _Option {
  static const event =
      GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_EVENT;
  static const format =
      GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_FORMAT;
  static const size = GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_SIZE;
  static const anyButtonPressed =
      GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED;
  static const trackLastCell =
      GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL;

  static const all = [event, format, size, anyButtonPressed, trackLastCell];
}
