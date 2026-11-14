import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:dox_pdf_me/src/barcodes/barcode_fit_layout.dart';
import 'package:dox_pdf_me/src/barcodes/barcode_painter.dart';
import 'package:dox_pdf_me/src/barcodes/barcode_plugin.dart';
import 'package:dox_pdf_me/src/barcodes/barcode_symbol.dart';
import 'package:dox_pdf_me/src/barcodes/code128_encoder.dart';
import 'package:dox_pdf_me/src/barcodes/japan_post.dart';
import 'package:dox_pdf_me/src/barcodes/linear_symbols.dart';
import 'package:dox_pdf_me/src/barcodes/matrix_symbols.dart';
import 'package:dox_pdf_me/src/fonts/font_store.dart';
import 'package:dox_pdf_me/src/options.dart';
import 'package:dox_pdf_me/src/plugin.dart';
import 'package:dox_pdf_me/src/schema.dart';
import 'package:test/test.dart';

void _valid(String type, List<String> good, List<String> bad) {
  for (String v in good) {
    expect(validateBarcodeInput(type, v), isTrue, reason: '$type "$v"');
  }
  for (String v in <String>[...bad, '']) {
    expect(validateBarcodeInput(type, v), isFalse, reason: '$type "$v"');
  }
}

/// The bwip-js 4.11.4 golden geometry (made once with node from the
/// pdfme bwip-js call: width 200 mm, height 16 mm, scale 5).
List<Map<String, dynamic>> _goldens() => (jsonDecode(
  File('test/fixtures/barcodes/bwip_linear.json').readAsStringSync(),
) as List<dynamic>).cast<Map<String, dynamic>>();

/// `start,length,y0,y1;...` of a golden.
List<List<double>> _bars(Map<String, dynamic> g) => <List<double>>[
  for (String b in (g['bars'] as String).split(';'))
    b.split(',').map(double.parse).toList(),
];

