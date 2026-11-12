// Reads a package's public API with the analyzer (analyzer 13.3.0, the
// version locked in the workspace) into an ApiModel. Nothing is compiled or
// run: the analyzer only parses and resolves the sources.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'model.dart';

/// Thrown when the API cannot be read reliably (a library that does not
/// resolve, a type the analyzer cannot resolve on the reference side).
final class ExtractError implements Exception {
  ExtractError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Extracts the API exported by [libraries] (`core.dart` -> its URI).
///
/// [analysisRoot] is a directory whose package config resolves the URIs (the
/// workspace for `package:` URIs). Members are kept when declared in a library
/// whose URI starts with [ownUriPrefix] or in the symbol's own library, so
/// members a class inherits from Flutter or the SDK are left out; with
/// [keepForeign] they are kept too and marked [ApiMember.foreign] (the
/// adapter side: an inherited member is still present for a caller). A
/// member that overrides one declared outside the package is kept when
/// declared in the package, and marked foreign as well.
///
/// With [requireAll], a library that does not exist or does not resolve is an
/// [ExtractError]; otherwise it exports nothing.
Future<ApiModel> extractApi({
  required String analysisRoot,
  required Map<String, String> libraries,
  required String ownUriPrefix,
  bool requireAll = false,
  bool keepForeign = false,
}) async {
  // The analyzer only accepts absolute, normalized paths.
  final rootPath = Uri.directory(Directory(analysisRoot).absolute.path)
      .normalizePath()
      .toFilePath()
      .replaceAll(RegExp(r'[/\\]+'), Platform.pathSeparator)
      .replaceFirst(RegExp(r'[/\\]$'), '');
  final collection = AnalysisContextCollection(includedPaths: [rootPath]);
  try {
    final session = collection.contextFor(rootPath).currentSession;
    // name -> (element, exporting libraries)
    final exported = <String, (Element, List<String>)>{};
    final setters = <String>{};
    for (final lib in libraryOrder) {
      final uri = libraries[lib];
      if (uri == null) continue;
      final result = await session.getLibraryByUri(uri);
      if (result is! LibraryElementResult ||
          result.element.isOriginNotExistingFile) {
        if (requireAll) throw ExtractError('$uri does not resolve ($result)');
        continue;
      }
      for (final MapEntry(key: name, value: element)
          in result.element.exportNamespace.definedNames2.entries) {
        if (name.startsWith('_')) continue;
        if (name.endsWith('=')) {
          setters.add(name.substring(0, name.length - 1));
          continue;
        }
        final entry = exported.putIfAbsent(name, () => (element, []));
        entry.$2.add(lib);
      }
    }
    final symbols = <String, ApiSymbol>{};
    for (final MapEntry(key: name, value: (element, libs))
        in exported.entries) {
      symbols[name] = _symbol(
        name,
        element,
        libs,
        ownUriPrefix,
        keepForeign,
        writable: setters.contains(name),
      );
    }
    return ApiModel(symbols);
  } finally {
    await collection.dispose();
  }
}

String _type(DartType type) => type.getDisplayString();

String _typeParameters(List<TypeParameterElement> params) => params.isEmpty
    ? ''
    : '<${params.map((p) => p.displayString()).join(', ')}>';

List<String> _flags(Iterable<Element?> elements) {
  final flags = <String>{};
  for (final e in elements) {
    if (e == null) continue;
    final m = e.metadata;
    if (m.hasInternal) flags.add('internal');
    if (m.hasProtected) flags.add('protected');
    if (m.hasVisibleForTesting) flags.add('visibleForTesting');
    if (m.hasDeprecated) flags.add('deprecated');
  }
  return flags.toList()..sort();
}

List<Map<String, Object?>> _params(List<FormalParameterElement> params) => [
  for (final p in params)
    {
      'name': p.name ?? '',
      'kind': p.isRequiredPositional
          ? 'positional'
          : p.isOptionalPositional
          ? 'optional'
          : p.isRequiredNamed
          ? 'required named'
          : 'named',
      'type': _type(p.type),
      if (p.defaultValueCode != null) 'default': p.defaultValueCode,
    },
];

Map<String, Object?> _executableSig(ExecutableElement e) => {
  'returns': _type(e.returnType),
  'typeParameters': _typeParameters(e.typeParameters),
  'params': _params(e.formalParameters),
  if (e.isStatic) 'static': true,
};

String _source(Element element, String ownUriPrefix) {
  final uri = element.library!.uri.toString();
  return uri.startsWith(ownUriPrefix)
      ? uri.substring(ownUriPrefix.length)
      : uri;
}

ApiSymbol _symbol(
  String name,
  Element element,
  List<String> libs,
  String ownUriPrefix,
  bool keepForeign, {
  required bool writable,
}) {
  final source = _source(element, ownUriPrefix);
  final libraryUri = element.library!.uri.toString();
  bool isOwn(Element e) {
    final uri = e.library?.uri.toString() ?? '';
    return uri.startsWith(ownUriPrefix) || uri == libraryUri;
  }

  ApiSymbol make(String kind, Map<String, Object?> sig, {String? display}) =>
      ApiSymbol(
        name: name,
        kind: kind,
        libraries: libs,
        display: display ?? element.displayString(),
        source: source,
        sig: sig,
        members: element is InstanceElement
            ? _members(element, isOwn, keepForeign)
            : {},
      );

  switch (element) {
    case ClassElement():
      return make('class', {
        'typeParameters': _typeParameters(element.typeParameters),
        'modifiers': [
          if (element.isAbstract) 'abstract',
          if (element.isSealed) 'sealed',
          if (element.isBase) 'base',
          if (element.isInterface) 'interface',
          if (element.isFinal) 'final',
          if (element.isMixinClass) 'mixin',
        ],
        'supertypes': _supertypes(element),
      });
    case MixinElement():
      return make('mixin', {
        'typeParameters': _typeParameters(element.typeParameters),
        'modifiers': [if (element.isBase) 'base'],
        'supertypes': _supertypes(element),
      });
    case EnumElement():
      return make('enum', {
        'typeParameters': _typeParameters(element.typeParameters),
        'supertypes': _supertypes(element),
      });
    case ExtensionTypeElement():
      return make('extension type', {
        'typeParameters': _typeParameters(element.typeParameters),
        'supertypes': _supertypes(element),
      });
    case ExtensionElement():
      return make('extension', {
        'typeParameters': _typeParameters(element.typeParameters),
        'on': _type(element.extendedType),
      });
    case TypeAliasElement():
      return make('typedef', {
        'typeParameters': _typeParameters(element.typeParameters),
        'aliased': _type(element.aliasedType),
      });
    case TopLevelFunctionElement():
      return make('function', _executableSig(element));
    case GetterElement():
      final variable = element.variable;
      return make('variable', {
        'type': _type(element.returnType),
        'get': true,
        'set': writable,
        if (variable.isConst) 'const': true,
      }, display: variable.displayString());
    default:
      throw ExtractError(
        'unsupported exported element $name (${element.runtimeType})',
      );
  }
}

List<String> _supertypes(InterfaceElement element) => [
  for (final t in element.allSupertypes)
    if (!t.isDartCoreObject) _type(t),
]..sort();

Map<String, ApiMember> _members(
  InstanceElement element,
  bool Function(Element) isOwn,
  bool keepForeign,
) {
  final members = <String, ApiMember>{};
  // Getters and setters merge into one property per name.
  final getters = <String, GetterElement>{};
  final setters = <String, SetterElement>{};
  final methods = <String, MethodElement>{};

  void addExecutable(ExecutableElement e) {
    if (!e.isPublic) return;
    final name = e.name;
    if (name == null) return;
    switch (e) {
      case GetterElement():
        getters.putIfAbsent(name, () => e);
      case SetterElement():
        setters.putIfAbsent(name, () => e);
      case MethodElement():
        methods.putIfAbsent(name, () => e);
      default:
    }
  }

  // Declared members first (static ones included), then everything the
  // interface inherits.
  element.getters.forEach(addExecutable);
  element.setters.forEach(addExecutable);
  element.methods.forEach(addExecutable);
  if (element is InterfaceElement) {
    element.interfaceMembers.values.forEach(addExecutable);
  }

  final enumConstants = element is EnumElement
      ? element.constants
      : const <FieldElement>[];
  for (final (index, constant) in enumConstants.indexed) {
    members[constant.name!] = ApiMember(
      name: constant.name!,
      kind: 'value',
      display: constant.displayString(),
      sig: {'index': index},
      flags: _flags([constant]),
    );
  }

  // Names declared by a supertype outside the package (Flutter, the SDK).
  // A member the class declares itself under such a name is an override
  // (`ChangeNotifier.dispose`, `State.didChangeDependencies`): it is present
  // for a caller either way, so it counts as foreign, never as an addition.
  final foreignNames = <String>{};
  if (element is InterfaceElement) {
    for (final type in element.allSupertypes) {
      final s = type.element;
      if (isOwn(s)) continue;
      for (final e in <ExecutableElement>[
        ...s.getters,
        ...s.setters,
        ...s.methods,
      ]) {
        final name = e.name;
        if (e.isPublic && !e.isStatic && name != null) foreignNames.add(name);
      }
    }
  }

  bool keep(Element e) => keepForeign || isOwn(e);
  bool foreign(Element e) => !isOwn(e) || foreignNames.contains(e.name);

  for (final name in {...getters.keys, ...setters.keys}) {
    if (members.containsKey(name)) continue;
    final getter = getters[name];
    final setter = setters[name];
    final any = (getter ?? setter)!;
    final variable = any.variable;
    if (variable is FieldElement && variable.isOriginEnumValues) continue;
    if (!keep(any)) continue;
    final type = getter != null
        ? _type(getter.returnType)
        : _type(setter!.formalParameters.single.type);
    final setType = setter == null
        ? null
        : _type(setter.formalParameters.single.type);
    members[name] = ApiMember(
      name: name,
      kind: 'property',
      display: getter?.displayString() ?? setter!.displayString(),
      sig: {
        'type': type,
        'get': getter != null,
        'set': setter != null,
        if (setType != null && setType != type) 'setType': setType,
        if (any.isStatic) 'static': true,
        if (variable.isConst) 'const': true,
      },
      flags: _flags([getter, setter, variable]),
      foreign: foreign(any),
    );
  }
  for (final MapEntry(key: name, value: m) in methods.entries) {
    if (!keep(m)) continue;
    members[name] = ApiMember(
      name: name,
      kind: m.isOperator ? 'operator' : 'method',
      display: m.displayString(),
      sig: _executableSig(m),
      flags: _flags([m]),
      foreign: foreign(m),
    );
  }
  if (element is InterfaceElement && element is! EnumElement) {
    for (final c in element.constructors) {
      if (!c.isPublic) continue;
      final name = (c.name == null || c.name == 'new') ? 'new' : c.name!;
      members[name] = ApiMember(
        name: name,
        kind: 'constructor',
        display: c.displayString(),
        sig: {
          'const': c.isConst,
          'factory': c.isFactory,
          'params': _params(c.formalParameters),
        },
        flags: _flags([c]),
      );
    }
  }
  return members;
}
