// Crosscheck of single fields with the real pdfme. The cases with
// `fields: true` (tool/crosscheck/field_cases.mjs) are drawn by pdfme and by
// dox_pdf_me, and each schema is compared on its own:
//
// - the pixels in the schema box (turned with the schema, plus 1 mm), and
// - the box of the ink (all pixels that are not white) in that area: its
//   place and size must be the same.
//
// A page-wide limit can hide a wrong field, so the limits here are per
// field. Needs `npm ci` in tool/crosscheck and pdftoppm, like
// crosscheck_test.dart. The numbers of each field are written to
// .dart_tool/field_crosscheck/report.txt.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';
import 'package:test/test.dart';

import 'support.dart';

const String outDir = '.dart_tool/field_crosscheck';
const String fixtureDir = 'test/fixtures/crosscheck';
const List<String> caseNames = <String>[
  'field-signature',
  'field-circle-mark',
  'field-mvt',
];

/// Render resolution of the pages.
const int dpi = 150;

/// The largest share of differing pixels in one field box.
const double pixelLimit = 0.005;

/// The largest move of one edge of the ink box, in mm.
const double inkLimitMm = 0.2;

void main() {
  bool ready = hasPdfme && hasTool('pdftoppm');

  test('every field looks like pdfme', () async {
    if (!await fetchTestFonts()) fail('can not download the test fonts');
    Directory(outDir).createSync(recursive: true);
    Directory('$outDir/pdfme').createSync(recursive: true);
    Directory('$outDir/dox').createSync(recursive: true);
    ProcessResult r = Process.runSync(
      'node',
      <String>[
        '$crosscheckDir/render.mjs',
        '$outDir/pdfme',
        fixtureDir,
        testFontDir,
      ],
      environment: <String, String>{'CROSSCHECK_ONLY': caseNames.join(',')},
    );
    if (r.exitCode != 0) fail('render.mjs failed: ${r.stderr}');
    List<dynamic> all = jsonDecode(
      File('$outDir/pdfme/cases.json').readAsStringSync(),
    ) as List<dynamic>;
    List<String> failures = <String>[];
    StringBuffer report = StringBuffer();
    for (Object? item in all) {
      Map<String, dynamic> c = item! as Map<String, dynamic>;
      String name = c['name'] as String;
      if (!caseNames.contains(name)) continue;
      expect(c['fields'], isTrue);
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
      _cleanDir('$outDir/png/$name');
      Ppm ours = renderPages(
        '$outDir/dox/$name.pdf',
        '$outDir/png/$name/dox',
        dpi: dpi,
      ).single;
      Ppm theirs = renderPages(
        '$outDir/pdfme/$name.pdf',
        '$outDir/png/$name/pdfme',
        dpi: dpi,
      ).single;
      List<dynamic> schemas =
          ((c['template'] as Map<String, dynamic>)['schemas'] as List<dynamic>)
                  .first
              as List<dynamic>;
      for (Object? s in schemas) {
        FieldResult f = FieldResult.compare(
          ours,
          theirs,
          s! as Map<String, dynamic>,
        );
        report.writeln('$name ${f.describe()}');
        String? problem = f.problem();
        if (problem != null) failures.add('$name ${f.field}: $problem');
      }
    }
    File('$outDir/report.txt').writeAsStringSync(report.toString());
    printOnFailure(report.toString());
    expect(failures, isEmpty);
  }, skip: ready ? false : 'needs npm ci in tool/crosscheck and pdftoppm');
}

/// The result of one field: pixel difference and ink boxes.
class FieldResult {
  FieldResult(this.field, this.pixels, this.ours, this.theirs);

  /// Compares the area of [schema] in [a] (ours) and [b] (pdfme).
  factory FieldResult.compare(Ppm a, Ppm b, Map<String, dynamic> schema) {
    Rect area = Rect.ofSchema(schema).grow(1).clamp(a.width, a.height);
    int differ = 0;
    int total = 0;
    for (int y = area.top; y < area.bottom; y++) {
      for (int x = area.left; x < area.right; x++) {
        total++;
        if (_differs(a, b, x, y)) differ++;
      }
    }
    return FieldResult(
      schema['name'] as String,
      total == 0 ? 0 : differ / total,
      Rect.ink(a, area),
      Rect.ink(b, area),
    );
  }

  final String field;
  final double pixels;
  final Rect? ours;
  final Rect? theirs;

