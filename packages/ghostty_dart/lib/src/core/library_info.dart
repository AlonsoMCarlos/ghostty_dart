/// What the loaded libghostty-vt library is: its version, build options and
/// compiled-in features (`build_info.h`), plus the compatibility check every
/// native constructor runs.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../ffi/bindings.g.dart';
import 'enum_codec.dart';
import 'memory.dart';
import 'result.dart';

/// The full version of the loaded libghostty-vt library (`ghostty_version`),
/// such as `1.0.0` or `1.1.0-dev+abc1234`.
///
/// This is the library found at run time, which can differ from the 1.0.0
/// headers this package was generated from. Which library is loaded is
/// chosen by the build hook's `source` option.
///
/// {@category build-hook-options}
String get libghosttyVtVersion => ghostty_version().cast<Utf8>().toDartString();

/// The optimisation mode the library was compiled with
/// (`GhosttyOptimizeMode`).
enum OptimizeMode {
  /// Debug build: safety checks, no optimisation.
  debug(0),

  /// Optimised with safety checks.
  releaseSafe(1),

  /// Optimised for size.
  releaseSmall(2),

  /// Optimised for speed, without safety checks.
  releaseFast(3),

  /// A mode added by a later libghostty-vt release.
  unknown(null);

  const OptimizeMode(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyOptimizeMode` values to [OptimizeMode] and back.
final optimizeModeCodec = RawEnumCodec<OptimizeMode>(
  OptimizeMode.values,
  raw: (mode) => mode._raw,
  unknown: OptimizeMode.unknown,
);

/// An optional part of libghostty-vt that a build can leave out
/// (`GHOSTTY_BUILD_INFO_FEATURE_*` and `GHOSTTY_BUILD_INFO_KITTY_GRAPHICS`).
///
/// Calling an API of a missing feature throws [UnsupportedError].
enum VtFeature {
  /// Kitty graphics protocol (`%kitty_graphics`).
  kittyGraphics(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_KITTY_GRAPHICS),

  /// Terminal snapshots (`%snapshot`).
  snapshot(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_FEATURE_SNAPSHOT),

  /// Plain/VT/HTML formatting (`%formatter`).
  formatter(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_FEATURE_FORMATTER),

  /// Selection and selection gestures (`%selection`).
  selection(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_FEATURE_SELECTION),

  /// Search (`%search`).
  search(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_FEATURE_SEARCH),

  /// Render state (`%render_state`).
  renderState(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_FEATURE_RENDER_STATE),

  /// Key, mouse, focus and paste encoding (`%input_encode`).
  inputEncode(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_FEATURE_INPUT_ENCODE),

  /// Colour utilities (`%color`).
  color(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_FEATURE_COLOR),

  /// Grid refs, cells and rows (`%grid_introspection`).
  gridIntrospection(
    GhosttyBuildInfo.GHOSTTY_BUILD_INFO_FEATURE_GRID_INTROSPECTION,
  ),

  /// Ghostty's glyph protocol (`%glyph_protocol`).
  glyphProtocol(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_FEATURE_GLYPH_PROTOCOL);

  const VtFeature(this._key);

  final int _key;
}

/// How the loaded libghostty-vt library was built (`ghostty_build_info`).
///
/// The values are constant for the life of the process; read them through
/// [libghosttyVtBuildInfo], which queries the library once.
final class VtBuildInfo {
  VtBuildInfo._({
    required this.version,
    required this.major,
    required this.minor,
    required this.patch,
    required this.preRelease,
    required this.buildMetadata,
    required this.optimizeMode,
    required this.simd,
    required this.tmuxControlMode,
    required this.features,
  });

  /// The full version string, e.g. `1.0.0` or `1.1.0-dev+abc1234`.
  final String version;

  /// The major version number.
  final int major;

  /// The minor version number.
  final int minor;

  /// The patch version number.
  final int patch;

  /// The pre-release tag (e.g. `dev`), or empty for a release.
  final String preRelease;

  /// The build metadata (e.g. a commit hash), or empty.
  final String buildMetadata;

  /// The optimisation mode.
  final OptimizeMode optimizeMode;

  /// Whether SIMD-accelerated code paths are enabled.
  final bool simd;

  /// Whether tmux control mode support is available.
  final bool tmuxControlMode;

  /// The optional features compiled into this build (unmodifiable).
  final Set<VtFeature> features;

  /// Whether [feature] is compiled into this build.
  bool supports(VtFeature feature) => features.contains(feature);

  static VtBuildInfo _query() => using((arena) {
    final out = arena<Uint64>(4).cast<Void>();
    void query(int key) =>
        checkResult(ghostty_build_info(key, out), 'ghostty_build_info');
    bool readBool(int key) {
      query(key);
      return out.cast<Bool>().value;
    }

    int readSize(int key) {
      query(key);
      return out.cast<Size>().value;
    }

    String readString(int key) {
      query(key);
      return readGhosttyString(out.cast<GhosttyString>().ref);
    }

    query(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_OPTIMIZE);
    final optimize = optimizeModeCodec.decode(out.cast<Int>().value);
    return VtBuildInfo._(
      version: readString(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_STRING),
      major: readSize(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_MAJOR),
      minor: readSize(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_MINOR),
      patch: readSize(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_PATCH),
      preRelease: readString(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_PRE),
      buildMetadata: readString(
        GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_BUILD,
      ),
      optimizeMode: optimize,
      simd: readBool(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_SIMD),
      tmuxControlMode: readBool(
        GhosttyBuildInfo.GHOSTTY_BUILD_INFO_TMUX_CONTROL_MODE,
      ),
      features: Set.unmodifiable({
        for (final feature in VtFeature.values)
          if (readBool(feature._key)) feature,
      }),
    );
  });

  @override
  String toString() =>
      'VtBuildInfo($version, ${optimizeMode.name}, '
      'features: ${features.map((f) => f.name).join(', ')})';
}

/// The build information of the loaded library, queried on first access.
final VtBuildInfo libghosttyVtBuildInfo = VtBuildInfo._query();

/// The loaded libghostty-vt library is not a version this package supports.
///
/// This package needs libghostty-vt 1.x, at least 1.0.0 (ADR 0001).
final class IncompatibleLibraryException implements Exception {
  /// Creates the exception for the loaded [version] and the [reason].
  IncompatibleLibraryException(this.version, this.reason);

  /// The version reported by the loaded library.
  final String version;

  /// Why the version is rejected.
  final String reason;

  @override
  String toString() =>
      'IncompatibleLibraryException: libghostty-vt $version is not '
      'supported: $reason';
}

/// Returns why the library version [major].[minor].[patch] with pre-release
/// tag [preRelease] is unsupported, or `null` if it is supported.
///
/// Supported: `>=1.0.0 <2.0.0`. A pre-release of 1.0.0 itself (such as
/// `1.0.0-dev`) predates the stable ABI and is rejected; a pre-release of a
/// later 1.x (such as `1.1.0-dev`) is newer than 1.0.0 and accepted.
String? libraryVersionProblem(
  int major,
  int minor,
  int patch, {
  String preRelease = '',
}) {
  if (major != 1) return 'this package requires libghostty-vt 1.x';
  if (minor == 0 && patch == 0 && preRelease.isNotEmpty) {
    return 'pre-release builds of 1.0.0 predate the stable 1.0.0 ABI';
  }
  return null;
}

bool _compatibilityChecked = false;

/// Throws [IncompatibleLibraryException] if the loaded library is not a
/// supported version. Cheap after the first call.
///
/// `createNative` calls this before creating any native object; stateless
/// entry points that never create an object may call it too.
void ensureCompatibleLibrary() {
  if (_compatibilityChecked) return;
  final problem = _loadedVersionProblem();
  if (problem != null) {
    throw IncompatibleLibraryException(libghosttyVtVersion, problem);
  }
  _compatibilityChecked = true;
}

const _noVersionNumbers = 'the library does not report its version numbers';

/// Checks the loaded library's version numbers only, without the full
/// [libghosttyVtBuildInfo] query: an incompatible library may not know the
/// feature keys, and must still be reported as incompatible rather than
/// with an [UnsupportedError] from an unrelated query.
String? _loadedVersionProblem() => using((arena) {
  final out = arena<Uint64>(2).cast<Void>();
  try {
    int readSize(int key) {
      checkResult(ghostty_build_info(key, out), 'ghostty_build_info');
      return out.cast<Size>().value;
    }

    final major = readSize(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_MAJOR);
    final minor = readSize(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_MINOR);
    final patch = readSize(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_PATCH);
    checkResult(
      ghostty_build_info(GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_PRE, out),
      'ghostty_build_info',
    );
    final preRelease = readGhosttyString(out.cast<GhosttyString>().ref);
    return libraryVersionProblem(major, minor, patch, preRelease: preRelease);
  } on UnsupportedError {
    return _noVersionNumbers;
  } on GhosttyException {
    return _noVersionNumbers;
  }
});
