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

/// The pages are rendered at this resolution (1 pixel is 0.13 mm).
const int dpi = 200;

/// The limits of one schema box: the largest move of an edge of its ink box
/// (mm) and the largest share of its pixels that may differ.
(double, double) _limit(String compare, String type) {
  // other shaping (HarfBuzz here, fontkit in pdfme): marks sit elsewhere
  if (compare == 'lines') return (3, 0.2);
  // pdfme encodes these images again as JPEG
  if (compare == 'reencoded') return (0.3, 0.02);
  // the text under the bars is Helvetica here, OCR-B in pdfme; the bars
  // are checked on their own (see _barDifference)
  if (_linear.contains(type)) return (0.3, 0.08);
  return (0.3, 0.01);
}

/// The limits of one area of `boxes` (see the test): stricter than a
/// schema box, as a table area holds many cells.
(double, double) _areaLimit(String compare) =>
    compare == 'lines' ? (0.3, 0.05) : (0.3, 0.005);

/// The linear barcode types.
final Set<String> _linear = barcodeTypes.toSet().difference(<String>{
  'qrcode',
  'gs1datamatrix',
  'pdf417',
});

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
    StringBuffer report = StringBuffer();
    for (Map<String, dynamic> c in cases) {
      String name = c['name'] as String;
      String compare = c['compare'] as String;
      Uint8List bytes = await generateJson(
        template: _resolve(c['template']) as Map<String, dynamic>,
        inputs: <Map<String, dynamic>>[
          for (Object? i in _resolve(c['inputs']) as List<dynamic>)
            i! as Map<String, dynamic>,
        ],
        options: _resolve(
          c['options'] ?? <String, dynamic>{},
        ) as Map<String, dynamic>,
        plugins: builtInPlugins,
      );
      File('$outDir/dox/$name.pdf').writeAsBytesSync(bytes);
      List<Ppm> ours = renderPages(
        '$outDir/dox/$name.pdf',
        '$outDir/png/$name/dox',
        dpi: dpi,
      );
      List<Ppm> theirs = renderPages(
        '$outDir/pdfme/$name.pdf',
        '$outDir/png/$name/pdfme',
        dpi: dpi,
      );
      if (ours.length != theirs.length) {
        failures.add('$name: ${ours.length} pages, pdfme ${theirs.length}');
        continue;
      }
      List<List<Map<String, dynamic>>> pageSchemas = _pageSchemas(c);
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
        // the whole page too, for marks outside the boxes
        double page = pixelDifference(a, b);
        report.writeln('$name p$p: ${(page * 100).toStringAsFixed(2)} %');
        double pageLimit = switch (compare) {
          'lines' => 0.1,
          'barcode' => 0.03,
          _ => 0.01,
        };
        if (page > pageLimit) {
          failures.add(
            '$name page $p: ${(page * 100).toStringAsFixed(2)} % '
            'of the pixels differ',
          );
        }
        for (Map<String, dynamic> s in pageSchemas[p % pageSchemas.length]) {
          String type = s['type'] as String;
          FieldDiff d = fieldDifference(a, b, s, dpi);
          (double, double) limit = _limit(compare, type);
          String row =
              '$name p$p ${s['name']} ($type): '
              'ink ${d.ink.toStringAsFixed(2)} mm, '
              'pixels ${(d.pixels * 100).toStringAsFixed(2)} % '
              '${d.inkA?.map(_mm).toList()} pdfme ${d.inkB?.map(_mm).toList()}';
          report.writeln(row);
          if (d.ink > limit.$1 || d.pixels > limit.$2) {
            failures.add('$row (limit ${limit.$1} mm, ${limit.$2 * 100} %)');
          }
          (String, bool)? bars = _barDifference(a, b, s, type);
          if (bars != null) {
            report.writeln('$name p$p ${s['name']} ($type): ${bars.$1}');
            if (!bars.$2) failures.add('$name p$p ${s['name']}: ${bars.$1}');
          }
        }
        // Areas of a case (`boxes`, per page, mm), for schemas that move:
        // a table grows and goes on over pages, so its template box is
        // not where it is drawn. The whole page is one area too, so a
        // page break at another row moves its ink box.
        List<dynamic> boxes = c['boxes'] as List<dynamic>? ?? <dynamic>[];
        if (c.containsKey('boxes')) {
          for (Object? area in <Object?>[
            <String, dynamic>{
              'name': 'page',
              'position': <String, dynamic>{'x': 0, 'y': 0},
              'width': a.width / (dpi / 25.4),
              'height': a.height / (dpi / 25.4),
            },
            if (p < boxes.length) ...boxes[p] as List<dynamic>,
          ]) {
            Map<String, dynamic> m = area! as Map<String, dynamic>;
            Map<String, dynamic> box = <String, dynamic>{
              ...m,
              'position':
                  m['position'] ?? <String, dynamic>{'x': m['x'], 'y': m['y']},
            };
            FieldDiff d = fieldDifference(a, b, box, dpi, margin: 0);
            (double, double) limit = _areaLimit(compare);
            String row =
                '$name p$p area ${_mm((box['position'] as Map<String, dynamic>)['x'] as num)},'
                '${_mm((box['position'] as Map<String, dynamic>)['y'] as num)}: '
                'ink ${d.ink.toStringAsFixed(2)} mm, '
                'pixels ${(d.pixels * 100).toStringAsFixed(3)} %';
            report.writeln(row);
            if (d.ink > limit.$1 || d.pixels > limit.$2) {
              failures.add('$row (limit ${limit.$1} mm, ${limit.$2 * 100} %)');
            }
          }
        }
      }
      if (compare == 'lines') {
        List<dynamic> schemas =
            ((c['template'] as Map<String, dynamic>)['schemas']
                    as List<dynamic>)[0]
                as List<dynamic>;
        Map<String, String> a = _lines('$outDir/dox/$name.pdf', schemas);
        Map<String, String> b = _lines('$outDir/pdfme/$name.pdf', schemas);
        printOnFailure('$name lines: $a\npdfme: $b');
        if (a.toString() != b.toString()) {
          failures.add('$name: the lines differ from pdfme');
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
        // the exact text must come back
        for (Object? text in c['decoded'] as List<dynamic>? ?? <dynamic>[]) {
          if (!a.contains(text)) failures.add('$name: $text not decoded: $a');
        }
      }
    }
    File('$outDir/report.txt').writeAsStringSync(report.toString());
    expect(failures, isEmpty);
  }, skip: ready ? false : 'needs npm ci in tool/crosscheck and pdftoppm');
}

