// Compares xterm's API (the snapshot) with the adapter's and merges the
// hand-kept status file into one status per symbol and member.
//
// Status file (tool/xterm_compat/status.json): `entries` maps a key to
// `{"status": "differs" | "missing" | "wont", "reason": "..."}`. A key is a
// library (`zmodem.dart`), a symbol (`Terminal`) or a member
// (`Terminal.write`; `Terminal.new` is the unnamed constructor).
//
// Rules, applied per row:
// - A present member that matches xterm is ✅. Its own `differs` entry turns
//   it into ⚠️ (a behaviour difference the analyzer cannot see).
// - A present member whose signature differs is ⚠️, with the differences as
//   its note, or with its own `differs` entry's reason plus the differences.
//   `✅` cannot be forced: a signature difference always shows.
// - A missing member takes its own `missing`/`wont` entry, else the first
//   `missing`/`wont` entry of its symbol, else of its library, else the
//   default: ❌ "planned". Its own `differs` entry (written ahead by the task
//   that ports it) keeps it ❌ and shows the reason.
// - Errors (the check fails): a key that names nothing in xterm's API, a
//   `missing`/`wont` entry on something that exists (stale), an unknown
//   status or field, an empty reason.

import 'dart:convert';

import 'model.dart';

/// The status vocabulary of contratos.md §6.
enum Status {
  same('✅', 'same'),
  differs('⚠️', 'differs'),
  missing('❌', 'missing'),
  wont('🚫', "won't support");

  const Status(this.icon, this.label);
  final String icon;
  final String label;
}

/// The note of a missing member that has no status entry.
const defaultMissingReason = 'planned';

/// A hand-kept status entry.
final class StatusEntry {
  StatusEntry(this.status, this.reason);
  final Status status;
  final String reason;
}

/// The status file or the merge is wrong; [problems] lists every finding.
final class StatusError implements Exception {
  StatusError(this.problems);
  final List<String> problems;
  @override
  String toString() => problems.join('\n');
}

/// Parses the status file. Throws [StatusError] for a malformed entry.
Map<String, StatusEntry> parseStatus(String text) {
  final json = jsonDecode(text);
  if (json is! Map<String, Object?> || json['entries'] is! Map) {
    throw StatusError(['status file: expected an object with "entries"']);
  }
  final problems = <String>[
    for (final key in json.keys)
      if (key != 'comment' && key != 'entries')
        'status file: unknown top-level field "$key"',
  ];
  final entries = <String, StatusEntry>{};
  for (final MapEntry(:key, :value)
      in (json['entries']! as Map<String, Object?>).entries) {
    if (value is! Map<String, Object?>) {
      problems.add('$key: expected {"status": ..., "reason": ...}');
      continue;
    }
    final status = switch (value['status']) {
      'differs' => Status.differs,
      'missing' => Status.missing,
      'wont' => Status.wont,
      _ => null,
    };
    final reason = value['reason'];
    if (status == null) {
      problems.add(
        '$key: status "${value['status']}" is not differs, missing or wont',
      );
    }
    if (reason is! String || reason.trim().isEmpty) {
      problems.add('$key: needs a non-empty "reason"');
    }
    final extra = value.keys.toSet().difference({'status', 'reason'});
    if (extra.isNotEmpty) problems.add('$key: unknown fields $extra');
    if (status != null && reason is String) {
      entries[key] = StatusEntry(status, reason.trim());
    }
  }
  if (problems.isNotEmpty) throw StatusError(problems);
  return entries;
}

/// One row of the report: a symbol (member == null) or one of its members.
final class Row {
  Row({
    required this.symbol,
    required this.member,
    required this.status,
    required this.note,
  });
  final ApiSymbol symbol;
  final ApiMember? member;
  final Status status;
  final String note;

  String get key =>
      member == null ? symbol.name : '${symbol.name}.${member!.name}';
}

/// The merged result.
final class Comparison {
  Comparison(this.rows, this.additions);

