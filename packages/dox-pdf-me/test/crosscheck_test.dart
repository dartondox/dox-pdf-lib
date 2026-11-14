// Crosscheck with the real pdfme: tool/crosscheck/render.mjs draws the
// cases of tool/crosscheck/cases.mjs with @pdfme/generator, this test draws
// the same cases with dox_pdf_me, and pdftoppm renders both. The pages must
// look the same.
//
// Needs `npm ci` in tool/crosscheck (Node.js) and pdftoppm (poppler). Without
// them the test is skipped. CI always runs it. zbarimg (zbar-tools) is
// optional: with it, the QR codes, Data Matrix and PDF417 codes of both
// sides are decoded and must give the same text.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';
import 'package:test/test.dart';

import 'support.dart';

const String outDir = '.dart_tool/crosscheck';
const String fixtureDir = 'test/fixtures/crosscheck';

/// The largest share of pixels that may differ, per kind of case.
const Map<String, double> tolerance = <String, double>{
  'pixels': 0.004,
  'barcode': 0.03,
  'matrix': 0.1,
};

void main() {
  bool ready = hasPdfme && hasTool('pdftoppm');
  bool zbar = hasTool('zbarimg', <String>['--version']);
  List<Map<String, dynamic>> cases = <Map<String, dynamic>>[];

  setUpAll(() async {
    if (!ready) return;
    if (!await fetchTestFonts()) fail('can not download the test fonts');
    for (String old in <String>['png', 'zbar']) {
      Directory d = Directory('$outDir/$old');
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    Directory(outDir).createSync(recursive: true);
    Directory('$outDir/pdfme').createSync(recursive: true);
    Directory('$outDir/dox').createSync(recursive: true);
    ProcessResult r = Process.runSync('node', <String>[
      '$crosscheckDir/render.mjs',
      '$outDir/pdfme',
      fixtureDir,
      testFontDir,
    ]);
    if (r.exitCode != 0) fail('render.mjs failed: ${r.stderr}');
    String json = File('$outDir/pdfme/cases.json').readAsStringSync();
    cases = <Map<String, dynamic>>[
      for (Object? c in jsonDecode(json) as List<dynamic>)
        c! as Map<String, dynamic>,
    ];
  });

  test('every case looks like pdfme', () async {
    List<String> failures = <String>[];
    for (Map<String, dynamic> c in cases) {
      String name = c['name'] as String;
      String compare = c['compare'] as String;
      Uint8List bytes = await generate(
        template: _resolve(c['template']) as Map<String, dynamic>,
        inputs: <Map<String, dynamic>>[
          for (Object? i in _resolve(c['inputs']) as List<dynamic>)
            i! as Map<String, dynamic>,
        ],
        options: _resolve(c['options'] ?? <String, dynamic>{}),
        plugins: builtInPlugins,
      );
      File('$outDir/dox/$name.pdf').writeAsBytesSync(bytes);
      List<Ppm> ours = renderPages(
        '$outDir/dox/$name.pdf',
        '$outDir/png/$name/dox',
      );
      List<Ppm> theirs = renderPages(
        '$outDir/pdfme/$name.pdf',
        '$outDir/png/$name/pdfme',
      );
      if (ours.length != theirs.length) {
        failures.add('$name: ${ours.length} pages, pdfme ${theirs.length}');
        continue;
      }
      for (int p = 0; p < ours.length; p++) {
        Ppm a = ours[p];
        Ppm b = theirs[p];
        if (a.width != b.width || a.height != b.height) {
          failures.add(
            '$name page $p: size ${a.width}x${a.height}, '
            'pdfme ${b.width}x${b.height}',
          );
          continue;
        }
        double diff = pixelDifference(a, b);
        double limit = tolerance[compare]!;
        printOnFailure('$name page $p: ${(diff * 100).toStringAsFixed(3)} %');
        if (diff > limit) {
          failures.add(
            '$name page $p: ${(diff * 100).toStringAsFixed(3)} % '
            'of the pixels differ (limit ${limit * 100} %)',
          );
        }
      }
      if (compare == 'matrix' && zbar) {
        List<String> a = _decode('$outDir/dox/$name.pdf', '$name/dox');
        List<String> b = _decode('$outDir/pdfme/$name.pdf', '$name/pdfme');
        printOnFailure('$name decoded: $a');
        if (a.join('\n') != b.join('\n')) {
          failures.add('$name: decoded $a, pdfme $b');
        }
        if (name == 'barcodes-2d' &&
            !a.contains('QR-Code:https://github.com/dartondox/dox-pdf-lib')) {
          failures.add('$name: the first QR code was not decoded: $a');
        }
      }
    }
    expect(failures, isEmpty);
  }, skip: ready ? false : 'needs npm ci in tool/crosscheck and pdftoppm');
}

/// The decoded codes of the pages of [pdf] (rendered at 200 dpi), sorted.
List<String> _decode(String pdf, String name) {
  String dir = '$outDir/zbar/$name';
  renderPages(pdf, dir, dpi: 200);
  List<String> out = <String>[];
  for (FileSystemEntity f in Directory(dir).listSync()) {
    ProcessResult r = Process.runSync('zbarimg', <String>['--quiet', f.path]);
    out.addAll(
      (r.stdout as String).split('\n').where((String l) => l.isNotEmpty),
    );
  }
  return out..sort();
}

/// `{"$file": name, "prefix": ...}` is the base64 of a fixture or a test
/// font; `{"$default": true}` is the default font.
Object? _resolve(Object? value) {
  if (value is List) return <Object?>[for (Object? v in value) _resolve(v)];
  if (value is! Map) return value;
  if (value.containsKey(r'$file')) {
    String name = value[r'$file'] as String;
    File file = File('$fixtureDir/$name');
    if (!file.existsSync()) file = File('$testFontDir/$name');
    return '${value['prefix'] ?? ''}${base64.encode(file.readAsBytesSync())}';
  }
  if (value.containsKey(r'$default')) return FontStore.defaultFont.data;
  return <String, dynamic>{
    for (MapEntry<dynamic, dynamic> e in value.entries)
      '${e.key}': _resolve(e.value),
  };
}
