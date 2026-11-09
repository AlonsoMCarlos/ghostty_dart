/// The optional `color` build feature that every colour utility needs.
library;

import '../core/core.dart';
import '../core/internal.dart';

/// Whether the loaded library was built with the colour utilities. Read once:
/// the build cannot change while the process runs.
final bool _hasColorFeature = libghosttyVtBuildInfo.supports(VtFeature.color);

/// Throws [UnsupportedError] if the library was built without the `color`
/// feature, in which case the native colour functions return zeros or empty
/// tables instead of failing. Also runs the library version check.
void ensureColorFeature(String operation) {
  ensureCompatibleLibrary();
  if (!_hasColorFeature) {
    throw UnsupportedError(
      '$operation needs a libghostty-vt built with the color feature',
    );
  }
}
