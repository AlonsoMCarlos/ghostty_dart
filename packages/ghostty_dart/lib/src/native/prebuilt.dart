/// Native-library facts for `hook/build.dart`: asset name, library file
/// names, the pinned prebuilt release and hashes, and the minimum platform
/// versions of the prebuilt binaries. Lives under `lib/` so the hook can
/// import it; must not import `dart:ffi`, so it stays usable from the hook
/// and from web builds. Everything here is pure (no I/O) so it can be tested.
library;

import 'package:code_assets/code_assets.dart';

/// The libghostty-vt version these bindings target and the hook fetches.
///
/// Not the loaded library's version: that is the public
/// `libghosttyVtVersion` getter.
const targetLibghosttyVtVersion = '1.0.0';

/// Asset name of the native library. The `@Native` bindings resolve symbols
/// through `package:ghostty_dart/<nativeAssetName>`, which is the default asset
/// id of the generated bindings library.
const nativeAssetName = 'src/ffi/bindings.g.dart';

/// Default download location of prebuilt binaries: the GitHub release that
/// [prebuiltReleaseTag] names.
///
/// Override it with the `url_pattern` user-define, for a mirror or an
/// internal artefact store. The pattern must be `https` and these
/// placeholders are substituted (see [prebuiltUrl]):
///
/// - `$TAG`: the release tag, [prebuiltReleaseTag] (`native-v1.0.0-r1`).
/// - `$VERSION`: the upstream libghostty-vt version,
///   [targetLibghosttyVtVersion] (`1.0.0`). Kept for mirrors laid out by
///   upstream version.
/// - `$FILENAME`: the asset file name, [PrebuiltTarget.fileName]
///   (`libghostty-vt-linux-x64.so`). Required.
///
/// Whatever the URL, the download must match the pinned [prebuiltSha256].
const defaultUrlPattern =
    r'https://github.com/AlonsoMCarlos/ghostty_dart/releases/download/$TAG/$FILENAME';

// `mise run native:pin <tag>` rewrites everything between the BEGIN and END
// markers, including the doc comments, from the release's SHA256SUMS.
// BEGIN GENERATED prebuiltSha256 (mise run native:pin)
/// Release tag of the pinned prebuilt binaries (`native-v<version>-r<n>`).
const prebuiltReleaseTag = 'native-v1.0.0-r1';

/// sha256 of each prebuilt binary, keyed by [PrebuiltTarget.fileName].
const prebuiltSha256 = <String, String>{};
// END GENERATED prebuiltSha256

/// Lowest Android API level the prebuilt Android binaries support (ADR 0008;
/// Flutter's default `minSdk`).
const prebuiltMinAndroidApi = 24;

/// Lowest iOS major version the prebuilt iOS binaries support (ADR 0008;
/// upstream's floor).
const prebuiltMinIOSVersion = 13;

/// Lowest macOS major version the prebuilt macOS binaries support (ADR 0008;
/// upstream's floor).
const prebuiltMinMacOSVersion = 13;

/// A target OS and architecture with a prebuilt binary.
///
/// iOS has two binaries per architecture, one for devices and one for the
/// simulator, told apart by [isSimulator].
final class PrebuiltTarget {
  /// Creates a target. [isSimulator] may only be `true` for [OS.iOS], so
  /// that equality and [fileName] always agree.
  const PrebuiltTarget(this.os, this.architecture, {this.isSimulator = false})
    // `identical`, not `==`: OS overrides `==`, which const evaluation
    // rejects. The OS constants are canonical, so this is exact.
    : assert(!isSimulator || identical(os, OS.iOS));

  /// The target of a hook's [CodeConfig]: its OS and architecture, and for
  /// iOS whether it builds for the simulator SDK.
  factory PrebuiltTarget.fromCodeConfig(CodeConfig code) {
    final os = code.targetOS;
    return PrebuiltTarget(
      os,
      code.targetArchitecture,
      isSimulator: os == OS.iOS && code.iOS.targetSdk == IOSSdk.iPhoneSimulator,
    );
  }