  /// Symbols in snapshot order, each followed by its members.
  final List<Row> rows;

  /// Adapter members and symbols xterm does not have: `Symbol.member` or
  /// `Symbol` -> kind.
  final Map<String, String> additions;
}

/// Compares [xterm] with [ours] and merges [status]. Throws [StatusError]
/// listing every problem.
Comparison compare(
  ApiModel xterm,
  ApiModel ours,
  Map<String, StatusEntry> status,
) {
  final problems = <String>[];
  final known = <String>{...libraryOrder};
  final rows = <Row>[];
  final names = xterm.symbols.keys.toList()..sort();

  Row resolve(
    ApiSymbol symbol,
    ApiMember? member, {
    required bool present,
    required List<String> diffs,
    required List<String> notes,
    required List<String> cascade,
  }) {
    final key = member == null ? symbol.name : '${symbol.name}.${member.name}';
    final exact = status[key];
    Row row(Status s, String note) =>
        Row(symbol: symbol, member: member, status: s, note: note);
    String join(Iterable<String> parts) =>
        parts.where((p) => p.isNotEmpty).join('; ');

    if (!present) {
      if (exact != null) {
        // A `differs` entry may be written before the member lands (the
        // task that ports it records the difference up front).
        return exact.status == Status.differs
            ? row(
                Status.missing,
                '$defaultMissingReason; will differ: ${exact.reason}',
              )
            : row(exact.status, exact.reason);
      }
      for (final c in cascade) {
        final entry = status[c];
        if (entry != null && entry.status != Status.differs) {
          return row(entry.status, entry.reason);
        }
      }
      return row(Status.missing, defaultMissingReason);
    }
    if (exact != null && exact.status != Status.differs) {
      problems.add(
        '$key: status says "${exact.status.name}" but it exists '
        '(make it "differs" with a reason, or remove the entry)',
      );
    }
    if (exact != null && exact.status == Status.differs) {
      return row(Status.differs, join([exact.reason, ...diffs, ...notes]));
    }
    if (diffs.isNotEmpty) {
      return row(Status.differs, join([...diffs, ...notes]));
    }
    return row(Status.same, join(notes));
  }

  for (final name in names) {
    final x = xterm.symbols[name]!;
    known.add(name);
    for (final m in x.members.keys) {
      known.add('$name.$m');
    }
    final o = ours.symbols[name];
    final libCascade = [x.primaryLibrary];
    rows.add(
      resolve(
        x,
        null,
        present: o != null,
        diffs: o == null ? const [] : symbolDiffs(x, o),
        notes: const [],
        cascade: libCascade,
      ),
    );
    final memberNames = x.members.keys.toList()..sort(_memberOrder(x));
    for (final m in memberNames) {
      final xm = x.members[m]!;
      final om = o?.members[m];
      final flagNote = xm.flags.isEmpty
          ? <String>[]
          : ['xterm: ${xm.flags.map((f) => '@$f').join(' ')}'];
      final (diffs, notes) = om == null
          ? (const <String>[], const <String>[])
          : memberDiffs(xm, om);
      rows.add(
        resolve(
          x,
          xm,
          present: om != null,
          diffs: diffs,
          notes: [...notes, ...flagNote],
          cascade: [name, ...libCascade],
        ),
      );
    }
  }

  for (final key in status.keys) {
    if (!known.contains(key)) {
      problems.add('$key: names nothing in xterm 4.0.0\'s API (typo?)');
    }
  }
  if (problems.isNotEmpty) throw StatusError(problems);

  final additions = <String, String>{};
  for (final MapEntry(key: name, value: o) in ours.symbols.entries) {
    final x = xterm.symbols[name];
    if (x == null) {
      additions[name] = o.kind;
      continue;
    }
    for (final MapEntry(key: m, value: om) in o.members.entries) {
      if (!om.foreign && !x.members.containsKey(m)) {
        additions['$name.$m'] = om.kind;
      }
    }
  }
  return Comparison(rows, additions);
}