  /// The largest edge move of the ink box, in mm (0 when both are empty).
  double get inkDeltaMm {
    Rect? a = ours;
    Rect? b = theirs;
    if (a == null || b == null) return a == b ? 0 : double.infinity;
    return <int>[
          (a.left - b.left).abs(),
          (a.top - b.top).abs(),
          (a.right - b.right).abs(),
          (a.bottom - b.bottom).abs(),
        ].reduce(math.max) *
        25.4 /
        dpi;
  }

  String? problem() {
    if ((ours == null) != (theirs == null)) {
      return ours == null
          ? 'empty, pdfme draws $theirs'
          : 'pdfme draws nothing';
    }
    if (pixels > pixelLimit) {
      return '${(pixels * 100).toStringAsFixed(3)} % of the pixels differ';
    }
    if (inkDeltaMm > inkLimitMm) {
      return 'ink box $ours, pdfme $theirs '
          '(${inkDeltaMm.toStringAsFixed(2)} mm)';
    }
    return null;
  }

  String describe() =>
      '$field: pixels ${(pixels * 100).toStringAsFixed(3)} %, ink '
      '${ours == null ? 'none' : '$ours'} / '
      '${theirs == null ? 'none' : '$theirs'}, '
      'delta ${inkDeltaMm.toStringAsFixed(3)} mm';
}

/// A pixel box: [left], [top] in, [right], [bottom] out.
class Rect {
  const Rect(this.left, this.top, this.right, this.bottom);

  /// The page area of a schema, turned around its center, in pixels.
  factory Rect.ofSchema(Map<String, dynamic> s) {
    Map<String, dynamic> p = s['position'] as Map<String, dynamic>;
    double x = (p['x'] as num).toDouble();
    double y = (p['y'] as num).toDouble();
    double w = (s['width'] as num).toDouble();
    double h = (s['height'] as num).toDouble();
    double angle = ((s['rotate'] as num?) ?? 0) * math.pi / 180;
    double bw = (w * math.cos(angle)).abs() + (h * math.sin(angle)).abs();
    double bh = (w * math.sin(angle)).abs() + (h * math.cos(angle)).abs();
    double cx = x + w / 2;
    double cy = y + h / 2;
    return Rect(
      _px(cx - bw / 2).floor(),
      _px(cy - bh / 2).floor(),
      _px(cx + bw / 2).ceil(),
      _px(cy + bh / 2).ceil(),
    );
  }

  /// The box of the pixels in [area] of [image] that are not white, or
  /// null when there are none.
  static Rect? ink(Ppm image, Rect area) {
    int left = area.right;
    int top = area.bottom;
    int right = area.left;
    int bottom = area.top;
    for (int y = area.top; y < area.bottom; y++) {
      for (int x = area.left; x < area.right; x++) {
        if (!_ink(image, x, y)) continue;
        left = math.min(left, x);
        top = math.min(top, y);
        right = math.max(right, x + 1);
        bottom = math.max(bottom, y + 1);
      }
    }
    return right <= left ? null : Rect(left, top, right, bottom);
  }

  final int left;
  final int top;
  final int right;
  final int bottom;

  /// [mm] more on each side.
  Rect grow(double mm) {
    int d = _px(mm).ceil();
    return Rect(left - d, top - d, right + d, bottom + d);
  }

  Rect clamp(int width, int height) => Rect(
    math.max(0, left),
    math.max(0, top),
    math.min(width, right),
    math.min(height, bottom),
  );

  @override
  String toString() {
    String mm(int v) => (v * 25.4 / dpi).toStringAsFixed(2);
    return '[${mm(left)},${mm(top)} ${mm(right - left)}x${mm(bottom - top)}]';
  }
}

double _px(double mm) => mm * dpi / 25.4;

bool _ink(Ppm image, int x, int y) {
  int i = (y * image.width + x) * 3;
  Uint8List p = image.pixels;
  return p[i] < 207 || p[i + 1] < 207 || p[i + 2] < 207;
}

bool _differs(Ppm a, Ppm b, int x, int y) {
  int i = (y * a.width + x) * 3;
  for (int c = 0; c < 3; c++) {
    if ((a.pixels[i + c] - b.pixels[i + c]).abs() > 48) return true;
  }
  return false;
}

void _cleanDir(String path) {
  Directory d = Directory(path);
  if (d.existsSync()) d.deleteSync(recursive: true);
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
