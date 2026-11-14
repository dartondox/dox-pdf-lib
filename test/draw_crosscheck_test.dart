// Draws the same scene with dox_pdf_lib and with pdf-lib
// (tool/crosscheck/draw.mjs), then compares:
// - the font metrics, exactly;
// - the rendered pages (pdftoppm from poppler-utils), pixel by pixel with a
//   small tolerance.
// Needs `npm ci` in tool/crosscheck and pdftoppm; skipped without them.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

import 'render_support.dart';

const String _fixtures = 'test/fixtures';

/// Keep in sync with `samples` in draw.mjs.
const Map<String, List<String>> _samples = <String, List<String>>{
  'WinAnsi': <String>['Hello World', 'AVATAR To. Wa', 'Grüße € „Quote“', ''],
  'Symbol': <String>['αβγ ∑∞ ≠'],
  'ZapfDingbats': <String>['✓✈❤ ➔'],
};

List<Map<String, Object?>> _metrics(PDFDocument doc) => <Map<String, Object?>>[
  for (StandardFonts name in StandardFonts.values)
    () {
      PDFFont f = doc.embedStandardFont(name);
      List<String> set =
          _samples[switch (name) {
            StandardFonts.symbol => 'Symbol',
            StandardFonts.zapfDingbats => 'ZapfDingbats',
            _ => 'WinAnsi',
          }]!;
      List<int> cs = f.getCharacterSet();
      return <String, Object?>{
        'name': f.name,
        'widths': <double>[for (String t in set) f.widthOfTextAtSize(t, 12.5)],
        'height': f.heightAtSize(12.5),
        'heightNoDescender': f.heightAtSize(12.5, descender: false),
        'sizeAtHeight': f.sizeAtHeight(20),
        'charset': <int>[cs.length, cs.first, cs.last],
        'encoded': f.encodeText(set.first).toString(),
      };
    }(),
];

