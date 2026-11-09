// Helpers shared by the Kitty graphics test files.

import 'package:ghostty_dart/ghostty_dart.dart';

import '../support/terminal_support.dart';

/// Whether the loaded library was built with Kitty graphics.
final hasKittyGraphics = libghosttyVtBuildInfo.supports(
  VtFeature.kittyGraphics,
);

/// The `skip:` value for tests that need Kitty graphics.
final String? skipWithoutKitty = hasKittyGraphics
    ? null
    : 'built without Kitty graphics';

/// Runs [body] with a 20×10 terminal whose cells are 10×20 px, so
/// placements have a geometry, and disposes it afterwards.
R withKittyTerminal<R>(R Function(VtTerminal terminal) body) =>
    withTerminal(20, 10, (terminal) {
      terminal.resize(20, 10, cellWidthPx: 10, cellHeightPx: 20);
      return body(terminal);
    });
