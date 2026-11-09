import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:test/test.dart';

void main() {
  test('libghosttyVtVersion reports a 1.x library', () {
    expect(libghosttyVtVersion, startsWith('1.'));
  });

  test('build info agrees with the version string', () {
    final info = libghosttyVtBuildInfo;
    expect(info.version, libghosttyVtVersion);
    expect(
      info.version,
      startsWith('${info.major}.${info.minor}.${info.patch}'),
    );
    if (info.preRelease.isNotEmpty) {
      expect(info.version, contains('-${info.preRelease}'));
    }
    if (info.buildMetadata.isNotEmpty) {
      expect(info.version, contains('+${info.buildMetadata}'));
    }
    expect(info.optimizeMode, isNot(OptimizeMode.unknown));
    expect(identical(info, libghosttyVtBuildInfo), isTrue);
    expect('$info', contains(info.version));
  });

  test('the bundled library has every feature this package wraps', () {
    final info = libghosttyVtBuildInfo;
    for (final feature in VtFeature.values) {
      if (feature == VtFeature.kittyGraphics) continue; // optional per target
      expect(info.supports(feature), isTrue, reason: feature.name);
    }
  });

  test('ensureCompatibleLibrary accepts the loaded library', () {
    ensureCompatibleLibrary();
    ensureCompatibleLibrary();
  });

  group('libraryVersionProblem', () {
    test('accepts 1.x releases and later 1.x pre-releases', () {
      expect(libraryVersionProblem(1, 0, 0), isNull);
      expect(libraryVersionProblem(1, 0, 3), isNull);
      expect(libraryVersionProblem(1, 7, 0), isNull);
      expect(libraryVersionProblem(1, 0, 1, preRelease: 'dev'), isNull);
      expect(libraryVersionProblem(1, 1, 0, preRelease: 'dev'), isNull);
    });

    test('rejects other majors and 1.0.0 pre-releases', () {
      expect(libraryVersionProblem(0, 9, 9), contains('1.x'));
      expect(libraryVersionProblem(2, 0, 0), contains('1.x'));
      expect(libraryVersionProblem(1, 0, 0, preRelease: 'dev'), isNotNull);
    });
  });

  test('IncompatibleLibraryException explains the problem', () {
    final error = IncompatibleLibraryException('2.0.0', 'needs 1.x');
    expect('$error', allOf(contains('2.0.0'), contains('needs 1.x')));
  });
}
