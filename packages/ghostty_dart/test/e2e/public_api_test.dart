// The public API audit: resolves `package:ghostty_dart/ghostty_dart.dart` with
// the analyzer and walks every exported declaration's public signature.
//
// It fails when the public API mentions a `dart:ffi` type (other than a
// class implementing `Finalizable`, which contratos.md §2 requires), a raw
// binding, or a package type that is not itself exported (an internal
// helper such as `RawEnumCodec` leaking through a signature), and when an
// internal-only name (codecs, raw converters, `adoptNativeTerminal`) is
// exported. It also fails when a new public type is declared under
// `lib/src/` but neither exported nor listed in [_internalTypes], which
// catches a forgotten barrel `show` entry.

@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:test/test.dart';

void main() {
  late final String lib;
  late final AnalysisSession session;
  late final Map<String, Element> exported;

  setUpAll(() async {
    // Works from any working directory (`mise run test` runs at the root).
    final barrel = await Isolate.resolvePackageUri(
      Uri.parse('package:ghostty_dart/ghostty_dart.dart'),
    );
    final path = barrel!.toFilePath();
    lib = File(path).parent.path;
    final collection = AnalysisContextCollection(includedPaths: [lib]);
    session = collection.contextFor(path).currentSession;
    final library = await _library(session, path);
    exported = library.exportNamespace.definedNames2;
  });

  test('the barrel exports the public API', () {
    expect(exported.length, greaterThan(150));
    for (final name in ['VtTerminal', 'RenderState', 'KeyEncoder']) {
      expect(exported, contains(name));
    }
  });

  test(
    'each public element is exported by exactly one module barrel',
    () async {
      final owners = <Element, List<String>>{};
      for (final module in _modules) {
        // Analyzer paths must be normalized (Windows: no mixed separators).
        final path = session.resourceProvider.pathContext.join(
          lib,
          'src',
          module,
          '$module.dart',
        );
        final library = await _library(session, path);
        for (final element in library.exportNamespace.definedNames2.values) {
          (owners[element] ??= []).add(module);
        }
      }
      final duplicated = [
        for (final MapEntry(:key, :value) in owners.entries)
          if (value.length > 1) '${key.displayName}: ${value.join(', ')}',
      ];
      expect(duplicated, isEmpty);
      // Nothing reaches the top-level barrel except through a module barrel.
      final unowned = [
        for (final element in exported.values)
          if (!owners.containsKey(element)) element.displayName,
      ];
      expect(unowned, isEmpty);
    },
  );

  test('no internal-only name is exported', () {
    final internal = exported.keys.where(
      (name) =>
          name.endsWith('Codec') ||
          name.endsWith('ToRaw') ||
          name.endsWith('FromRaw') ||
          name.endsWith('FromNative') ||
          name.endsWith('ToNative') ||
          name == 'adoptNativeTerminal',
    );
    expect(internal, isEmpty);
    final fromInternalFiles = [
      for (final MapEntry(:key, :value) in exported.entries)
        if (_isInternalFile(_uriOf(value))) '$key (${_uriOf(value)})',
    ];
    expect(fromInternalFiles, isEmpty);
  });

  test('public signatures mention no dart:ffi type or unexported type', () {
    final exportedElements = exported.values.map(_declaration).toSet();
    final problems = <String>{};
    for (final MapEntry(key: name, value: element) in exported.entries) {
      _Auditor(name, exportedElements, problems).element(element);
    }
    expect(problems.toList()..sort(), isEmpty);
  });

  test(
    'every public type under lib/src is exported or known internal',
    () async {
      final exportedElements = exported.values.toSet();
      final unexported = <String>[];
      final pathContext = session.resourceProvider.pathContext;
      final files = Directory(pathContext.join(lib, 'src'))
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.endsWith('bindings.g.dart'));
      for (final file in files) {
        final result = await session.getResolvedLibrary(
          pathContext.normalize(file.absolute.path),
        );
        // Part files are reached through their library.
        if (result is! ResolvedLibraryResult) continue;
        final library = result.element;
        for (final Element type in [
          ...library.classes,
          ...library.enums,
          ...library.mixins,
          ...library.extensions,
          ...library.extensionTypes,
          ...library.typeAliases,
        ]) {
          if (type.isPublic &&
              !exportedElements.contains(type) &&
              !_internalTypes.contains(type.displayName)) {
            unexported.add('${type.displayName} (${library.uri})');
          }
        }
      }
      expect(unexported, isEmpty);
    },
  );
}

/// The module barrels (`lib/src/<m>/<m>.dart`), contratos.md §1.
const _modules = [
  'color',
  'core',
  'grid',
  'input',
  'kitty',
  'parsers',
  'render',
  'search',
  'selection',
  'snapshot',
  'sys',
  'terminal',
  'text',
  'unicode',
];