void main() {
  group('validateBarcodeInput (pdfme barcode.test.ts)', () {
    test('qrcode', () {
      _valid(
        'qrcode',
        <String>['https://www.google.com/', '漢字を含む文字列', 'x' * 499],
        <String>['x' * 500],
      );
    });
    test('japanpost', () {
      _valid(
        'japanpost',
        <String>['10000131-3-2-503', '10000131-3-2-B503'],
        <String>['invalid', '10000131=3=2-503', '10000131-3-2-b503'],
      );
    });
    test('ean13', () {
      _valid(
        'ean13',
        <String>[
          '111111111111',
          '1111111111116',
          '2822224229221',
          '3433333133331',
          '8434244447413',
        ],
        <String>[
          '111',
          '111111111111111111111111',
          'invalid',
          '11111a111111',
          '1111111111111',
        ],
      );
    });
    test('ean8', () {
      _valid(
        'ean8',
        <String>['1111111', '11111115', '22222220', '33333335', '44444440'],
        <String>[
          '111',
          '11111111111111111111',
          'invalid',
          '111a111',
          '44444441',
        ],
      );
    });
    test('code39', () {
      _valid(
        'code39',
        <String>['12345', 'ABCDE', '1A2B3C4D5G', '1-A \$2/B+3%C4D5G'],
        <String>['123a45', '1-A\$2/B+3%C4=D5G'],
      );
    });
    test('code128', () {
      _valid(
        'code128',
        <String>['12345', '1-A\$2/B+3%C4=D5G', '1-A\$2/B+3%C4=D5Ga~'],
        <String>[
          '1-A\$2/B+3%C4=D5Gひらがな',
          '1-A\$2/B+3%C4=D5G〜',
          '1ーA\$2・B＋3%C4=D5G〜',
        ],
      );
    });
    test('nw7', () {
      _valid(
        'nw7',
        <String>['A12345D', 'A\$2/+345D', 'a4321D'],
        <String>['A12345G', 'A12a45D'],
      );
    });
    test('itf14', () {
      _valid(
        'itf14',
        <String>['1111111111111', '11111111111113', '22222222222226'],
        <String>['111', 'invalid', '11111111111111'],
      );
    });
    test('upca', () {
      _valid(
        'upca',
        <String>['11111111111', '111111111117', '222222222224'],
        <String>['111', 'invalid', '111111111111'],
      );
    });
    test('upce', () {
      _valid(
        'upce',
        <String>['0111111', '01111118', '02222226'],
        <String>['111', 'invalid', '11111118', '01111111'],
      );
    });
    test('gs1datamatrix', () {
      _valid(
        'gs1datamatrix',
        <String>[
          '(01)12345678901231',
          '(01)03453120000011(17)191125(10)ABCD1234',
          '(01)12345670',
        ],
        <String>[
          '(01)12345678901234',
          '(02)12345678901231',
          '(01)123',
          '(01)12345678901231(10)${'A' * 40}',
        ],
      );
    });
    test('pdf417', () {
      _valid('pdf417', <String>['x', 'x' * 1000], <String>['x' * 1001]);
    });
    test('unknown type', () {
      expect(validateBarcodeInput('aztec', 'x'), isFalse);
      expect(barcodeTypes, hasLength(12));
    });
  });

  group('getBarcodeFitLayout (pdfme barcode.test.ts)', () {
    test('a box at the natural ratio comes back unchanged', () {
      for (double box in <double>[30, 15, 33.33, 47.1]) {
        expect(
          getBarcodeFitLayout(
            boxWidth: box,
            boxHeight: box,
            naturalWidth: 1,
            naturalHeight: 1,
          ),
          BarcodeFitLayout(width: box, height: box, offsetX: 0, offsetY: 0),
        );
      }
    });
    test('letterboxes a natural size', () {
      expect(
        getBarcodeFitLayout(
          boxWidth: 60,
          boxHeight: 30,
          naturalWidth: 250,
          naturalHeight: 250,
        ),
        const BarcodeFitLayout(width: 30, height: 30, offsetX: 15, offsetY: 0),
      );
      expect(
        getBarcodeFitLayout(
          boxWidth: 30,
          boxHeight: 60,
          naturalWidth: 250,
          naturalHeight: 250,
        ),
        const BarcodeFitLayout(width: 30, height: 30, offsetX: 0, offsetY: 15),
      );
      BarcodeFitLayout wide = getBarcodeFitLayout(
        boxWidth: 40,
        boxHeight: 20,
        naturalWidth: 1101,
        naturalHeight: 104,
      );
      expect(wide.width, closeTo(40, 1e-9));
      expect(wide.height, closeTo(104 * 40 / 1101, 1e-9));
      expect(wide.offsetX, closeTo(0, 1e-9));
      expect(wide.offsetY, closeTo((20 - wide.height) / 2, 1e-9));
    });
    test('falls back to the box', () {
      expect(
        getBarcodeFitLayout(boxWidth: 40, boxHeight: 20),
        const BarcodeFitLayout(width: 40, height: 20, offsetX: 0, offsetY: 0),
      );
    });
  });

  group('linear bars match bwip-js', () {
    for (Map<String, dynamic> g in _goldens()) {
      String type = g['type'] as String;
      String text = g['value'] as String;
      bool withText = g['includetext'] as bool;
      double w = (g['width'] as num).toDouble();
      double h = (g['height'] as num).toDouble();
      test('$type "$text" $w x $h text: $withText', () {
        BarcodeSymbol s = LinearSymbolBuilder.build(
          type,
          text,
          widthMm: w,
          heightMm: h,
          includeText: withText,
        )!;
        _compareBars(s, g, type);
        _compareText(s, g);
      });
    }
  });

  group('japanpost', () {
    test('67 bars, check character like BWIPP', () {
      List<JapanPostBar> bars = JapanPostEncoder.encode('6540123789-A-K-Z')!;
      expect(bars, hasLength(67));
      // start "31" and stop "13"
      expect(bars.take(2), <JapanPostBar>[
        JapanPostBar.full,
        JapanPostBar.descender,
      ]);
      expect(bars.skip(65), <JapanPostBar>[
        JapanPostBar.descender,
        JapanPostBar.full,
      ]);
    });
    test('every bar is the same as bwip-js (20 inputs)', () {
      // made with bwip-js 4.11.4: one letter per bar, F full, A ascender,
      // D descender, T tracker, - the empty bar of check character 19
      Map<String, dynamic> golden = jsonDecode(
        File('test/fixtures/barcodes/japanpost_bwip.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(golden, hasLength(20));
      const Map<JapanPostBar, String> letters = <JapanPostBar, String>{
        JapanPostBar.full: 'F',
        JapanPostBar.ascender: 'A',
        JapanPostBar.descender: 'D',
        JapanPostBar.tracker: 'T',
        JapanPostBar.none: '-',
      };
      golden.forEach((String input, dynamic expected) {
        List<JapanPostBar> bars = JapanPostEncoder.encode(input)!;
        expect(
          bars.map((JapanPostBar b) => letters[b]).join(),
          expected,
          reason: input,
        );
      });
    });

    test('too long input gives null (BWIPP fails)', () {
      expect(JapanPostEncoder.encode('1000013${'A' * 8}'), isNull);
      expect(JapanPostEncoder.encode('1000013${'1' * 13}'), isNotNull);
      expect(JapanPostEncoder.encode('1000013${'1' * 14}'), isNull);
    });
  });

  group('2D symbols like bwip-js', () {
    test('qrcode: version by data with level M, no quiet zone', () {
      // bwip-js natural sizes: 210 = 21 modules, 250 = 25 modules
      for ((String, int) c in <(String, int)>[
        ('hello', 21),
        ('https://pdfme.com/', 25),
        ('てすとです', 25),
      ]) {
        MatrixSymbol m = MatrixSymbolBuilder.build('qrcode', c.$1)!;
        expect(m.grid.columns, c.$2, reason: c.$1);
        expect(m.grid.rows, c.$2);
        expect(m.ratio, 1);
        _expectQrFinders(m.grid);
      }
    });
    test('gs1datamatrix: square, finder L and timing edges', () {
      for ((String, int) c in <(String, int)>[
        ('(01)12345678901231', 16),
        ('(01)03453120000011(17)191125(10)ABCD1234', 20),
      ]) {
        MatrixSymbol m = MatrixSymbolBuilder.build('gs1datamatrix', c.$1)!;
        expect(m.grid.columns, c.$2, reason: c.$1);
        expect(m.grid.rows, c.$2);
        _expectDataMatrixFinder(m.grid);
      }
    });
    test('pdf417: every module is the same as bwip-js (20 inputs)', () {
      _expectGolden('pdf417', 'pdf417_bwip.json', 20, rowHeight: 3);
    });
    test('code128: every bar is the same as bwip-js (27 inputs)', () {
      // made with bwip-js 4.11.4 (`bwipjs.raw`): the bar and space widths
      Map<String, dynamic> golden = jsonDecode(
        File('test/fixtures/barcodes/code128_bwip.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(golden, hasLength(27));
      golden.forEach((String input, dynamic widths) {
        expect(Code128Encoder.widths(input)!.join(), widths, reason: input);
      });
    });
    test('gs1datamatrix: every module is the same as bwip-js (26 inputs)', () {
      // C40, Text, X12 and EDIFACT runs and the square size
      _expectGolden('gs1datamatrix', 'gs1datamatrix_bwip.json', 26);
    });
    test('qrcode: every module is the same as bwip-js (28 inputs)', () {
      // segments, version, raised error correction level and mask
      _expectGolden('qrcode', 'qrcode_bwip.json', 28);
    });
    test('pdf417: too much data gives null', () {
      expect(MatrixSymbolBuilder.build('pdf417', '\u0001' * 2000), isNull);
      expect(MatrixSymbolBuilder.build('pdf417', ''), isNull);
    });
    test('gs1datamatrix: element string parsing', () {
      expect(MatrixSymbolBuilder.parseGs1('(01)123(10)AB'), <(String, String)>[
        ('01', '123'),
        ('10', 'AB'),
      ]);
      expect(MatrixSymbolBuilder.parseGs1('x(01)123'), isNull);
    });
    test('pdf417: BWIPP columns and rows, row height 3', () {
      // bwip-js natural viewBox / 5 units: (17 * columns + 69) x rows * 3
      for ((String, int, int) c in <(String, int, int)>[
        ('PDF417 rotated', 103, 9),
        ('Test PDF417 barcode generation', 120, 9),
        ('x' * 300, 188, 24),
      ]) {
        MatrixSymbol m = MatrixSymbolBuilder.build('pdf417', c.$1)!;
        expect(m.grid.columns, c.$2, reason: c.$1.substring(0, 10));
        expect(m.grid.rows, c.$3, reason: c.$1.substring(0, 10));
        expect(m.rowHeight, 3);
        expect(m.ratio, closeTo(c.$2 * 5 / (c.$3 * 15), 1e-9));
        // every row starts with the start pattern 11111111 0 1 0 1 000
        for (int r = 0; r < m.grid.rows; r++) {
          expect(
            <bool>[for (int i = 0; i < 9; i++) m.grid.isDark(i, r)],
            <bool>[true, true, true, true, true, true, true, true, false],
          );
        }
      }
    });
  });

  group('BarcodePainter', () {
    test('rect path is in points, y down from the top', () {
      expect(
        BarcodePainter.rectsPath(
          const <BarcodeRect>[BarcodeRect(1, 0, 2, 10)],
          0.5,
          2,
        ),
        'M0.5 0H1.5V20H0.5Z',
      );
    });
  });

  group('BarcodePlugin renders a PDF', () {
    const Map<String, String> values = <String, String>{
      'qrcode': 'https://pdfme.com/',
      'japanpost': '10000131-3-2-B503',
      'ean13': '1111111111116',
      'ean8': '11111115',
      'code39': 'ABC-123',
      'code128': 'ABC-123',
      'nw7': 'A12345B',
      'itf14': '12345678901231',
      'upca': '123456789012',
      'upce': '01234565',
      'gs1datamatrix': '(01)12345678901231',
      'pdf417': 'Test PDF417 barcode generation',
    };

    Future<Uint8List> render(
      List<(String, String, Map<String, dynamic>)> items, {
      String? colorType,
    }) async {
      PDFDocument doc = await PDFDocument.create();
      PDFPage page = doc.addPage(<double>[595.28, 841.89]);
      Map<Object, Object?> cache = <Object, Object?>{};
      int i = 0;
      for ((String, String, Map<String, dynamic>) item in items) {
        Schema schema = Schema(<String, dynamic>{
          'name': 'b$i',
          'type': item.$1,
          'position': <String, dynamic>{
            'x': 10 + (i % 3) * 65,
            'y': 10 + (i ~/ 3) * 45,
          },
          'width': 55,
          'height': 30,
          ...item.$3,
        });
        i++;
        await BarcodePlugin(item.$1).pdf(
          RenderProps(
            value: item.$2,
            schema: schema,
            basePdf: null,
            doc: doc,
            page: page,
            options: GenerateOptions(colorType: colorType),
            fonts: FontStore(doc, null),
            cache: cache,
          ),
        );
      }
      return doc.save(useObjectStreams: false);
    }

    test('every type, with colors, rotation and opacity', () async {
      Uint8List pdf = await render(<(String, String, Map<String, dynamic>)>[
        for (String t in barcodeTypes)
          (
            t,
            values[t]!,
            <String, dynamic>{
              'backgroundColor': '#ffffff',
              'barColor': '#000000',
              'textColor': '#000000',
            },
          ),
        (
          'qrcode',
          'rotated',
          <String, dynamic>{
            'rotate': 30,
            'opacity': 0.5,
            'barColor': 'ff000080',
          },
        ),
        (
          'ean13',
          '111111111111',
          <String, dynamic>{
            'backgroundColor': '#00ff0080',
            'barColor': '#00f',
            'textColor': '#f00',
            'includetext': false,
          },
        ),
      ]);
      expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
      String? out = Platform.environment['BARCODE_PDF_OUT'];
      if (out != null) File(out).writeAsBytesSync(pdf);
    });

    test('cmyk colors', () async {
      Uint8List pdf = await render(<(String, String, Map<String, dynamic>)>[
        ('code128', 'ABC-123', <String, dynamic>{'barColor': '#ff0000'}),
      ], colorType: 'cmyk');
      expect(_content(pdf), contains('0 1 1 0 K'));
    });

    test('invalid values and unknown types draw nothing', () async {
      Uint8List empty = await render(
        <(String, String, Map<String, dynamic>)>[],
      );
      Uint8List invalid = await render(<(String, String, Map<String, dynamic>)>[
        (
          'ean13',
          '1111111111111',
          <String, dynamic>{'backgroundColor': '#fff'},
        ),
        ('qrcode', '', <String, dynamic>{}),
        ('nw7', 'a4321D', <String, dynamic>{}),
        ('aztec', 'x', <String, dynamic>{}),
      ]);
      expect(invalid.length, empty.length);
    });
  });
}

/// The same SVG geometry as bwip-js, to the unit: viewBox, every bar
/// (x, stroke width, y extent) and the ITF-14 frame.
void _compareBars(BarcodeSymbol s, Map<String, dynamic> g, String type) {
  List<List<double>> golden = _bars(g);
  List<BarcodeRect> bars = s.bars;
  expect(s.border, hasLength(type == 'itf14' ? 4 : 0));
  expect(s.width, g['vw'], reason: 'viewBox width');
  expect(s.height, g['vh'], reason: 'viewBox height');
  expect(bars, hasLength(golden.length));
  for (int i = 0; i < bars.length; i++) {
    BarcodeRect r = bars[i];
    List<double> b = golden[i];
    expect(<double>[r.x, r.width, r.y, r.y + r.height], b, reason: 'bar $i');
  }
  if (type == 'itf14') {
    // `M0 0L0 H L W H L W 0Z M x0 y0 L x1 y0 L x1 y1 L x0 y1 Z`
    List<double> n = RegExp(r'[\d.]+')
        .allMatches(g['frame'] as String)
        .map((RegExpMatch m) => double.parse(m[0]!))
        .toList();
    BarcodeRect top = s.border[0];
    BarcodeRect bottom = s.border[1];
    BarcodeRect left = s.border[2];
    expect(<double>[top.x, top.y, top.x + top.width], <double>[0, 0, n[6]]);
    expect(bottom.y + bottom.height, n[3]);
    expect(
      <double>[left.x + left.width, top.y + top.height],
      <double>[n[8], n[9]],
    );
    expect(<double>[bottom.y, s.border.last.x], <double>[n[13], n[10]]);
  }
}

/// The text sits where the OCR-B text of bwip-js is: same center, about
/// the same width, baseline 38.35 units under the bars or the frame.
void _compareText(BarcodeSymbol s, Map<String, dynamic> g) {
  List<dynamic>? span = g['textSpan'] as List<dynamic>?;
  if (span == null) {
    expect(s.text, isNull);
    return;
  }
  BarcodeTextLine t = s.text!;
  double x0 = (span[0] as num).toDouble(), x1 = (span[1] as num).toDouble();
  expect(t.left + t.width / 2, closeTo((x0 + x1) / 2, s.width * 0.01));
  expect(t.width, closeTo(x1 - x0, (x1 - x0) * 0.08));
  int descent = LinearSymbolBuilder.textDescent(t.text);
  expect(t.baseline, closeTo(s.height - 40 - descent + 38.35, 1e-9));
}

/// The page content stream of a one page PDF saved without object
/// streams.
String _content(Uint8List pdf) {
  String text = latin1.decode(pdf);
  int start = text.indexOf('stream\n', text.indexOf('/FlateDecode')) + 7;
  int end = text.indexOf('endstream', start);
  return latin1.decode(zlib.decode(pdf.sublist(start, end)));
}

void _expectQrFinders(ModuleGrid g) {
  // a 7x7 finder: dark ring, light ring, dark 3x3 center
  for ((int, int) o in <(int, int)>[
    (0, 0),
    (g.columns - 7, 0),
    (0, g.rows - 7),
  ]) {
    for (int i = 0; i < 7; i++) {
      expect(g.isDark(o.$1 + i, o.$2), isTrue);
      expect(g.isDark(o.$1 + i, o.$2 + 6), isTrue);
    }
    expect(g.isDark(o.$1 + 1, o.$2 + 1), isFalse);
    expect(g.isDark(o.$1 + 3, o.$2 + 3), isTrue);
  }
}

void _expectDataMatrixFinder(ModuleGrid g) {
  int last = g.rows - 1;
  for (int i = 0; i < g.columns; i++) {
    expect(g.isDark(0, i), isTrue, reason: 'left edge');
    expect(g.isDark(i, last), isTrue, reason: 'bottom edge');
    expect(g.isDark(i, 0), i.isEven, reason: 'top timing');
    expect(g.isDark(g.columns - 1, i), i.isOdd, reason: 'right timing');
  }
}

/// Compares the 2D symbols of [type] with a bwip-js 4.11.4 golden file
/// (made with `bwipjs.raw`): per symbol row (of [rowHeight] modules), the
/// modules as a hex number (1 is dark).
void _expectGolden(String type, String file, int count, {int rowHeight = 1}) {
  Map<String, dynamic> golden = jsonDecode(
    File('test/fixtures/barcodes/$file').readAsStringSync(),
  ) as Map<String, dynamic>;
  expect(golden, hasLength(count));
  golden.forEach((String input, dynamic g) {
    Map<String, dynamic> want = g as Map<String, dynamic>;
    MatrixSymbol m = MatrixSymbolBuilder.build(type, input)!;
    String name = input.length > 20 ? input.substring(0, 20) : input;
    expect(m.grid.columns, want['width'], reason: name);
    expect(m.rowHeight, rowHeight);
    List<String> rows = <String>[
      for (int r = 0; r < m.grid.rows; r++)
        BigInt.parse(
          <String>[
            for (int x = 0; x < m.grid.columns; x++)
              m.grid.isDark(x, r) ? '1' : '0',
          ].join(),
          radix: 2,
        ).toRadixString(16),
    ];
    expect(rows, want['rows'], reason: name);
  });
}
