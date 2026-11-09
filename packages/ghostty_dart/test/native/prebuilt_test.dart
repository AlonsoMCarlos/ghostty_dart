// Pure parts of the build hook's prebuilt source: asset names, target
// mapping from a hook CodeConfig, minimum versions and URL patterns. Also
// runs the hook's prebuilt branch up to the point where it would download.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:ghostty_dart/src/native/prebuilt.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as hook;

/// Scratch directory: building a [BuildInput] creates its output directory.
late Directory tempDir;

/// A [CodeConfig] as hooks_runner would pass it to the hook.
CodeConfig codeConfig(
  OS os,
  Architecture architecture, {
  IOSCodeConfig? iOS,
  AndroidCodeConfig? android,
  MacOSCodeConfig? macOS,
}) {
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: tempDir.uri,
      packageName: 'ghostty_dart',
      outputDirectoryShared: tempDir.uri.resolve('shared/'),
      outputFile: tempDir.uri.resolve('output.json'),
    )
    ..setupBuildInput()
    ..config.setupBuild(linkingEnabled: false);
  CodeAssetExtension(
    targetArchitecture: architecture,
    targetOS: os,
    linkModePreference: LinkModePreference.dynamic,
    iOS: iOS,
    android: android,
    macOS: macOS,
  ).setupBuildInput(builder);
  return builder.build().config.code;
}

/// A config for [target] at the minimum supported platform version.
CodeConfig codeConfigFor(PrebuiltTarget target) => codeConfig(
  target.os,
  target.architecture,
  iOS: target.os == OS.iOS
      ? IOSCodeConfig(
          targetSdk: target.isSimulator
              ? IOSSdk.iPhoneSimulator
              : IOSSdk.iPhoneOS,
          targetVersion: prebuiltMinIOSVersion,
        )
      : null,
  android: target.os == OS.android
      ? AndroidCodeConfig(targetNdkApi: prebuiltMinAndroidApi)
      : null,
  macOS: target.os == OS.macOS
      ? MacOSCodeConfig(targetVersion: prebuiltMinMacOSVersion)
      : null,
);

/// Asset names from the table in ADR 0008, the frozen contract with the
/// release workflow, or `null` outside the repository (published package).
List<String>? adrAssetNames() {
  final adr = File('../../docs/internal/adr/0008-prebuilt-release-pipeline.md');
  if (!adr.existsSync()) return null;
  // The first cell of a data row is the asset name in a code span, possibly
  // followed by a note such as "(best effort)".
  final row = RegExp(r'^\| `([^`]+)`');
  return [
    for (final line in adr.readAsLinesSync())
      if (row.firstMatch(line) case final match?) match[1]!,
  ];
}

