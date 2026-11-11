// The API model shared by the snapshot (xterm 4.0.0, committed as JSON) and
// the live pass over ghostty_dart_xterm. Plain data with a stable JSON form:
// maps are written with sorted keys so the snapshot diffs cleanly.

/// The public libraries compared, in the order a symbol's primary library is
/// chosen (the first one that exports it). `xterm.dart` comes last: it only
/// re-exports the others.
const libraryOrder = [
  'core.dart',
  'ui.dart',
  'zmodem.dart',
  'suggestion.dart',
  'utils.dart',
  'xterm.dart',
];

/// One exported top-level symbol: a class, mixin, enum, extension, typedef,
/// function or variable.
final class ApiSymbol {
  ApiSymbol({
    required this.name,
    required this.kind,
    required this.libraries,
    required this.display,
    required this.source,
    required this.sig,
    required this.members,
  });

  factory ApiSymbol.fromJson(String name, Map<String, Object?> json) =>
      ApiSymbol(
        name: name,
        kind: json['kind']! as String,
        libraries: (json['libraries']! as List<Object?>).cast<String>(),
        display: json['display']! as String,
        source: json['source']! as String,
        sig: (json['sig']! as Map<String, Object?>),
        members: {
          for (final MapEntry(:key, :value)
              in (json['members']! as Map<String, Object?>).entries)
            key: ApiMember.fromJson(key, value! as Map<String, Object?>),
        },
      );

  final String name;

  /// `class`, `mixin`, `enum`, `extension`, `extension type`, `typedef`,
  /// `function` or `variable`.
  final String kind;

  /// The public libraries that export it, in [libraryOrder].
  final List<String> libraries;

  /// The declaration as the analyzer prints it, for the report.
  final String display;

  /// The declaring file, relative to its package's `lib/`, or the library URI
  /// for symbols declared outside the package (a re-export).
  final String source;

  /// The comparable part of the declaration (see `compare.dart`).
  final Map<String, Object?> sig;

  /// Members by key: the member name, `new` for the unnamed constructor.
  final Map<String, ApiMember> members;

  /// The library a reader looks for it under.
  String get primaryLibrary => libraries.first;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'libraries': libraries,
    'display': display,
    'source': source,
    'sig': sig,
    'members': {
      for (final key in members.keys.toList()..sort())
        key: members[key]!.toJson(),
    },
  };
}

/// A member of a symbol: constructor, property (field or getter/setter pair),
/// method, operator or enum value.
final class ApiMember {
  ApiMember({
    required this.name,
    required this.kind,
    required this.display,
    required this.sig,
    this.flags = const [],
    this.foreign = false,
  });

  factory ApiMember.fromJson(String name, Map<String, Object?> json) =>
      ApiMember(
        name: name,
        kind: json['kind']! as String,
        display: json['display']! as String,
        sig: json['sig']! as Map<String, Object?>,
        flags: ((json['flags'] as List<Object?>?) ?? const []).cast<String>(),
      );

  final String name;

  /// `constructor`, `property`, `method`, `operator` or `value`.
  final String kind;
  final String display;
  final Map<String, Object?> sig;

  /// Annotations worth showing: `internal`, `protected`, `visibleForTesting`,
  /// `deprecated`.
  final List<String> flags;

  /// Inherited from a supertype outside the package (Flutter, the SDK).
  /// Only the adapter side keeps such members (they are present for a
  /// caller); they are never written to the snapshot and never additions.
  final bool foreign;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'display': display,
    'sig': sig,
    if (flags.isNotEmpty) 'flags': flags,
  };
}

/// A package's public API: every exported symbol by name.
final class ApiModel {
  ApiModel(this.symbols);

  factory ApiModel.fromJson(Map<String, Object?> json) => ApiModel({
    for (final MapEntry(:key, :value) in json.entries)
      key: ApiSymbol.fromJson(key, value! as Map<String, Object?>),
  });

  final Map<String, ApiSymbol> symbols;

  Map<String, Object?> toJson() => {
    for (final name in symbols.keys.toList()..sort())
      name: symbols[name]!.toJson(),
  };

  /// Number of symbols plus members.
  int get size =>
      symbols.values.fold(0, (sum, s) => sum + 1 + s.members.length);
}
