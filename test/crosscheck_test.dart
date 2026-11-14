// Compares what dox_pdf_lib reads with what pdf-lib (Node.js) reads, for
// files made by both. Needs `npm ci` in tool/crosscheck; skipped without it.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// pdftoppm (poppler) renders for the pixel compare. CI installs it.
bool get _canRender =>
    Process.runSync('sh', <String>['-c', 'command -v pdftoppm']).exitCode == 0;

/// Page 1 of [pdf] as gray pixels at 50 dpi: (width, height, pixels).
(int, int, Uint8List) _render(String pdf) {
  String prefix = pdf.replaceAll('.pdf', '');
  ProcessResult r = Process.runSync('pdftoppm', <String>[
    '-gray',
    '-r',
    '50',
    '-singlefile',
    pdf,
    prefix,
  ]);
  if (r.exitCode != 0) fail('pdftoppm: ${r.stderr}');
  Uint8List b = File('$prefix.pgm').readAsBytesSync();
  // P5 header: magic, width, height, max value, each ends at white space
  List<String> head = <String>[];
  int at = 0;
  while (head.length < 4) {
    int start = at;
    while (b[at] > 32) {
      at++;
    }
    head.add(String.fromCharCodes(b, start, at));
    at++;
  }
  return (int.parse(head[1]), int.parse(head[2]), Uint8List.sublistView(b, at));
}

/// The attachments that pdf-lib reads, per file.
Future<List<Object?>> _attachments(List<String> files) async {
  ProcessResult r = await Process.run('node', <String>[
    '$_dir/attachments.mjs',
    ...files,
  ]);
  if (r.exitCode != 0) fail('attachments.mjs: ${r.stderr}');
  return <Object?>[
    for (String line in LineSplitter.split(r.stdout as String))
      jsonDecode(line),
  ];
}

