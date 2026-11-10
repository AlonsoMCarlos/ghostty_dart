/// @docImport '../../view/terminal_view.dart';
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../../controller/terminal_controller.dart';
import '../../seams/controller_seams.dart';

/// A row of keys that soft keyboards lack (Esc, Ctrl, Alt, Tab and the
/// arrows), for mobile. Ctrl and Alt latch: they apply to the next key or
/// character typed in the [controller]'s view, or to the next toolbar key,
/// and then release. Tap a latched key again to release it.
///
/// Place it next to the [VtTerminalView] of the same [controller], for
/// example above the soft keyboard:
///
/// ```dart
/// Column(
///   children: [
///     Expanded(child: VtTerminalView(controller: controller)),
///     VtTerminalKeyToolbar(controller: controller),
///   ],
/// )
/// ```
///
/// The keys never take the focus, so the soft keyboard stays open. Keys
/// are encoded for the terminal's current modes (cursor key application
/// mode, the Kitty keyboard protocol), like hardware keys. It draws plain
/// text on a transparent background in the ambient [DefaultTextStyle];
/// wrap it in your own decoration. The labels (`Esc`, `Ctrl`, `Alt`,
/// `Tab`, arrow glyphs that the ambient font must cover) and their
/// semantic labels are English for now.
///
/// Set [readOnly] to match a read-only [VtTerminalView]: the keys then send
/// nothing.
class VtTerminalKeyToolbar extends StatefulWidget {
  /// A toolbar that sends its keys to [controller].
  const VtTerminalKeyToolbar({
    super.key,
    required this.controller,
    this.height,
    this.latchedColor = defaultLatchedColor,
    this.readOnly = false,
  });

  /// The default [latchedColor]: 25 % grey, visible on light and dark
  /// backgrounds.
  static const defaultLatchedColor = Color(0x40808080);

  /// The terminal the keys go to.
  final VtTerminalController controller;

  /// The height of the row, in logical pixels. `null` uses the platform's
  /// minimum touch target: 44 on iOS and macOS (Apple's Human Interface
  /// Guidelines; Flutter's `kMinInteractiveDimensionCupertino`), 48
  /// elsewhere (Material's touch target; Flutter's
  /// `kMinInteractiveDimension`).
  final double? height;

  /// The fill of a latched Ctrl or Alt key; [defaultLatchedColor] unless
  /// given.
  final Color latchedColor;

  /// Whether the keys send nothing (the view is read-only).
  final bool readOnly;

  @override
  State<VtTerminalKeyToolbar> createState() => _VtTerminalKeyToolbarState();
}

class _VtTerminalKeyToolbarState extends State<VtTerminalKeyToolbar> {
  ControllerSeams? _seams;

  ControllerSeams? get _liveSeams {
    final controller = widget.controller;
    if (controller.isDisposed) return null;
    if (_seams?.controller != controller) _seams = ControllerSeams(controller);
    return _seams;
  }

  double get _height =>
      widget.height ??
      switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.macOS => 44,
        _ => 48,
      };

  void _send(VtKey key) {
    final seams = _liveSeams;
    if (seams == null || widget.readOnly) return;
    final latched = seams.latchedModifiers.value;
    seams.latchedModifiers.value = KeyModifiers.none;
    seams.sendKey(VtKeyEvent(key: key, modifiers: latched));
  }

  void _toggle(KeyModifiers modifier) {
    final seams = _liveSeams;
    if (seams == null || widget.readOnly) return;
    final latched = seams.latchedModifiers.value;
    seams.latchedModifiers.value = latched.containsAll(modifier)
        ? _without(latched, modifier)
        : latched | modifier;
  }

  /// [set] without [modifier]. Latches only hold Shift, Ctrl, Alt and
  /// Super, so the lock and right-side bits are not carried over.
  static KeyModifiers _without(KeyModifiers set, KeyModifiers modifier) =>
      KeyModifiers(
        shift: set.hasShift && !modifier.hasShift,
        ctrl: set.hasCtrl && !modifier.hasCtrl,
        alt: set.hasAlt && !modifier.hasAlt,
        superKey: set.hasSuper && !modifier.hasSuper,
      );

  @override
  Widget build(BuildContext context) {
    final seams = _liveSeams;
    if (seams == null) return SizedBox(height: _height);
    return SizedBox(
      height: _height,
      child: ValueListenableBuilder<KeyModifiers>(
        valueListenable: seams.latchedModifiers,
        builder: (context, latched, _) => Row(
          // A fixed key order (the arrows must not mirror), and no ambient
          // Directionality needed.
          textDirection: TextDirection.ltr,
          children: [
            _key('Esc', 'Escape', () => _send(VtKey.escape)),
            _key(
              'Ctrl',
              'Control',
              () => _toggle(KeyModifiers.ctrl),
              latched: latched.hasCtrl,
            ),
            _key(
              'Alt',
              'Alt',
              () => _toggle(KeyModifiers.alt),
              latched: latched.hasAlt,
            ),
            _key('Tab', 'Tab', () => _send(VtKey.tab)),
            _key('←', 'Left', () => _send(VtKey.arrowLeft)),
            _key('↓', 'Down', () => _send(VtKey.arrowDown)),
            _key('↑', 'Up', () => _send(VtKey.arrowUp)),
            _key('→', 'Right', () => _send(VtKey.arrowRight)),
          ],
        ),
      ),
    );
  }

  Widget _key(
    String label,
    String semanticLabel,
    VoidCallback onTap, {
    bool? latched,
  }) => Expanded(
    child: Semantics(
      button: true,
      toggled: latched,
      label: semanticLabel,
      textDirection: TextDirection.ltr,
      container: true,
      child: GestureDetector(
        key: ValueKey('ghostty_dart_flutter.toolbar.$semanticLabel'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ColoredBox(
          color: latched ?? false
              ? widget.latchedColor
              : const Color(0x00000000),
          child: Center(
            child: ExcludeSemantics(
              child: Text(label, textDirection: TextDirection.ltr),
            ),
          ),
        ),
      ),
    ),
  );
}