/// The text lines of [pdf] from `pdftotext -bbox`. The key is the schema
/// box the line starts in (by [schemas] of the first page) and the top of
/// the line. The value is the sorted base letters of Thai, Lao, Khmer and
/// Myanmar on that line. Only the base letters are compared: the vowels and
/// marks come out in another order (or split) from a pdfme file, because
/// pdfme writes no `/ActualText`.
Map<String, String> _lines(String pdf, List<dynamic> schemas) {
  ProcessResult r = Process.runSync('pdftotext', <String>['-bbox', pdf, '-']);
  if (r.exitCode != 0) throw StateError('pdftotext: ${r.stderr}');
  RegExp word = RegExp(
    r'<word xMin="([\d.]+)" yMin="([\d.]+)"[^>]*>([^<]*)</word>',
  );
  const double mm = 72 / 25.4;
  Map<String, List<int>> lines = <String, List<int>>{};
  for (RegExpMatch m in word.allMatches(r.stdout as String)) {
    double x = double.parse(m[1]!) / mm;
    double y = double.parse(m[2]!) / mm;
    // the box that holds the word start; the lowest one when boxes share
    // a column (text can overflow the box above)
    int box = -1;
    num top = -1;
    for (int i = 0; i < schemas.length; i++) {
      Map<String, dynamic> s = schemas[i] as Map<String, dynamic>;
      Map<String, dynamic> p = s['position'] as Map<String, dynamic>;
      num left = p['x'] as num;
      num boxTop = p['y'] as num;
      if (x >= left - 0.5 &&
          x < left + (s['width'] as num) &&
          y >= boxTop - 2 &&
          boxTop > top) {
        box = i;
        top = boxTop;
      }
    }
    String key = '$box@${y.toStringAsFixed(1)}';
    lines
        .putIfAbsent(key, () => <int>[])
        .addAll(m[3]!.runes.where(_isBaseLetter));
  }
  return <String, String>{
    for (String key in lines.keys.toList()..sort())
      key: String.fromCharCodes(lines[key]!..sort()),
  };
}

bool _isBaseLetter(int c) =>
    (c >= 0x0e01 && c <= 0x0e2e) ||
    (c >= 0x0e81 && c <= 0x0eae) ||
    (c >= 0x0edc && c <= 0x0edf) ||
    (c >= 0x1000 && c <= 0x102a) ||
    (c >= 0x1780 && c <= 0x17b3);

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

String _mm(num v) => v.toStringAsFixed(2);

/// The schemas of each page of the template of case [c]: the schemas of
/// the page and the static schemas of a blank base PDF.
List<List<Map<String, dynamic>>> _pageSchemas(Map<String, dynamic> c) {
  Map<String, dynamic> template = c['template'] as Map<String, dynamic>;
  Object? base = template['basePdf'];
  List<dynamic> statics = base is Map && base['staticSchema'] is List
      ? base['staticSchema'] as List<dynamic>
      : const <dynamic>[];
  return <List<Map<String, dynamic>>>[
    for (Object? page in template['schemas'] as List<dynamic>)
      <Map<String, dynamic>>[
        for (Object? s in <Object?>[
          ...(page is Map ? page.values : page! as List<dynamic>),
          ...statics,
        ])
          s! as Map<String, dynamic>,
      ],
  ];
}

/// Compares the bars of a linear barcode box on a line across the bars:
/// every edge must be at the same place (vector bars here, an SVG in
/// pdfme). Null for other types; else what was found, and true when it
/// matches.
(String, bool)? _barDifference(
  Ppm a,
  Ppm b,
  Map<String, dynamic> s,
  String type,
) {
  if (!_linear.contains(type)) return null;
  // Japan Post: the middle line crosses every bar
  double v = type == 'japanpost' ? 0.5 : 0.2;
  List<double> x = scanEdges(a, s, dpi, v);
  List<double> y = scanEdges(b, s, dpi, v);
  double e = edgeDifference(x, y);
  return (
    'bars: ${x.length} edges, pdfme ${y.length}, '
        'moved up to ${e.toStringAsFixed(2)} mm',
    e <= 0.13,
  );
}
