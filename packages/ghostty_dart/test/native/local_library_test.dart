// Resolution of the `path` user-define of the build hook's `source: path`.

import 'package:code_assets/code_assets.dart';
import 'package:ghostty_dart/src/native/prebuilt.dart';
import 'package:test/test.dart';

void main() {
  group('localLibraryUri', () {
    test('returns a file path unchanged', () {
      final file = Uri.file('/repo/out/lib/libghostty-vt.so.1.0.0');
      expect(localLibraryUri(file, OS.linux, isDirectory: false), file);
    });

    test('picks the bundled name inside a directory, per OS', () {
      final dir = Uri.file('/repo/.native-cache/host/');
      expect(
        localLibraryUri(dir, OS.linux, isDirectory: true),
        Uri.file('/repo/.native-cache/host/libghostty-vt.so'),
      );
      expect(
        localLibraryUri(dir, OS.macOS, isDirectory: true),
        Uri.file('/repo/.native-cache/host/libghostty-vt.dylib'),
      );
      expect(
        localLibraryUri(dir, OS.windows, isDirectory: true),
        Uri.file('/repo/.native-cache/host/ghostty-vt.dll'),
      );
    });

    test('accepts a directory without a trailing slash', () {
      final dir = Uri.parse('file:///repo/.native-cache/host');
      expect(
        localLibraryUri(dir, OS.linux, isDirectory: true),
        Uri.parse('file:///repo/.native-cache/host/libghostty-vt.so'),
      );
    });

    test('keeps Windows drive paths', () {
      final dir = Uri.file(r'D:\a\repo\.native-cache\host', windows: true);
      expect(
        localLibraryUri(
          dir,
          OS.windows,
          isDirectory: true,
        ).toFilePath(windows: true),
        r'D:\a\repo\.native-cache\host\ghostty-vt.dll',
      );
    });
  });
}