/// Constructors first, then enum values in index order, then the rest by
/// name.
Comparator<String> _memberOrder(ApiSymbol s) => (a, b) {
  final x = s.members[a]!, y = s.members[b]!;
  int rank(ApiMember m) => switch (m.kind) {
    'constructor' => 0,
    'value' => 1,
    _ => 2,
  };
  final r = rank(x) - rank(y);
  if (r != 0) return r;
  if (x.kind == 'value') {
    return (x.sig['index']! as int) - (y.sig['index']! as int);
  }
  if (x.kind == 'constructor') {
    if (a == 'new') return -1;
    if (b == 'new') return 1;
  }
  return a.compareTo(b);
};

String _code(Object? s) => '`$s`';

/// Differences of a symbol's declaration that break xterm callers.
List<String> symbolDiffs(ApiSymbol x, ApiSymbol o) {
  final diffs = <String>[];
  if (x.kind != o.kind) {
    diffs.add('is a ${o.kind} (xterm: ${x.kind})');
    return diffs;
  }
  for (final lib in x.libraries) {
    if (!o.libraries.contains(lib)) diffs.add('not exported from $lib');
  }
  final xs = x.sig, os = o.sig;
  if (xs['typeParameters'] != os['typeParameters']) {
    diffs.add(
      'type parameters ${_code(os['typeParameters'])} '
      '(xterm: ${_code(xs['typeParameters'])})',
    );
  }
  final xMods = ((xs['modifiers'] as List<Object?>?) ?? const []).toSet();
  final oMods = ((os['modifiers'] as List<Object?>?) ?? const []).toSet();
  for (final mod in ['abstract', 'sealed', 'base', 'interface', 'final']) {
    if (oMods.contains(mod) && !xMods.contains(mod)) {
      diffs.add('is $mod (xterm: not)');
    }
  }
  if (xMods.contains('mixin') && !oMods.contains('mixin')) {
    diffs.add('is not a mixin class');
  }
  final xSuper = ((xs['supertypes'] as List<Object?>?) ?? const []);
  final oSuper = ((os['supertypes'] as List<Object?>?) ?? const []).toSet();
  for (final t in xSuper) {
    if (!oSuper.contains(t)) diffs.add('is not a ${_code(t)}');
  }
  for (final field in ['on', 'aliased', 'type']) {
    if (xs[field] != os[field]) {
      diffs.add('$field ${_code(os[field])} (xterm: ${_code(xs[field])})');
    }
  }
  if (x.kind == 'function') {
    final (d, _) = _executableDiffs(xs, os);
    diffs.addAll(d);
  }
  if (x.kind == 'variable') {
    if (xs['const'] == true && os['const'] != true) diffs.add('not const');
    if (xs['set'] == true && os['set'] != true) diffs.add('not assignable');
  }
  return diffs;
}

/// (differences that break xterm callers, additive notes) of a member.
(List<String>, List<String>) memberDiffs(ApiMember x, ApiMember o) {
  final diffs = <String>[];
  final notes = <String>[];
  if (x.kind != o.kind) {
    diffs.add('is a ${o.kind} (xterm: ${x.kind})');
    return (diffs, notes);
  }
  final xs = x.sig, os = o.sig;
  if ((xs['static'] ?? false) != (os['static'] ?? false)) {
    diffs.add(xs['static'] == true ? 'not static' : 'static');
  }
  switch (x.kind) {
    case 'value':
      if (xs['index'] != os['index']) {
        diffs.add('index ${os['index']} (xterm: ${xs['index']})');
      }
    case 'property':
      if (xs['get'] == true && os['get'] != true) diffs.add('no getter');
      if (xs['set'] == true && os['set'] != true) diffs.add('read-only');
      if (xs['type'] != os['type']) {
        diffs.add('type ${_code(os['type'])} (xterm: ${_code(xs['type'])})');
      }
      if (xs['set'] == true &&
          os['set'] == true &&
          (xs['setType'] ?? xs['type']) != (os['setType'] ?? os['type'])) {
        diffs.add('setter takes ${_code(os['setType'] ?? os['type'])}');
      }
      if (xs['const'] == true && os['const'] != true) diffs.add('not const');
    case 'constructor':
      if (xs['const'] == true && os['const'] != true) diffs.add('not const');
      if (xs['factory'] != true && os['factory'] == true) {
        diffs.add('factory (cannot be a super constructor)');
      }
      final (d, n) = _paramDiffs(xs['params']! as List, os['params']! as List);
      diffs.addAll(d);
      notes.addAll(n);
    default:
      final (d, n) = _executableDiffs(xs, os);
      diffs.addAll(d);
      notes.addAll(n);
  }
  return (diffs, notes);
}