  /// Target operating system.
  final OS os;

  /// Target CPU architecture.
  final Architecture architecture;

  /// Whether this is the iOS simulator rather than an iOS device.
  final bool isSimulator;

  /// File name of the release asset, e.g. `libghostty-vt-linux-x64.so` or
  /// `libghostty-vt-ios-arm64-simulator.dylib`. These names are a frozen
  /// contract with the release workflow (ADR 0008).
  String get fileName {
    final ext = switch (os) {
      OS.windows => 'dll',
      OS.macOS || OS.iOS => 'dylib',
      _ => 'so',
    };
    final prefix = os == OS.windows ? '' : 'lib';
    final suffix = isSimulator ? '-simulator' : '';
    return '${prefix}ghostty-vt-${os.name}-${architecture.name}$suffix.$ext';
  }

  @override
  bool operator ==(Object other) =>
      other is PrebuiltTarget &&
      other.os == os &&
      other.architecture == architecture &&
      other.isSimulator == isSimulator;

  @override
  int get hashCode => Object.hash(os, architecture, isSimulator);

  @override
  String toString() => 'PrebuiltTarget($fileName)';
}

/// Every target the release pipeline publishes (ADR 0008). Windows arm64 is
/// best effort.
const prebuiltTargets = <PrebuiltTarget>[
  PrebuiltTarget(OS.linux, Architecture.x64),
  PrebuiltTarget(OS.linux, Architecture.arm64),
  PrebuiltTarget(OS.windows, Architecture.x64),
  PrebuiltTarget(OS.windows, Architecture.arm64),
  PrebuiltTarget(OS.android, Architecture.arm64),
  PrebuiltTarget(OS.android, Architecture.arm),
  PrebuiltTarget(OS.android, Architecture.x64),
  PrebuiltTarget(OS.macOS, Architecture.arm64),
  PrebuiltTarget(OS.macOS, Architecture.x64),
  PrebuiltTarget(OS.iOS, Architecture.arm64),
  PrebuiltTarget(OS.iOS, Architecture.arm64, isSimulator: true),
  PrebuiltTarget(OS.iOS, Architecture.x64, isSimulator: true),
];

/// The minimum platform version that [code] targets: the Android API level,
/// or the iOS or macOS major version. `null` for other OSes, which have no
/// version requirement.
int? targetPlatformVersion(CodeConfig code) => switch (code.targetOS) {
  OS.android => code.android.targetNdkApi,
  OS.iOS => code.iOS.targetVersion,
  OS.macOS => code.macOS.targetVersion,
  _ => null,
};

/// What to set instead of the default `prebuilt` source, for error
/// messages. [includeUrlPattern] adds the mirror option, which only helps
/// when the download itself failed.
String prebuiltAlternativesHint({bool includeUrlPattern = false}) => [
  'Alternatives, in `hooks: user_defines: ghostty_dart:` of your root '
      'pubspec.yaml:',
  if (includeUrlPattern)
    r'  - url_pattern: an https mirror or internal store, e.g. '
        r'"https://mirror.example/$TAG/$FILENAME" ($TAG, $VERSION and '
        r'$FILENAME are substituted; the pinned sha256 is still verified). '
        'Behind a TLS-intercepting proxy, point it at a mirror the hook can '
        'reach with the system trust store, or use `source: path`.',
  '  - source: path, with path: pointing at a libghostty-vt '
      '$targetLibghosttyVtVersion library file, or a directory holding it '
      '(air-gapped builds).',
  '  - source: system, to load an installed libghostty-vt 1.x.',
].join('\n');