void main() {
  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('ghostty_dart_prebuilt');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  group('PrebuiltTarget.fileName', () {
    final adrNames = adrAssetNames();
    test(
      'matches the ADR 0008 asset table',
      () {
        expect(adrNames, hasLength(12));
        expect(prebuiltTargets.map((t) => t.fileName), adrNames);
      },
      skip: adrNames == null
          ? 'docs/internal/adr/0008-prebuilt-release-pipeline.md is only in '
                'the repository'
          : false,
    );

    test('names are unique', () {
      final names = prebuiltTargets.map((t) => t.fileName).toSet();
      expect(names, hasLength(prebuiltTargets.length));
    });

    test('isSimulator is rejected outside iOS', () {
      expect(
        () => PrebuiltTarget(OS.linux, Architecture.x64, isSimulator: true),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('PrebuiltTarget.fromCodeConfig', () {
    for (final target in prebuiltTargets) {
      test(target.fileName, () {
        final mapped = PrebuiltTarget.fromCodeConfig(codeConfigFor(target));
        expect(mapped, target);
        expect(mapped.fileName, target.fileName);
      });
    }

    test('iOS device and simulator are distinct', () {
      PrebuiltTarget ios(IOSSdk sdk) => PrebuiltTarget.fromCodeConfig(
        codeConfig(
          OS.iOS,
          Architecture.arm64,
          iOS: IOSCodeConfig(targetSdk: sdk, targetVersion: 15),
        ),
      );
      expect(ios(IOSSdk.iPhoneOS).fileName, 'libghostty-vt-ios-arm64.dylib');
      expect(
        ios(IOSSdk.iPhoneSimulator).fileName,
        'libghostty-vt-ios-arm64-simulator.dylib',
      );
    });
  });

  group('minimum versions', () {
    // Deliberate tripwire: changing a floor must be a decision recorded in
    // ADR 0008, not a silent edit.
    test('constants follow ADR 0008', () {
      expect(prebuiltMinAndroidApi, 24);
      expect(prebuiltMinIOSVersion, 14);
      expect(prebuiltMinMacOSVersion, 13);
    });

    test('targetPlatformVersion reads the per-OS config', () {
      expect(
        targetPlatformVersion(
          codeConfig(
            OS.android,
            Architecture.arm64,
            android: AndroidCodeConfig(targetNdkApi: 21),
          ),
        ),
        21,
      );
      expect(
        targetPlatformVersion(
          codeConfig(
            OS.iOS,
            Architecture.arm64,
            iOS: IOSCodeConfig(targetSdk: IOSSdk.iPhoneOS, targetVersion: 12),
          ),
        ),
        12,
      );
      expect(
        targetPlatformVersion(
          codeConfig(
            OS.macOS,
            Architecture.x64,
            macOS: MacOSCodeConfig(targetVersion: 14),
          ),
        ),
        14,
      );
      expect(
        targetPlatformVersion(codeConfig(OS.linux, Architecture.x64)),
        isNull,
      );
    });

    test('accepts the minimum and above', () {
      expect(prebuiltMinimumVersionError(OS.android, 24), isNull);
      expect(prebuiltMinimumVersionError(OS.android, 35), isNull);
      expect(prebuiltMinimumVersionError(OS.iOS, 14), isNull);
      expect(prebuiltMinimumVersionError(OS.macOS, 15), isNull);
      expect(prebuiltMinimumVersionError(OS.linux, null), isNull);
      expect(prebuiltMinimumVersionError(OS.windows, null), isNull);
    });

    test('rejects lower targets with accurate advice', () {
      final android = prebuiltMinimumVersionError(OS.android, 21)!;
      final ios = prebuiltMinimumVersionError(OS.iOS, 12)!;
      final macos = prebuiltMinimumVersionError(OS.macOS, 12)!;
      expect(android, contains('Android API 24'));
      expect(android, contains('Android API 21'));
      expect(android, contains('minSdk'));
      expect(ios, contains('iOS 14 or later'));
      expect(macos, contains('macOS 13 or later'));
      for (final message in [android, ios, macos]) {
        expect(message, contains('source: path'));
        expect(message, contains('source: system'));
      }
      // Xcode settings do not reach the hook config, so they are not advice.
      for (final message in [ios, macos]) {
        expect(message, isNot(contains('DEPLOYMENT_TARGET')));
        expect(message, isNot(contains('Podfile')));
      }
    });
  });

  group('prebuiltUrl', () {
    test('default pattern points at the pinned GitHub release', () {
      expect(
        prebuiltUrl(defaultUrlPattern, 'libghostty-vt-linux-x64.so'),
        Uri.parse(
          'https://github.com/AlonsoMCarlos/ghostty_dart/releases/download/'
          '$prebuiltReleaseTag/libghostty-vt-linux-x64.so',
        ),
      );
    });

    test('the release tag follows the native-v<version>-r<n> scheme', () {
      final version = RegExp.escape(targetLibghosttyVtVersion);
      expect(
        prebuiltReleaseTag,
        matches(RegExp('^native-v$version-r[1-9]\\d*\$')),
      );
    });

    test(r'substitutes $TAG, $VERSION and $FILENAME', () {
      expect(
        prebuiltUrl(
          r'https://mirror.example/$TAG/$VERSION/$FILENAME?x=$FILENAME',
          'ghostty-vt-windows-x64.dll',
          tag: 'native-v1.0.0-r7',
          version: '1.0.0',
        ),
        Uri.parse(
          'https://mirror.example/native-v1.0.0-r7/1.0.0/'
          'ghostty-vt-windows-x64.dll?x=ghostty-vt-windows-x64.dll',
        ),
      );
    });

    test(r'requires $FILENAME', () {
      expect(
        () => prebuiltUrl(r'https://mirror.example/$TAG/lib.so', 'x.so'),
        throwsFormatException,
      );
    });
  });

  test('the pinned hashes only name known assets, as lowercase sha256', () {
    final names = prebuiltTargets.map((t) => t.fileName).toSet();
    for (final MapEntry(:key, :value) in prebuiltSha256.entries) {
      expect(names, contains(key));
      expect(value, matches(RegExp(r'^[0-9a-f]{64}$')));
    }
  });

  group('hook/build.dart', () {
    test('never uses the insecure test seam', () {
      final source = File('hook/build.dart').readAsStringSync();
      expect(source, isNot(contains('insecureForTesting')));
      expect(source, contains('const PrebuiltFetcher()'));
    });

    // End to end through the real hook entry point, stopping before any
    // network access: the failures below happen before the download.
    Future<void> runHook({
      required OS os,
      required Architecture architecture,
      int androidApi = 30,
      Map<String, Object?> defines = const {},
    }) => testCodeBuildHook(
      mainMethod: hook.main,
      check: (_, _) => fail('the hook should have failed'),
      targetOS: os,
      targetArchitecture: architecture,
      targetAndroidNdkApi: androidApi,
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: defines,
          basePath: Directory.current.uri,
        ),
      ),
    );

    test(
      'prebuilt without a pinned hash fails with the alternatives',
      () async {
        await expectLater(
          runHook(os: OS.linux, architecture: Architecture.riscv64),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              allOf([
                contains('libghostty-vt-linux-riscv64.so'),
                contains(prebuiltReleaseTag),
                contains('source: path'),
                contains('source: system'),
              ]),
            ),
          ),
        );
      },
      // riscv64 is not in the ADR 0008 table, so it stays unpinned.
      skip: prebuiltSha256.containsKey('libghostty-vt-linux-riscv64.so')
          ? 'linux-riscv64 is pinned now; this case needs an unpinned target'
          : false,
    );

    test('the version check runs before the pin lookup', () async {
      await expectLater(
        runHook(
          os: OS.android,
          architecture: Architecture.arm64,
          androidApi: 21,
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('Android API 24'),
          ),
        ),
      );
    });

    test('a non-string url_pattern is a FormatException', () async {
      await expectLater(
        runHook(
          os: OS.linux,
          architecture: Architecture.x64,
          defines: {'url_pattern': 42},
        ),
        throwsFormatException,
      );
    });
  });
}
