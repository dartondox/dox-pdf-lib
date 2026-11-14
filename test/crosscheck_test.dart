// Compares what dox_pdf_lib reads with what pdf-lib (Node.js) reads, for
// files made by both. Needs `npm ci` in tool/crosscheck; skipped without it.
import 'dart:convert';
import 'dart:io';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

import 'support.dart';

const String _dir = 'tool/crosscheck';

bool get _ready => Directory('$_dir/node_modules/pdf-lib').existsSync();

/// pdf-lib's view of each file.
Future<List<Object?>> _inspect(List<String> files) async {
  ProcessResult r = await Process.run('node', <String>[
    '$_dir/inspect.mjs',
    ...files,
  ]);
  if (r.exitCode != 0) fail('inspect.mjs: ${r.stderr}');
  return <Object?>[
    for (String line in LineSplitter.split(r.stdout as String))
      _numbersAsDouble(jsonDecode(line)),
  ];
}

/// JSON gives 612 as an int; Dart reads doubles.
Object? _numbersAsDouble(Object? v) => switch (v) {
  int() => v.toDouble(),
  List<Object?>() => v.map(_numbersAsDouble).toList(),
  Map<String, Object?>() => v.map(
    (String k, Object? e) => MapEntry<String, Object?>(
      k,
      k == 'pageCount' ? e : _numbersAsDouble(e),
    ),
  ),
  _ => v,
};

void main() {
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('dox_pdf_lib'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('pdf-lib reads files made by dox_pdf_lib the same', () async {
    PDFDocument doc = await PDFDocument.create();
    doc
      ..setTitle('Grüße 世界 😀')
      ..setAuthor('Ann')
      ..setSubject('Sub')
      ..setKeywords(<String>['x', 'y'])
      ..setLanguage('fr-FR')
      ..setCreationDate(DateTime.utc(2020, 1, 2, 3, 4, 5))
      ..setModificationDate(DateTime.utc(2021, 6, 7, 8, 9, 10));
    doc.addPage(PageSizes.A4);
    doc.addPage(PageSizes.Letter).setRotation(degrees(90));
    PDFPage boxes = doc.addPage(<double>[300.5, 400.25])
      ..setCropBox(1, 2, 200, 300)
      ..setTrimBox(3, 4, 50, 60);
    boxes.setBleedBox(5, 6, 70, 80);

    List<String> files = <String>[];
    for (bool streams in <bool>[true, false]) {
      String path = '${tmp.path}/dox-$streams.pdf';
      File(path).writeAsBytesSync(await doc.save(useObjectStreams: streams));
      files.add(path);
    }
    List<Object?> theirs = await _inspect(files);
    for (int i = 0; i < files.length; i++) {
      PDFDocument ours = await PDFDocument.load(
        File(files[i]).readAsBytesSync(),
        updateMetadata: false,
      );
      expect(describe(ours), theirs[i], reason: files[i]);
    }
  }, skip: _ready ? false : 'run npm ci in tool/crosscheck');

  test('dox_pdf_lib reads files made by pdf-lib the same', () async {
    ProcessResult r = await Process.run('node', <String>[
      '$_dir/make.mjs',
      tmp.path,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    List<String> files = <String>[
      '${tmp.path}/made-by-pdf-lib.pdf',
      '${tmp.path}/plain-xref.pdf',
    ];
    List<Object?> theirs = await _inspect(files);
    for (int i = 0; i < files.length; i++) {
      PDFDocument ours = await PDFDocument.load(
        File(files[i]).readAsBytesSync(),
        updateMetadata: false,
      );
      expect(describe(ours), theirs[i], reason: files[i]);
    }
  }, skip: _ready ? false : 'run npm ci in tool/crosscheck');

  test('a merge made by dox_pdf_lib reads the same in pdf-lib', () async {
    await Process.run('node', <String>['$_dir/make.mjs', tmp.path]);
    PDFDocument a = await PDFDocument.load(
      File('${tmp.path}/made-by-pdf-lib.pdf').readAsBytesSync(),
    );
    PDFDocument b = await PDFDocument.load(
      File('${tmp.path}/plain-xref.pdf').readAsBytesSync(),
    );
    PDFDocument merged = await PDFDocument.create();
    for (PDFDocument src in <PDFDocument>[a, b]) {
      for (PDFPage p in await merged.copyPages(src, src.getPageIndices())) {
        merged.addPage(p);
      }
    }
    String path = '${tmp.path}/merged.pdf';
    File(path).writeAsBytesSync(await merged.save());
    Map<String, Object?> theirs =
        (await _inspect(<String>[path])).single! as Map<String, Object?>;
    expect(theirs['pageCount'], 42);
    expect(
      describe(
        await PDFDocument.load(
          File(path).readAsBytesSync(),
          updateMetadata: false,
        ),
      )['pages'],
      theirs['pages'],
    );
  }, skip: _ready ? false : 'run npm ci in tool/crosscheck');
}