/// The error message for an app targeting [os] at [targetVersion] (see
/// [targetPlatformVersion]) that the prebuilt binaries cannot serve, or
/// `null` when they can.
///
/// The message states the floor and the `source: path` / `source: system`
/// alternatives. For iOS and macOS it does not name Xcode settings: the
/// version comes from the hook config, and Flutter 3.47.9 hard-codes it
/// (iOS 15, macOS 13 in `flutter_tools` `native_assets.dart`) rather than
/// passing the app's deployment target. Pure, so tests can check it.
String? prebuiltMinimumVersionError(OS os, int? targetVersion) {
  if (targetVersion == null) return null;
  final (int minimum, String platform, String advice) = switch (os) {
    OS.android => (
      prebuiltMinAndroidApi,
      'Android API',
      'Raise `minSdk` in android/app/build.gradle(.kts) to '
          '$prebuiltMinAndroidApi',
    ),
    OS.iOS => (
      prebuiltMinIOSVersion,
      'iOS',
      'The minimum iOS version your build tool passes to build hooks must be '
          '$prebuiltMinIOSVersion or later',
    ),
    OS.macOS => (
      prebuiltMinMacOSVersion,
      'macOS',
      'The minimum macOS version your build tool passes to build hooks must '
          'be $prebuiltMinMacOSVersion or later',
    ),
    // Other OSes have no version floor.
    _ => (0, '', ''),
  };
  if (targetVersion >= minimum) return null;
  return 'ghostty_dart: the prebuilt libghostty-vt $targetLibghosttyVtVersion '
      'needs $platform $minimum or later, but this build targets '
      '$platform $targetVersion. $advice, or provide your own library.\n'
      '${prebuiltAlternativesHint()}';
}

/// Builds the download URL of [fileName] from a `url_pattern` [pattern] (see
/// [defaultUrlPattern] for the placeholders).
///
/// [tag] and [version] default to the pinned values and exist so tests can
/// tell the `$TAG` and `$VERSION` substitutions apart. Throws a
/// [FormatException] when [pattern] has no `$FILENAME`, since every target
/// would then fetch the same file. The `https` check is the downloader's,
/// not this function's.
Uri prebuiltUrl(
  String pattern,
  String fileName, {
  String tag = prebuiltReleaseTag,
  String version = targetLibghosttyVtVersion,
}) {
  if (!pattern.contains(r'$FILENAME')) {
    throw FormatException(
      r'ghostty_dart: url_pattern must contain $FILENAME',
      pattern,
    );
  }
  return Uri.parse(
    pattern
        .replaceAll(r'$TAG', tag)
        .replaceAll(r'$VERSION', version)
        .replaceAll(r'$FILENAME', fileName),
  );
}

/// File name the library is bundled under. Identical across architectures,
/// as Apple platforms require.
String bundledLibraryName(OS os) => switch (os) {
  OS.windows => 'ghostty-vt.dll',
  OS.macOS || OS.iOS => 'libghostty-vt.dylib',
  _ => 'libghostty-vt.so',
};

/// Resolves the `path` user-define of `source: path` to the library file.
///
/// [path] may name the library file itself, or a directory that holds it
/// under [bundledLibraryName] for [os]. The directory form lets one root
/// pubspec serve every host: `tool/native/build_host.sh` stages each host's
/// build into `.native-cache/host/`. Pass whether [path] is an existing
/// directory as [isDirectory]; this function does no I/O.
Uri localLibraryUri(Uri path, OS os, {required bool isDirectory}) {
  if (!isDirectory) return path;
  final dir = path.path.endsWith('/')
      ? path
      : path.replace(path: '${path.path}/');
  return dir.resolve(bundledLibraryName(os));
}

/// Name the system dynamic loader resolves for an installed libghostty-vt 1.x.
String systemLibraryName(OS os) => switch (os) {
  OS.windows => 'ghostty-vt.dll',
  OS.macOS || OS.iOS => 'libghostty-vt.1.dylib',
  _ => 'libghostty-vt.so.1',
};
