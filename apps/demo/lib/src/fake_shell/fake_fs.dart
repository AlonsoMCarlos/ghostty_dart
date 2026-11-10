/// A tiny read-only in-memory file system for the fake shell.
library;

/// A file or directory of a [FakeFileSystem].
sealed class FakeNode {
  const FakeNode();
}

/// A file with its [content].
final class FakeFile extends FakeNode {
  /// Creates a file; [executable] files are listed in green by `ls`.
  const FakeFile(this.content, {this.executable = false});

  /// The file's text.
  final String content;

  /// Whether `ls` shows the file as executable.
  final bool executable;
}

/// A directory with named [children].
final class FakeDirectory extends FakeNode {
  /// Creates a directory.
  const FakeDirectory(this.children);

  /// The entries, by name.
  final Map<String, FakeNode> children;
}

/// A read-only tree of [FakeNode]s with Unix-style absolute paths.
final class FakeFileSystem {
  /// Creates a file system rooted at [root], whose home directory is
  /// [home] (an absolute path that must exist).
  FakeFileSystem(this.root, {this.home = '/home/demo'})
    : assert(home.startsWith('/'));

  /// The demo's default tree.
  factory FakeFileSystem.demo() => FakeFileSystem(
    const FakeDirectory({
      'home': FakeDirectory({
        'demo': FakeDirectory({
          'README.md': FakeFile(
            '# ghostty_dart demo\n'
            '\n'
            'This terminal is drawn by ghostty_dart_flutter on top of\n'
            'libghostty-vt. On the web it talks to this fake shell, which\n'
            'runs entirely in Dart in your browser.\n'
            '\n'
            'Try: colors, top, ls -l, cat notes.txt, title <text>\n',
          ),
          'notes.txt': FakeFile(
            'Wide characters: 漢字 かな 한국어\n'
            'Emoji: 🙂 👍🏽 👨‍👩‍👧 🇪🇸\n'
            'Combining: é ä ñ\n',
          ),
          'projects': FakeDirectory({
            'hello.sh': FakeFile(
              '#!/bin/sh\necho "hello from a fake script"\n',
              executable: true,
            ),
            'todo.txt': FakeFile('- write more tests\n- measure frames\n'),
          }),
        }),
      }),
      'bin': FakeDirectory({
        'colors': FakeFile('(built-in)\n', executable: true),
        'top': FakeFile('(built-in)\n', executable: true),
      }),
      'etc': FakeDirectory({
        'motd': FakeFile('Welcome to the ghostty_dart fake shell.\n'),
      }),
    }),
  );

  /// The top directory.
  final FakeDirectory root;

  /// The home directory (`~`).
  final String home;

  /// The absolute, normalised form of [path] seen from [cwd]: `~` expands
  /// to [home], and `.` and `..` are resolved.
  String resolve(String path, {required String cwd}) {
    var full = path;
    if (full == '~' || full.startsWith('~/')) {
      full = home + full.substring(1);
    } else if (!full.startsWith('/')) {
      full = '$cwd/$full';
    }
    final parts = <String>[];
    for (final part in full.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return '/${parts.join('/')}';
  }

  /// The node at the absolute [path], or `null` if there is none.
  FakeNode? lookup(String path) {
    FakeNode node = root;
    for (final part in path.split('/')) {
      if (part.isEmpty) continue;
      if (node is! FakeDirectory) return null;
      final child = node.children[part];
      if (child == null) return null;
      node = child;
    }
    return node;
  }

  /// [path] with [home] shortened to `~`, as prompts show it.
  String display(String path) {
    if (path == home) return '~';
    if (path.startsWith('$home/')) return '~${path.substring(home.length)}';
    return path;
  }
}
