// Crosscheck of the table cases (tool/crosscheck/table_cases.mjs) with the
// real pdfme, at 144 dpi. Besides the whole pages, it compares each area of
// `boxes` alone: the share of pixels that differ, and the box around the
// ink. A whole page is mostly white, so a page limit can hide a shifted
// row; an area limit and the ink box do not.
//
// Needs `npm ci` in tool/crosscheck and pdftoppm, like crosscheck_test.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';
import 'package:test/test.dart';

import 'support.dart';

const String outDir = '.dart_tool/crosscheck_table';
const int dpi = 144;
const double pxPerMm = dpi / 25.4;

/// The largest share of differing pixels of a page or an area.
const Map<String, double> areaLimit = <String, double>{
  'pixels': 0.005,
  'lines': 0.05,
};

/// The largest move of an edge of the ink box, in mm.
const double inkLimit = 0.3;

void main() {
  bool ready = hasPdfme && hasTool('pdftoppm');
  List<Map<String, dynamic>> cases = <Map<String, dynamic>>[];

  setUpAll(() async {
    if (!ready) return;
    if (!await fetchTestFonts()) fail('can not download the test fonts');
    Directory out = Directory(outDir);
    if (out.existsSync()) out.deleteSync(recursive: true);
    Directory('$outDir/pdfme').createSync(recursive: true);
    Directory('$outDir/dox').createSync(recursive: true);
    ProcessResult r = Process.runSync(
      'node',
      <String>[
        '$crosscheckDir/render.mjs',
        '$outDir/pdfme',
        'test/fixtures/crosscheck',
        testFontDir,
      ],
      environment: <String, String>{'ONLY': 'table-'},
    );
    if (r.exitCode != 0) fail('render.mjs failed: ${r.stderr}');
    cases = <Map<String, dynamic>>[
      for (Object? c in jsonDecode(
        File('$outDir/pdfme/cases.json').readAsStringSync(),
      ) as List<dynamic>)
        c! as Map<String, dynamic>,
    ];
  });

  test('every table case looks like pdfme, area by area', () async {
    expect(cases, isNotEmpty);
    List<String> failures = <String>[];
    for (Map<String, dynamic> c in cases) {
      String name = c['name'] as String;
      double limit = areaLimit[c['compare']] ?? 0.005;
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
      List<dynamic> boxes = c['boxes'] as List<dynamic>? ?? <dynamic>[];
      for (int p = 0; p < ours.length; p++) {
        Ppm a = ours[p];
        Ppm b = theirs[p];
        // the whole page is always one area too (it catches a page break
        // at another row)
        List<dynamic> areas = <dynamic>[
          <String, dynamic>{
            'x': 0,
            'y': 0,
            'width': a.width / pxPerMm,
            'height': a.height / pxPerMm,
          },
          if (p < boxes.length) ...boxes[p] as List<dynamic>,
        ];
        for (Object? area in areas) {
          Map<String, dynamic> m = area! as Map<String, dynamic>;
          _Rect r = _Rect.mm(m, a.width, a.height);
          double diff = _areaDifference(a, b, r);
          _Rect? inkA = _ink(a, r);
          _Rect? inkB = _ink(b, r);
          double shift = _shift(inkA, inkB);
          String label = '$name page $p area ${_num(m['x'])},${_num(m['y'])}';
          print(
            '$label: ${_pct(diff)}, ink edges ${shift.toStringAsFixed(3)} mm',
          );
          if (diff > limit) failures.add('$label: ${_pct(diff)} differ');
          if (shift > inkLimit) {
            failures.add(
              '$label: ink box moved ${shift.toStringAsFixed(2)} mm',
            );
          }
        }
      }
    }
    expect(failures, isEmpty);
  }, skip: ready ? false : 'needs npm ci in tool/crosscheck and pdftoppm');
}

String _num(Object? v) => (v! as num).toStringAsFixed(0);

String _pct(double v) => '${(v * 100).toStringAsFixed(3)} %';

class _Rect {
  _Rect(this.left, this.top, this.right, this.bottom);

  factory _Rect.mm(Map<String, dynamic> m, int width, int height) {
    int px(Object? v) => ((v! as num) * pxPerMm).round();
    int x = px(m['x']);
    int y = px(m['y']);
    return _Rect(
      math.max(0, x),
      math.max(0, y),
      math.min(width, x + px(m['width'])),
      math.min(height, y + px(m['height'])),
    );
  }

  final int left;
  final int top;
  final int right;
  final int bottom;
}

double _areaDifference(Ppm a, Ppm b, _Rect r, {int threshold = 48}) {
  int differ = 0;
  for (int y = r.top; y < r.bottom; y++) {
    for (int x = r.left; x < r.right; x++) {
      int i = (y * a.width + x) * 3;
      for (int c = 0; c < 3; c++) {
        if ((a.pixels[i + c] - b.pixels[i + c]).abs() > threshold) {
          differ++;
          break;
        }
      }
    }
  }
  return differ / ((r.right - r.left) * (r.bottom - r.top));
}

/// The box around the pixels in [r] that are not (nearly) white.
_Rect? _ink(Ppm img, _Rect r) {
  int left = r.right;
  int top = r.bottom;
  int right = r.left - 1;
  int bottom = r.top - 1;
  for (int y = r.top; y < r.bottom; y++) {
    for (int x = r.left; x < r.right; x++) {
      int i = (y * img.width + x) * 3;
      if (img.pixels[i] < 235 ||
          img.pixels[i + 1] < 235 ||
          img.pixels[i + 2] < 235) {
        left = math.min(left, x);
        right = math.max(right, x);
        top = math.min(top, y);
        bottom = math.max(bottom, y);
      }
    }
  }
  return right < left ? null : _Rect(left, top, right, bottom);
}

/// The largest move of one edge between the ink boxes, in mm.
double _shift(_Rect? a, _Rect? b) {
  if (a == null || b == null) return a == b ? 0 : double.infinity;
  int px = <int>[
    (a.left - b.left).abs(),
    (a.top - b.top).abs(),
    (a.right - b.right).abs(),
    (a.bottom - b.bottom).abs(),
  ].reduce(math.max);
  return px / pxPerMm;
}

Object? _resolve(Object? value) {
  if (value is List) return <Object?>[for (Object? v in value) _resolve(v)];
  if (value is! Map) return value;
  if (value.containsKey(r'$file')) {
    String name = value[r'$file'] as String;
    File file = File('test/fixtures/crosscheck/$name');
    if (!file.existsSync()) file = File('$testFontDir/$name');
    return '${value['prefix'] ?? ''}${base64.encode(file.readAsBytesSync())}';
  }
  if (value.containsKey(r'$default')) return FontStore.defaultFont.data;
  return <String, dynamic>{
    for (MapEntry<dynamic, dynamic> e in value.entries)
      '${e.key}': _resolve(e.value),
  };
}