(List<String>, List<String>) _executableDiffs(
  Map<String, Object?> xs,
  Map<String, Object?> os,
) {
  final diffs = <String>[];
  if (xs['returns'] != os['returns']) {
    diffs.add(
      'returns ${_code(os['returns'])} (xterm: ${_code(xs['returns'])})',
    );
  }
  if (xs['typeParameters'] != os['typeParameters']) {
    diffs.add(
      'type parameters ${_code(os['typeParameters'])} '
      '(xterm: ${_code(xs['typeParameters'])})',
    );
  }
  final (d, n) = _paramDiffs(xs['params']! as List, os['params']! as List);
  return ([...diffs, ...d], n);
}

String _normalize(Object? code) =>
    code == null ? '' : (code as String).replaceAll(RegExp(r'\s+'), '');

(List<String>, List<String>) _paramDiffs(List<Object?> xp, List<Object?> op) {
  final diffs = <String>[];
  final notes = <String>[];
  final x = xp.cast<Map<String, Object?>>();
  final o = op.cast<Map<String, Object?>>();
  bool positional(Map<String, Object?> p) =>
      p['kind'] == 'positional' || p['kind'] == 'optional';
  final xPos = x.where(positional).toList();
  final oPos = o.where(positional).toList();
  final xNamed = {for (final p in x.where((p) => !positional(p))) p['name']: p};
  final oNamed = {for (final p in o.where((p) => !positional(p))) p['name']: p};

  void compareParam(
    String label,
    Map<String, Object?> a,
    Map<String, Object?> b,
  ) {
    if (a['kind'] != b['kind']) {
      diffs.add('$label is ${b['kind']} (xterm: ${a['kind']})');
    }
    if (a['type'] != b['type']) {
      diffs.add(
        '$label has type ${_code(b['type'])} (xterm: ${_code(a['type'])})',
      );
    }
    if (_normalize(a['default']) != _normalize(b['default'])) {
      diffs.add(
        '$label defaults to ${_code(b['default'] ?? 'null')} '
        '(xterm: ${_code(a['default'] ?? 'null')})',
      );
    }
  }

  for (final (i, p) in xPos.indexed) {
    final label = 'parameter ${i + 1} (`${p['name']}`)';
    if (i >= oPos.length) {
      diffs.add('$label missing');
    } else {
      compareParam(label, p, oPos[i]);
    }
  }
  for (final p in oPos.skip(xPos.length)) {
    if (p['kind'] == 'optional') {
      notes.add('adds optional `${p['name']}`');
    } else {
      diffs.add('adds required parameter `${p['name']}`');
    }
  }
  for (final MapEntry(key: name, value: p) in xNamed.entries) {
    final q = oNamed[name];
    if (q == null) {
      diffs.add('named parameter `$name` missing');
    } else {
      compareParam('`$name`', p, q);
    }
  }
  for (final MapEntry(key: name, value: p) in oNamed.entries) {
    if (xNamed.containsKey(name)) continue;
    if (p['kind'] == 'named') {
      notes.add('adds `$name`');
    } else {
      diffs.add('adds required named parameter `$name`');
    }
  }
  return (diffs, notes);
}
