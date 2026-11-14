// A text schema sets the character spacing (`Tc`) like pdfme. It must not
// change text drawn after it on the same page: the barcode text and SVG
// `<text>` use drawText too.
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';
import 'package:test/test.dart';

import 'support.dart';

const String _dir = '.dart_tool/tc_leak_test';

Map<String, dynamic> _box(String name, String type, double y, double h) =>
    <String, dynamic>{
      'name': name,
      'type': type,
      'position': <String, num>{'x': 10, 'y': y},
      'width': 60,
      'height': h,
    };

Future<Ppm> _render(bool withText) async {
  List<Map<String, dynamic>> schemas = <Map<String, dynamic>>[
    if (withText)
      <String, dynamic>{..._box('t', 'text', 5, 10), 'characterSpacing': 5},
    _box('code', 'ean13', 30, 20),
    _box('pic', 'svg', 60, 20),
  ];
  Uint8List bytes = await generate(
    template: <String, dynamic>{
      'basePdf': <String, dynamic>{
        'width': 80,
        'height': 90,
        'padding': <int>[0, 0, 0, 0],
      },
      'schemas': <List<Map<String, dynamic>>>[schemas],
    },
    inputs: <Map<String, dynamic>>[
      <String, dynamic>{
        't': 'Wide text',
        'code': '2112345678900',
        'pic':
            '<svg xmlns="http://www.w3.org/2000/svg" width="60" height="20">'
            '<text x="2" y="14" font-size="10">SVG text 123</text></svg>',
      },
    ],
    plugins: builtInPlugins,
  );
  String name = withText ? 'with' : 'without';
  File('$_dir/$name.pdf')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  return renderPages('$_dir/$name.pdf', '$_dir/$name', dpi: 100).single;
}

void main() {
  test('text with character spacing does not change later text', () async {
    Ppm a = await _render(true);
    Ppm b = await _render(false);
    // compare below the text box (y > 20 mm): the barcode and the SVG
    int from = (20 / 25.4 * 100).round();
    int differ = 0;
    for (int y = from; y < a.height; y++) {
      for (int x = 0; x < a.width; x++) {
        if (a.dark(x, y) != b.dark(x, y)) differ++;
      }
    }
    expect(differ, 0);
  }, skip: hasTool('pdftoppm') ? false : 'needs pdftoppm');
}
