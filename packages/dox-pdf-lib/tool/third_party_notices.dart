// Writes THIRD_PARTY_NOTICES: the licenses of the Rust crates that are
// compiled into the native library. Run it in packages/dox-pdf-lib after a
// change of native/Cargo.toml or native/Cargo.lock:
//
//   dart run tool/third_party_notices.dart
//
// With `--check` it only fails when the file is not up to date (CI).
//
// It reads `cargo metadata` for the 5 release targets, takes the normal
// (not build or dev) dependencies, and leaves out proc-macro crates: they
// run at build time and are not in the library. For each crate it copies
// the license files of the crate package (LICENSE*, COPYING*, NOTICE*).
import 'dart:convert';
import 'dart:io';

const List<String> targets = <String>[
  'aarch64-apple-darwin',
  'x86_64-apple-darwin',
  'x86_64-unknown-linux-gnu',
  'aarch64-unknown-linux-gnu',
  'x86_64-pc-windows-msvc',
];

const String output = 'THIRD_PARTY_NOTICES';

const String header = '''
THIRD PARTY NOTICES

The native library of dox_pdf_lib (libdox_pdf_lib.so, libdox_pdf_lib.dylib,
dox_pdf_lib.dll) contains code and data of the projects below. Their
licenses and copyright notices follow.

dox_pdf_lib itself is under the MIT license (see LICENSE).

===============================================================================
ICU (ICU4C dictionary break engines)
===============================================================================

native/src/segment.rs is a port of the Thai, Lao, Burmese and Khmer
dictionary break engines of ICU4C (icu4c/source/common/dictbe.cpp, ICU 78),
https://github.com/unicode-org/icu

Copyright (C) 2016 and later: Unicode, Inc. and others.
Copyright (C) 2006-2016, International Business Machines Corporation
and others. All Rights Reserved.

License: Unicode License V3 (full text below).

The Thai, Lao, Khmer and Myanmar word lists come from ICU4X
(icu_segmenter_data, https://github.com/unicode-org/icu4x), which takes them
from ICU. Copyright (C) 2020 and later: Unicode, Inc. and others. Unicode
License V3.

UNICODE_LICENSE

===============================================================================
Rust crates
===============================================================================
''';

Future<void> main(List<String> args) async {
  bool check = args.contains('--check');
  Map<String, Map<String, dynamic>> crates = <String, Map<String, dynamic>>{};
  for (String target in targets) {
    ProcessResult r = Process.runSync('cargo', <String>[
      'metadata',
      '--format-version',
      '1',
      '--locked',
      '--filter-platform',
      target,
    ], workingDirectory: 'native');
    if (r.exitCode != 0) {
      stderr.writeln('cargo metadata failed: ${r.stderr}');
      exit(1);
    }
    Map<String, dynamic> meta =
        jsonDecode(r.stdout as String) as Map<String, dynamic>;
    Map<String, Map<String, dynamic>> packages = <String, Map<String, dynamic>>{
      for (dynamic p in meta['packages'] as List<dynamic>)
        p['id'] as String: p as Map<String, dynamic>,
    };
    Map<String, dynamic> resolve = meta['resolve'] as Map<String, dynamic>;
    Map<String, Map<String, dynamic>> nodes = <String, Map<String, dynamic>>{
      for (dynamic n in resolve['nodes'] as List<dynamic>)
        n['id'] as String: n as Map<String, dynamic>,
    };
    List<String> stack = <String>[resolve['root'] as String];
    Set<String> seen = <String>{};
    while (stack.isNotEmpty) {
      for (dynamic dep in nodes[stack.removeLast()]!['deps'] as List<dynamic>) {
        bool normal = (dep['dep_kinds'] as List<dynamic>).any(
          (dynamic k) => k['kind'] == null,
        );
        String id = dep['pkg'] as String;
        if (!normal || !seen.add(id)) continue;
        Map<String, dynamic> package = packages[id]!;
        bool procMacro = (package['targets'] as List<dynamic>).any(
          (dynamic t) => (t['kind'] as List<dynamic>).contains('proc-macro'),
        );
        if (procMacro) continue;
        crates['${package['name']} ${package['version']}'] = package;
        stack.add(id);
      }
    }
  }

  Map<String, List<File>> filesOf = <String, List<File>>{
    for (String key in crates.keys) key: _licenseFiles(crates[key]!),
  };
  String? unicode = crates.entries
      .where(
        (MapEntry<String, Map<String, dynamic>> e) =>
            e.key.startsWith('icu_segmenter '),
      )
      .map((MapEntry<String, Map<String, dynamic>> e) => filesOf[e.key]!)
      .where((List<File> f) => f.isNotEmpty)
      .map((List<File> f) => f.first.readAsStringSync().trimRight())
      .firstOrNull;
  if (unicode == null) {
    stderr.writeln('no license file of icu_segmenter');
    exit(1);
  }
  StringBuffer out = StringBuffer(
    header.replaceFirst('UNICODE_LICENSE', unicode),
  );
  List<String> missing = <String>[];
  // a license text that is the same as one above is not repeated
  Map<String, String> printed = <String, String>{};
  for (String key in crates.keys.toList()..sort()) {
    Map<String, dynamic> package = crates[key]!;
    List<File> files = filesOf[key]!;
    String? from;
    // a crate without its own license file: the file of another crate of
    // the same repository (eg. alloc-stdlib and alloc-no-stdlib)
    if (files.isEmpty) {
      for (String other in filesOf.keys) {
        if (filesOf[other]!.isNotEmpty &&
            crates[other]!['repository'] == package['repository'] &&
            crates[other]!['license'] == package['license']) {
          files = filesOf[other]!;
          from = other;
          break;
        }
      }
    }
    out
      ..writeln()
      ..writeln('-' * 79)
      ..writeln(key)
      ..writeln('License: ${package['license']}')
      ..writeln('Source: ${package['repository'] ?? ''}')
      ..writeln('-' * 79);
    if (from != null) {
      out
        ..writeln()
        ..writeln('(The crate has no license file. The file of $from, from the')
        ..writeln('same repository, follows.)');
    }
    if (files.isEmpty) missing.add(key);
    for (File f in files) {
      String name = f.uri.pathSegments.last;
      String text = f.readAsStringSync().trimRight();
      String? first = printed[text];
      if (first != null) {
        out
          ..writeln()
          ..writeln('$name: the same text as $first above.');
        continue;
      }
      printed[text] = '$name of $key';
      out
        ..writeln()
        ..writeln('$name:')
        ..writeln()
        ..writeln(text);
    }
  }

  if (missing.isNotEmpty) {
    stderr.writeln('no license file in the crate package: $missing');
    exit(1);
  }
  String text = out.toString();
  File file = File(output);
  if (check) {
    if (!file.existsSync() || file.readAsStringSync() != text) {
      stderr.writeln(
        '$output is not up to date. Run '
        'dart run tool/third_party_notices.dart in packages/dox-pdf-lib.',
      );
      exit(1);
    }
    return;
  }
  file.writeAsStringSync(text);
  print('wrote ${crates.length} crates to $output');
}

List<File> _licenseFiles(Map<String, dynamic> package) {
  Directory dir = File(package['manifest_path'] as String).parent;
  return dir
      .listSync()
      .whereType<File>()
      .where(
        (File f) => RegExp(
          r'^(LICEN[CS]E|COPYING|NOTICE|UNLICENSE)',
          caseSensitive: false,
        ).hasMatch(f.uri.pathSegments.last),
      )
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
}