/// Our view of the attachments, in the shape of attachments.mjs.
Map<String, Object?> _ourAttachments(PDFDocument doc) {
  String? date(DateTime? d) => d == null
      ? null
      : 'D:${d.toUtc().toIso8601String().replaceAll(RegExp(r'[-:T]'), '').substring(0, 14)}Z';
  List<PDFAttachment> files = doc.getAttachments();
  return <String, Object?>{
    'files': <Object?>[
      for (PDFAttachment f in files)
        <String, Object?>{
          'key': f.name,
          'name': f.name,
          'data': base64Encode(f.data),
          'mimeType': f.mimeType,
          'description': f.description,
          'creationDate': date(f.creationDate),
          'modificationDate': date(f.modificationDate),
          'afRelationship': f.afRelationship,
        },
    ],
    'af': files.length,
  };
}

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

  test('embed, drawPage and attach match pdf-lib', () async {
    ProcessResult r = await Process.run('node', <String>[
      '$_dir/embed.mjs',
      tmp.path,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    Uint8List source = File('${tmp.path}/embed-source.pdf').readAsBytesSync();

    // the same steps as embed.mjs
    PDFDocument doc = await PDFDocument.create();
    PDFEmbeddedPage whole = (await doc.embedPdf(source)).single;
    PDFDocument src = await PDFDocument.load(source);
    PDFEmbeddedPage clipped = await doc.embedPage(src.getPage(0), (
      left: 20,
      bottom: 100,
      right: 220,
      top: 180,
    ));
    PDFPage page = doc.addPage(<double>[500, 500]);
    page.drawPage(whole, x: 20, y: 20, xScale: 0.5, yScale: 0.5);
    page.drawPage(
      whole,
      x: 300,
      y: 100,
      rotate: degrees(30),
      opacity: 0.5,
      blendMode: BlendMode.multiply,
    );
    page.drawPage(
      clipped,
      x: 20,
      y: 300,
      width: 400,
      height: 160,
      xSkew: degrees(10),
    );
    await doc.attach(
      Uint8List.fromList(utf8.encode('hello from pdf-lib')),
      'hello.txt',
      mimeType: 'text/plain',
      description: 'Grüße',
      creationDate: DateTime.utc(2020, 1, 2, 3, 4, 5),
      modificationDate: DateTime.utc(2021, 1, 2, 3, 4, 5),
      afRelationship: AFRelationship.data,
    );
    String ours = '${tmp.path}/embed-dox.pdf';
    File(ours).writeAsBytesSync(await doc.save());
    String theirs = '${tmp.path}/embed-pdflib.pdf';

    // pdf-lib reads our attachment like its own, and we read its one
    List<Object?> read = await _attachments(<String>[ours, theirs]);
    expect(read[0], read[1]);
    PDFDocument theirDoc = await PDFDocument.load(
      File(theirs).readAsBytesSync(),
    );
    expect(_ourAttachments(theirDoc), read[1]);

    if (!_canRender) {
      markTestSkipped('no pdftoppm: pixels not compared');
      return;
    }
    (int, int, Uint8List) a = _render(ours);
    (int, int, Uint8List) b = _render(theirs);
    expect((a.$1, a.$2), (b.$1, b.$2));
    int off = 0;
    for (int i = 0; i < a.$3.length; i++) {
      if ((a.$3[i] - b.$3[i]).abs() > 24) off++;
    }
    // a few edge pixels may differ from rounding
    expect(off / a.$3.length, lessThan(0.002), reason: '$off pixels differ');
    // and the page is not blank
    expect(a.$3.where((int v) => v < 200).length, greaterThan(1000));
  }, skip: _ready ? false : 'run npm ci in tool/crosscheck');

  test('pdfdetach sees files attached to a tree with Kids', () async {
    if (!_canRender) {
      markTestSkipped('no poppler: pdfdetach not run');
      return;
    }
    String spec(String n, int stream) =>
        '<< /Type /Filespec /F ($n) /UF ($n) /EF << /F $stream 0 R >> >>';
    Uint8List input = buildPdf(<String>[
      '<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles 4 0 R >> >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] >>',
      '<< /Kids [5 0 R 6 0 R] >>',
      '<< /Limits [(b) (d)] /Names [(b) 7 0 R (d) 8 0 R] >>',
      '<< /Limits [(m) (p)] /Names [(m) 9 0 R (p) 10 0 R] >>',
      spec('b', 11),
      spec('d', 11),
      spec('m', 11),
      spec('p', 11),
      '<< /Type /EmbeddedFile /Length 1 >>\nstream\nx\nendstream',
    ]);
    PDFDocument doc = await PDFDocument.load(input);
    for (String n in <String>['a', 'c', 'n', 'z']) {
      await doc.attach(Uint8List.fromList(utf8.encode(n)), n);
    }
    String path = '${tmp.path}/kids.pdf';
    File(path).writeAsBytesSync(await doc.save());
    ProcessResult r = Process.runSync('pdfdetach', <String>['-list', path]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    List<String> names = <String>[
      for (String line in LineSplitter.split(r.stdout as String))
        if (line.contains(': ')) line.substring(line.indexOf(': ') + 2),
    ];
    // all found. The order is by key bytes: our keys are UTF-16 with a BOM
    // (like pdf-lib), so they sort after the plain (b) ... (p) keys
    expect(names, <String>['b', 'd', 'm', 'p', 'a', 'c', 'n', 'z']);
  });

  test('a pending embed of a template is in what is copied out', () async {
    if (!_canRender) {
      markTestSkipped('no pdftoppm: pixels not compared');
      return;
    }
    Uint8List source = buildPdf(<String>[
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>',
      '<< /Length 16 >>\nstream\n0 0 100 100 re f\nendstream',
    ]);
    PDFDocument template = await PDFDocument.load(source);
    // page 2 of the template draws page 1, embedded but not saved yet
    PDFEmbeddedPage own = await template.embedPage(template.getPage(0));
    template.addPage(<double>[100, 100]).drawPage(own);
    PDFPage drawn = template.getPage(1);

    PDFDocument a = await PDFDocument.create();
    a.addPage(<double>[100, 100]).drawPage(await a.embedPage(drawn));
    PDFDocument b = await PDFDocument.create();
    b.addPage((await b.copyPages(template, <int>[1])).single);
    for (PDFDocument out in <PDFDocument>[a, b]) {
      String path = '${tmp.path}/pending-${out == a ? 'embed' : 'copy'}.pdf';
      File(path).writeAsBytesSync(await out.save());
      (int, int, Uint8List) px = _render(path);
      int dark = px.$3.where((int v) => v < 100).length;
      expect(dark, greaterThan(px.$3.length * 0.9), reason: path);
    }
  });

  test('drawPage keeps the order with drawText, and a changed template is embedded again', () async {
    if (!_canRender) {
      markTestSkipped('no pdftoppm: pixels not compared');
      return;
    }
    ProcessResult r = await Process.run('node', <String>[
      '$_dir/embed.mjs',
      tmp.path,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    Uint8List source = File('${tmp.path}/embed-source.pdf').readAsBytesSync();

    PDFDocument order = await PDFDocument.create();
    PDFEmbeddedPage o = (await order.embedPdf(source)).single;
    PDFPage op = order.addPage(<double>[400, 300]);
    op.drawPage(o, x: 0, y: 0);
    op.drawText('Over', x: 20, y: 60, size: 90, color: rgb(0, 0.6, 0));
    op.drawPage(o, x: 150, y: 40, xScale: 0.5, yScale: 0.5);

    PDFDocument redo = await PDFDocument.create();
    PDFDocument template = await PDFDocument.load(source);
    PDFEmbeddedPage first = await redo.embedPage(template.getPage(0));
    template
        .getPage(0)
        .drawText('Changed', x: 20, y: 20, size: 40, color: rgb(0, 0, 0.5));
    PDFEmbeddedPage again = await redo.embedPage(template.getPage(0));
    expect(again.ref, isNot(first.ref), reason: 'the source changed');
    redo.addPage(<double>[300, 200]).drawPage(again);

    for ((PDFDocument, String) c in <(PDFDocument, String)>[
      (order, 'embed-order'),
      (redo, 'embed-redo'),
    ]) {
      String ours = '${tmp.path}/${c.$2}-dox.pdf';
      File(ours).writeAsBytesSync(await c.$1.save());
      (int, int, Uint8List) a = _render(ours);
      (int, int, Uint8List) b = _render('${tmp.path}/${c.$2}.pdf');
      expect((a.$1, a.$2), (b.$1, b.$2));
      int off = 0;
      for (int i = 0; i < a.$3.length; i++) {
        if ((a.$3[i] - b.$3[i]).abs() > 24) off++;
      }
      expect(off / a.$3.length, lessThan(0.002), reason: '${c.$2}: $off');
    }
  }, skip: _ready ? false : 'run npm ci in tool/crosscheck');
}