/// Public-in-Dart types under `lib/src/` that are deliberately internal:
/// FFI plumbing, hot-path decoders and dispatch enums no signature uses.
const _internalTypes = {
  'CellBits',
  'CellTranscoder',
  'Effect',
  'EncodeBuffer',
  'GrowableNativeBuffer',
  'MultiKey',
  'NativeHandle',
  'PackedCell',
  'PrebuiltTarget',
  'RawEnumCodec',
  'SizedStructInit',
  'SnapshotProgressKind',
  'TerminalEffects',
};

Future<LibraryElement> _library(AnalysisSession session, String path) async {
  final result = await session.getResolvedLibrary(path);
  return (result as ResolvedLibraryResult).element;
}

/// The declaring element of [element] (a getter/setter of a top-level
/// variable is reported by its variable).
Element _declaration(Element element) => switch (element) {
  PropertyAccessorElement(:final variable) => variable,
  _ => element,
};

String _uriOf(Element element) => '${element.library?.uri}';

bool _isInternalFile(String uri) =>
    uri.endsWith('/internal.dart') ||
    uri.endsWith('_native.dart') ||
    uri.endsWith('/bindings.g.dart');

/// Walks the public signature of one exported element.
final class _Auditor {
  _Auditor(this.name, this.exported, this.problems);

  final String name;
  final Set<Element> exported;
  final Set<String> problems;

  /// The (type, location) pairs walked so far: stops recursion through
  /// F-bounded type parameters while still naming every location of a leak.
  final _seen = <(DartType, String)>{};

  void element(Element element) {
    switch (element) {
      case InterfaceElement():
        _interface(element);
      case ExtensionElement():
        _typeParameters(element.typeParameters, 'type parameter bound');
        type(element.extendedType, 'on-type');
        _members(element);
      case TypeAliasElement():
        _typeParameters(element.typeParameters, 'type parameter bound');
        type(element.aliasedType, 'aliased type');
      case ExecutableElement():
        _executable(element, name);
      case PropertyInducingElement():
        type(element.type, 'type');
      default:
        problems.add('$name: unexpected element kind ${element.runtimeType}');
    }
  }

  void _typeParameters(List<TypeParameterElement> parameters, String where) {
    for (final p in parameters) {
      if (p.bound case final bound?) type(bound, where);
    }
  }

  void _interface(InterfaceElement element) {
    _typeParameters(element.typeParameters, 'type parameter bound');
    if (element.supertype case final supertype?) {
      type(supertype, 'superclass');
    }
    for (final interface in element.interfaces) {
      // contratos.md §2: public wrappers implement Finalizable.
      if (interface.element.name == 'Finalizable' &&
          _uriOf(interface.element) == 'dart:ffi') {
        continue;
      }
      type(interface, 'interface');
    }
    for (final mixin in element.mixins) {
      type(mixin, 'mixin');
    }
    for (final constructor in element.constructors) {
      if (constructor.isPublic) {
        _executable(constructor, '$name.${constructor.displayName}');
      }
    }
    if (element is ExtensionTypeElement) {
      type(element.typeErasure, 'representation');
    }
    _members(element);
  }

  void _members(InstanceElement element) {
    // Fields are covered by their implicit getters and setters.
    for (final executable in <ExecutableElement>[
      ...element.getters,
      ...element.setters,
      ...element.methods,
    ]) {
      if (executable.isPublic) {
        _executable(executable, '$name.${executable.displayName}');
      }
    }
  }

  void _executable(ExecutableElement element, String where) {
    _typeParameters(element.typeParameters, '$where type parameter');
    type(element.returnType, '$where return type');
    for (final parameter in element.formalParameters) {
      type(parameter.type, '$where parameter ${parameter.displayName}');
    }
  }

  void type(DartType type, String where) {
    if (!_seen.add((type, where))) return;
    if (type.alias case final alias?) _named(alias.element, where);
    switch (type) {
      case InterfaceType():
        _named(type.element, where);
        for (final argument in type.typeArguments) {
          this.type(argument, where);
        }
      case FunctionType():
        _typeParameters(type.typeParameters, where);
        this.type(type.returnType, where);
        for (final parameter in type.formalParameters) {
          this.type(parameter.type, where);
        }
      case RecordType():
        for (final field in [...type.positionalFields, ...type.namedFields]) {
          this.type(field.type, where);
        }
      case TypeParameterType():
        this.type(type.bound, where);
      default:
        break;
    }
  }

  void _named(Element element, String where) {
    final uri = _uriOf(element);
    if (uri == 'dart:ffi' || uri.endsWith('/bindings.g.dart')) {
      problems.add('$name: $where mentions ${element.displayName} ($uri)');
    } else if (uri.startsWith('package:ghostty_dart/') &&
        !exported.contains(element)) {
      problems.add(
        '$name: $where mentions unexported ${element.displayName} ($uri)',
      );
    }
  }
}