/// The scene of draw.mjs.
Future<PDFDocument> _scene() async {
  Uint8List read(String f) => File('$_fixtures/$f').readAsBytesSync();
  PDFDocument doc = await PDFDocument.create();
  _metrics(doc);
  PDFFont times = await doc.embedFont(StandardFonts.timesRomanBold);
  PDFFont courier = await doc.embedFont(StandardFonts.courier);
  PDFFont symbol = await doc.embedFont(StandardFonts.symbol);
  PDFFont zapf = await doc.embedFont(StandardFonts.zapfDingbats);

  PDFPage p1 = doc.addPage(<double>[600, 800]);
  p1.drawText('Hello pdf-lib', x: 50, y: 750);
  p1.drawText(
    'Times bold, rotated',
    x: 50,
    y: 700,
    font: times,
    size: 20,
    color: rgb(0.2, 0.4, 0.6),
    rotate: degrees(10),
  );
  p1.drawText(
    'Courier wraps this long line of text at the max width.\n'
    'A new line, and more words to wrap again here.',
    x: 50,
    y: 640,
    font: courier,
    size: 12,
    lineHeight: 14,
    maxWidth: 220,
  );
  p1.drawText(
    'Skewed, half opacity, multiply',
    x: 320,
    y: 640,
    size: 14,
    opacity: 0.5,
    blendMode: BlendMode.multiply,
    xSkew: degrees(15),
    ySkew: degrees(5),
  );
  p1.drawText(
    'A-B-C-D-E-F-G-H-I-J-K',
    x: 320,
    y: 600,
    size: 14,
    maxWidth: 80,
    wordBreaks: <String>['-'],
    color: cmyk(0.1, 0.8, 0.2, 0.1),
  );
  p1.drawText(_samples['Symbol']![0], x: 320, y: 520, font: symbol, size: 18);
  p1.drawText(
    _samples['ZapfDingbats']![0],
    x: 450,
    y: 520,
    font: zapf,
    size: 18,
    color: grayscale(0.3),
  );
  p1.drawRectangle(
    x: 50,
    y: 400,
    width: 200,
    height: 100,
    color: cmyk(0.5, 0.1, 0, 0.1),
    borderColor: rgb(1, 0, 0),
    borderWidth: 3,
    borderDashArray: <double>[5, 3],
    rotate: degrees(5),
    opacity: 0.7,
    borderOpacity: 0.5,
  );
  p1.drawSquare(x: 300, y: 400, size: 60, color: grayscale(0.5));
  p1.drawRectangle(
    x: 380,
    y: 400,
    width: 50,
    height: 30,
    borderColor: rgb(0, 0.5, 0),
    borderWidth: 2,
    xSkew: degrees(20),
  );
  p1.drawEllipse(
    x: 500,
    y: 450,
    xScale: 60,
    yScale: 30,
    borderColor: rgb(1, 0, 0),
    borderWidth: 2,
    rotate: degrees(20),
  );
  p1.drawCircle(
    x: 500,
    y: 330,
    size: 40,
    color: rgb(0, 0.6, 0),
    borderColor: rgb(0, 0, 0),
    borderWidth: 1,
    opacity: 0.8,
  );
  p1.drawEllipse(
    x: 400,
    y: 330,
    xScale: 30,
    yScale: 50,
    color: rgb(0.9, 0.6, 0),
  );
  p1.drawLine(
    start: (x: 50, y: 360),
    end: (x: 300, y: 330),
    thickness: 4,
    color: rgb(0, 0, 1),
    lineCap: LineCapStyle.round,
    dashArray: <double>[10, 5],
    opacity: 0.6,
  );
  p1.drawLine(start: (x: 50, y: 340), end: (x: 300, y: 310));
  p1.drawSvgPath(
    'M 0,20 L 100,160 Q 130,200 150,120 C 190,-40 200,200 300,150 L 400,90',
    x: 50,
    y: 300,
    scale: 0.5,
    borderColor: rgb(0.5, 0, 0.5),
    borderWidth: 3,
  );
  p1.drawSvgPath(
    'M10 80 C 40 10, 65 10, 95 80 S 150 150, 180 80 Z '
    'm 20 0 a 25 25 0 1 0 50 0 a 25 25 0 0 1 -50 0',
    x: 250,
    y: 300,
    color: rgb(0.2, 0.7, 0.9),
    borderColor: rgb(0, 0, 0),
    borderWidth: 1,
    rotate: degrees(-5),
  );
  p1.drawSvgPath(
    'M10 10 h 80 v 80 h -80 Z M30 30 t 20 10 t 20 -10 T 70 60',
    x: 450,
    y: 250,
    color: rgb(1, 0.8, 0),
  );
  p1.pushOperators(<PDFOperator>[
    pushGraphicsState(),
    setFillingRgbColor(0.9, 0.1, 0.1),
    rectangle(520, 40, 50, 30),
    fill(),
    popGraphicsState(),
  ]);

  PDFPage p2 = doc.addPage(<double>[600, 800]);
  List<PDFImage> images = <PDFImage>[
    for (String f in <String>['rgb.jpg', 'gray.jpg', 'cmyk.jpg'])
      await doc.embedJpg(read(f)),
    for (String f in <String>[
      'rgba-interlaced.png',
      'rgb16.png',
      'gray16.png',
      'gray1.png',
      'palette-trns.png',
    ])
      await doc.embedPng(read(f)),
  ];
  p2.drawRectangle(
    x: 0,
    y: 500,
    width: 600,
    height: 300,
    color: rgb(0.8, 0.9, 0.8),
  );
  for (int i = 0; i < images.length; i++) {
    ({double width, double height}) s = images[i].scale(2);
    p2.drawImage(
      images[i],
      x: 20 + (i % 4) * 140,
      y: 700 - (i ~/ 4) * 120,
      width: s.width,
      height: s.height,
    );
  }
  p2.drawImage(
    images[0],
    x: 300,
    y: 300,
    width: 120,
    height: 90,
    rotate: degrees(30),
    opacity: 0.5,
  );
  ({double width, double height}) fit = images[3].scaleToFit(100, 200);
  p2.drawImage(
    images[3],
    x: 100,
    y: 300,
    width: fit.width,
    height: fit.height,
    xSkew: degrees(10),
  );
  p2
    ..moveTo(50, 200)
    ..setFont(times)
    ..setFontSize(18)
    ..setFontColor(rgb(0.6, 0, 0))
    ..setLineHeight(22)
    ..drawText('Page state text\nsecond line')
    ..moveDown(60)
    ..moveRight(10)
    ..drawText('Moved')
    ..translateContent(20, -20)
    ..drawText('After translate', x: 300, y: 150);

  PDFPage p3 = doc.addPage(<double>[400, 400]);
  p3.drawRectangle(
    x: 50,
    y: 50,
    width: 300,
    height: 300,
    color: rgb(0.3, 0.3, 0.9),
  );
  p3.drawText('Scaled page', x: 60, y: 200, size: 30, color: rgb(1, 1, 1));
  p3.scale(1.5, 0.75);
  return doc;
}

void main() {
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('dox_pdf_draw'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  bool ready = hasNode && hasPdftoppm;
  String skip = 'needs npm ci in tool/crosscheck and pdftoppm (poppler-utils)';

  test(
    'drawing renders like pdf-lib, and font metrics match exactly',
    () async {
      ProcessResult r = await Process.run('node', <String>[
        '$crosscheckDir/draw.mjs',
        tmp.path,
        _fixtures,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');

      PDFDocument doc = await _scene();
      // compared as numbers, so 0 and 0.0 are the same
      expect(
        asDoubles(jsonDecode(jsonEncode(_metrics(doc)))),
        asDoubles(jsonDecode(r.stdout as String)),
        reason: 'font metrics',
      );
      String ours = '${tmp.path}/ours.pdf';
      File(ours).writeAsBytesSync(await doc.save());
      await sameRender(ours, '${tmp.path}/theirs.pdf', 3);

      // drawing on a loaded page: the old content is wrapped in q/Q, so its
      // open transform does not change the new drawing
      PDFDocument loaded = await PDFDocument.load(
        File('${tmp.path}/base.pdf').readAsBytesSync(),
      );
      loaded.getPage(0)
        ..drawText('On a loaded page', x: 20, y: 250, size: 20)
        ..drawCircle(x: 150, y: 150, size: 50, color: rgb(1, 0, 0));
      String oursLoaded = '${tmp.path}/ours-loaded.pdf';
      File(oursLoaded).writeAsBytesSync(await loaded.save());
      await sameRender(oursLoaded, '${tmp.path}/theirs-loaded.pdf', 1);
    },
    skip: ready ? false : skip,
  );
}
