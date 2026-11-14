import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:dox_pdf_me/src/fonts/font_store.dart';
import 'package:dox_pdf_me/src/options.dart';
import 'package:dox_pdf_me/src/plugin.dart';
import 'package:dox_pdf_me/src/schema.dart';
import 'package:dox_pdf_me/src/svg/svg_aspect.dart';
import 'package:dox_pdf_me/src/svg/svg_color.dart';
import 'package:dox_pdf_me/src/svg/svg_matrix.dart';
import 'package:dox_pdf_me/src/svg/svg_parser.dart';
import 'package:dox_pdf_me/src/svg/svg_plugin.dart';
import 'package:dox_pdf_me/src/svg/svg_renderer.dart';
import 'package:dox_pdf_me/src/svg/svg_values.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

const String _work =
    '/private/tmp/claude-501/-Users-zinkyawkyaw-projects-dox/'
    '44e5df58-a521-433a-b1ee-7c645e0f749d/scratchpad/svg-work';

const String _pdftoppm = '/opt/homebrew/bin/pdftoppm';

/// All content streams of the first page, decompressed.
Future<String> pageContent(PDFDocument doc) async {
  Uint8List bytes = await doc.save(useObjectStreams: false);
  String pdf = latin1.decode(bytes);
  StringBuffer out = StringBuffer();
  RegExp stream = RegExp(r'stream\r?\n');
  for (RegExpMatch m in stream.allMatches(pdf)) {
    if (m.start > 0 && pdf.substring(m.start - 3, m.start) == 'end') continue;
    int end = pdf.indexOf('endstream', m.end);
    Uint8List data = Uint8List.sublistView(bytes, m.end, end);
    try {
      out.writeln(latin1.decode(zlib.decode(data)));
    } on FormatException {
      out.writeln(latin1.decode(data));
    }
  }
  return out.toString();
}

/// Draws [svg] with the renderer at 0, 0 (top edge [height]).
Future<String> drawContent(
  String svg, {
  double width = 20,
  double height = 20,
  SvgColorMapper? mapColor,
}) async {
  PDFDocument doc = await PDFDocument.create();
  PDFPage page = doc.addPage(<double>[200, 200]);
  await const SvgRenderer().draw(
    page,
    svg,
    x: 0,
    y: height,
    width: width,
    height: height,
    mapColor: mapColor,
  );
  return pageContent(doc);
}

int count(String text, String part) => part.allMatches(text).length;

/// A page of 100 x 100 mm with one schema drawn by [plugin].
Future<PDFDocument> renderSchema(
  SchemaPlugin plugin,
  String value,
  Map<String, dynamic> schema, {
  GenerateOptions? options,
}) async {
  PDFDocument doc = await PDFDocument.create();
  PDFPage page = doc.addPage(<double>[283.46, 283.46]);
  GenerateOptions o = options ?? GenerateOptions();
  await plugin.pdf(
    RenderProps(
      value: value,
      schema: Schema(<String, dynamic>{
        'name': 'f',
        'type': plugin.type,
        ...schema,
      }),
      basePdf: null,
      doc: doc,
      page: page,
      options: o,
      fonts: FontStore(doc, o.font),
      cache: <Object, Object?>{},
    ),
  );
  return doc;
}

/// The page rasterized at 72 dpi (1 pixel = 1 point).
class Raster {
  Raster(Uint8List data) {
    // header: P6 <w> <h> 255, each followed by one whitespace
    List<String> head = latin1
        .decode(data.sublist(0, 40))
        .split(RegExp(r'\s+'));
    width = int.parse(head[1]);
    int headerLength = '${head[0]}\n${head[1]} ${head[2]}\n${head[3]}\n'.length;
    pixels = Uint8List.sublistView(data, headerLength);
  }

  late final int width;
  late final Uint8List pixels;

  static int _n = 0;

  static Future<Raster> of(PDFDocument doc) async {
    Directory(_work).createSync(recursive: true);
    String base = '$_work/r${_n++}';
    File('$base.pdf').writeAsBytesSync(await doc.save());
    ProcessResult r = Process.runSync(_pdftoppm, <String>[
      '-r',
      '72',
      '-singlefile',
      '$base.pdf',
      base,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return Raster(File('$base.ppm').readAsBytesSync());
  }

  /// The color at [x], [y] in points from the TOP left, as 0xRRGGBB.
  int at(num x, num y) {
    int i = (y.floor() * width + x.floor()) * 3;
    return pixels[i] << 16 | pixels[i + 1] << 8 | pixels[i + 2];
  }

  /// True when the pixel is red-ish.
  bool isRed(num x, num y) {
    int c = at(x, y);
    return (c >> 16) > 200 && ((c >> 8) & 0xff) < 80 && (c & 0xff) < 80;
  }

  bool isWhite(num x, num y) => at(x, y) == 0xffffff;
}

double mm(double v) => v * 2.8346;

/// A PNG of [width] x [height] in one RGB color, as a `data:` URL.
String pngDataUrl(int width, int height, List<int> rgb) {
  List<int> crcTable = <int>[
    for (int n = 0; n < 256; n++)
      List<int>.generate(
        8,
        (int i) => i,
      ).fold(n, (int c, int _) => c & 1 == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1),
  ];
  List<int> chunk(String type, List<int> data) {
    List<int> body = <int>[...ascii.encode(type), ...data];
    int crc = 0xffffffff;
    for (int b in body) {
      crc = crcTable[(crc ^ b) & 0xff] ^ (crc >> 8);
    }
    crc ^= 0xffffffff;
    List<int> u32(int v) => <int>[
      v >> 24 & 255,
      v >> 16 & 255,
      v >> 8 & 255,
      v & 255,
    ];
    return <int>[...u32(data.length), ...body, ...u32(crc)];
  }

  List<int> rows = <int>[
    for (int y = 0; y < height; y++) ...<int>[
      0,
      for (int x = 0; x < width; x++) ...rgb,
    ],
  ];
  List<int> png = <int>[
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ...chunk('IHDR', <int>[0, 0, 0, width, 0, 0, 0, height, 8, 2, 0, 0, 0]),
    ...chunk('IDAT', zlib.encode(rows)),
    ...chunk('IEND', <int>[]),
  ];
  return 'data:image/png;base64,${base64.encode(png)}';
}

void main() {
  bool hasPdftoppm = File(_pdftoppm).existsSync();

  tearDownAll(() {
    Directory dir = Directory(_work);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('numbers', () {
    test('jsParseFloat reads the leading number like JS', () {
      expect(jsParseFloat('10px'), 10);
      expect(jsParseFloat(' .5e1x'), 5);
      expect(jsParseFloat('1.'), 1);
      expect(jsParseFloat('-Infinity'), double.negativeInfinity);
      expect(jsParseFloat('px'), isNaN);
    });

    test('parseFloatValue resolves percent against the reference', () {
      expect(parseFloatValue('50%', 200), 100);
      expect(parseFloatValue('12'), 12);
      expect(parseFloatValue(''), isNull);
      expect(parseFloatValue('abc'), isNull);
    });

    test('view box splits on single spaces only, like pdfme', () {
      SvgBox b = SvgBox.parse('1 2 24 48');
      expect(<double>[b.x, b.y, b.width, b.height], <double>[1, 2, 24, 48]);
      SvgBox comma = SvgBox.parse('0,0,24,24');
      expect(<double>[comma.width, comma.height], <double>[1, 1]);
      SvgBox twoSpaces = SvgBox.parse('0  0 24 24');
      expect(<double>[twoSpaces.width, twoSpaces.height], <double>[0, 24]);
    });
  });

  group('colors', () {
    void expectRgb(String css, List<int> rgb255, [double? alpha]) {
      CssColorValue c = CssColor.parse(css);
      expect(c.rgb.red, closeTo(rgb255[0] / 255, 1e-9), reason: css);
      expect(c.rgb.green, closeTo(rgb255[1] / 255, 1e-9), reason: css);
      expect(c.rgb.blue, closeTo(rgb255[2] / 255, 1e-9), reason: css);
      expect(c.alpha, alpha, reason: css);
    }

    test('reads hex, rgb(), rgba(), names and hsl()', () {
      expectRgb('#abc', <int>[0xaa, 0xbb, 0xcc]);
      expectRgb('#112233', <int>[17, 34, 51]);
      expectRgb('#11223380', <int>[17, 34, 51], 0.5);
      expectRgb('rgb(17, 34, 51)', <int>[17, 34, 51]);
      expectRgb('rgba(17, 34, 51, 0.5)', <int>[17, 34, 51], 0.5);
      // 50 * 2.55 is 127.4999..., so 127 like JS
      expectRgb('rgb(100%, 0%, 50%)', <int>[255, 0, 127]);
      expectRgb('blue', <int>[0, 0, 255]);
      expectRgb('RebeccaPurple', <int>[0x66, 0x33, 0x99]);
      expectRgb('hsl(120, 100%, 50%)', <int>[0, 255, 0]);
      expectRgb('hsla(0, 100%, 50%, 0.25)', <int>[255, 0, 0], 0.25);
    });

    test('throws for a value it can not read, like pdfme', () {
      expect(() => CssColor.parse('url(#g)'), throwsArgumentError);
    });
  });

  group('matrix', () {
    test('translate flips y', () {
      SvgMatrix m = SvgMatrix.identity.thenList('translate(10 20)');
      expect(m.values, <double>[1, 0, 0, 1, 10, -20]);
      expect(SvgMatrix.transform('translate', <double>[5]).values.last, -5);
    });

    test('rotate turns the PDF way, around a point', () {
      ({double x, double y}) p = SvgMatrix.transform('rotate', <double>[
        90,
      ]).apply(1, 0);
      expect(p.x, closeTo(0, 1e-12));
      expect(p.y, closeTo(-1, 1e-12));
      ({double x, double y}) c = SvgMatrix.transform('rotate', <double>[
        90,
        5,
        5,
      ]).apply(5, -5);
      expect(c.x, closeTo(5, 1e-12));
      expect(c.y, closeTo(-5, 1e-12));
    });

    test('scale, skew and matrix()', () {
      expect(SvgMatrix.transform('scale', <double>[2]).values, <double>[
        2,
        0,
        0,
        2,
        0,
        0,
      ]);
      expect(SvgMatrix.transform('skewX', <double>[45]).c, closeTo(-1, 1e-12));
      expect(
        SvgMatrix.transform('matrix', <double>[1, 2, 3, 4, 5, 6]).values,
        <double>[1, -2, -3, 4, 5, -6],
      );
      expect(SvgMatrix.transform('nope', <double>[1]).values, <double>[
        1,
        0,
        0,
        1,
        0,
        0,
      ]);
    });

    test('a transform list works left to right', () {
      SvgMatrix m = SvgMatrix.identity.thenList('translate(10, 0) scale(2)');
      ({double x, double y}) p = m.apply(1, 0);
      expect(p.x, 12);
    });
  });

  group('aspect ratio', () {
    test('meet uses the y scale when the target is wider (pdfme bug)', () {
      // a 100 x 10 view box into 60 x 50: correct meet would be 0.6
      ({SvgMatrix clipBox, SvgMatrix content}) t = SvgAspectRatio.transform(
        SvgMatrix.identity,
        100,
        10,
        60,
        50,
        'xMidYMid',
      );
      expect(t.content.a, 5);
      expect(t.clipBox.values.take(4), <double>[0.6, 0, 0, 5]);
    });

    test('meet uses the x scale when the target is not wider', () {
      ({SvgMatrix clipBox, SvgMatrix content}) t = SvgAspectRatio.transform(
        SvgMatrix.identity,
        24,
        24,
        50,
        100,
        'xMidYMid',
      );
      expect(t.content.a, closeTo(50 / 24, 1e-12));
      // centered: (100 - 50) / 2 down, as -y in PDF space
      expect(t.content.f, -25);
    });

    test('none stretches; xMinYMin does not move', () {
      ({SvgMatrix clipBox, SvgMatrix content}) none = SvgAspectRatio.transform(
        SvgMatrix.identity,
        10,
        10,
        40,
        20,
        'none',
      );
      expect(none.content.values.take(4), <double>[4, 0, 0, 2]);
      ({SvgMatrix clipBox, SvgMatrix content}) min = SvgAspectRatio.transform(
        SvgMatrix.identity,
        10,
        10,
        20,
        40,
        'xMinYMin',
      );
      expect(<double>[min.content.e, min.content.f], <double>[0, 0]);
    });

    test('fit keeps the image ratio', () {
      SvgRect r = SvgAspectRatio.fit(10, 5, 40, 40, null);
      expect(<double>[r.x, r.y, r.width, r.height], <double>[0, 10, 40, 20]);
    });
  });

  group('dash', () {
    test('parses like pdfme', () {
      expect(SvgDash.parseArray('3')!.length, 2);
      expect(SvgDash.parseArray('NONE'), isEmpty);
      expect(SvgDash.parseArray('0 0'), isEmpty);
      expect(SvgDash.parseArray('4 -2'), isNull);
      expect(SvgDash.parseArray('4 2abc'), isNull);
      expect(SvgDash.parseArray('4 1e999'), isNull);
      expect(SvgDash.parseOffset('Infinity'), isNull);
    });

    test('resolves percent and wraps the offset', () {
      DashPattern p = SvgDash.resolve(
        SvgDash.parseArray('10%'),
        SvgDash.parseOffset('-1'),
        const SvgBox(0, 0, 20, 20),
      );
      expect(p.array, <double>[2, 2]);
      expect(p.offset, 3);
    });
  });

  group('parser', () {
    List<SvgShape> parse(String svg) {
      XmlElement root = XmlDocument.parse(svg).rootElement;
      return SvgParser().parseNode(
        root,
        SvgParser.attributesOf(root),
        SvgStyle(
          width: 100,
          height: 100,
          viewBox: SvgBox.parse(root.getAttribute('viewBox') ?? '0 0 1 1'),
        ),
        SvgMatrix.identity,
        <SvgClipSpace>[],
      );
    }

    test('a polygon becomes a path, flipped for the y axis', () {
      SvgShape s = parse(
        '<svg width="10" height="10"><polygon points="0,0 10,0 10,10"/></svg>',
      ).single;
      expect(s.tag, 'path');
      expect(s.d, 'M0,0 10,0 10,10Z');
      expect(s.matrix.d, -1);
    });

    test('fill, stroke and fonts are inherited; style wins', () {
      SvgShape s = parse(
        '<svg width="10" height="10"><g fill="red" style="stroke: blue" '
        'font-family="\'My Font\', serif"><rect width="1" height="1"/></g>'
        '</svg>',
      ).single;
      expect((s.style.fill! as RGB).red, 1);
      expect((s.style.stroke! as RGB).blue, 1);
      expect(s.style.fontFamily, 'My Font');
    });

    test('currentColor takes the inherited paint, else black', () {
      List<SvgShape> s = parse(
        '<svg width="10" height="10"><g fill="red">'
        '<rect width="1" height="1" fill="currentColor"/></g>'
        '<rect width="1" height="1" stroke="currentColor"/></svg>',
      );
      expect((s[0].style.fill! as RGB).red, 1);
      expect((s[1].style.stroke! as RGB).red, 0);
    });

    test('x and y are a translate; a nested svg adds a clip', () {
      List<SvgShape> s = parse(
        '<svg width="100" height="100"><rect x="5" y="6" width="1" '
        'height="1" fill="red"/><svg x="10" width="20" height="20">'
        '<rect width="1" height="1" fill="red"/></svg></svg>',
      );
      expect(<double>[s[0].matrix.e, s[0].matrix.f], <double>[5, -6]);
      expect(s[0].clipSpaces.length, 1);
      expect(s[1].clipSpaces.length, 2);
      expect(s[1].matrix.e, 10);
    });
  });

  group('drawSvg content (pdfme svg.spec)', () {
    test('uses mapped CMYK colors for fills, strokes and text', () async {
      List<RGB> seen = <RGB>[];
      String content = await drawContent(
        '<svg width="20" height="30">'
        '<rect width="10" height="10" fill="#000000"/>'
        '<path d="M0 15L10 15" stroke="#000000" stroke-width="1" fill="none"/>'
        '<text x="0" y="25" fill="#112233">A</text></svg>',
        width: 20,
        height: 30,
        mapColor: (RGB c) {
          seen.add(c);
          return cmyk(0, 0, 0, 1);
        },
      );
      expect(content, contains('0 0 0 1 k'));
      expect(content, contains('0 0 0 1 K'));
      expect(content, isNot(matches(RegExp(r'\srg\n'))));
      expect(content, isNot(matches(RegExp(r'\sRG\n'))));
      expect(seen.any((RGB c) => (c.blue - 0.2).abs() < 1e-9), isTrue);
    });

    test('keeps RGB when there is no mapper', () async {
      String content = await drawContent(
        '<svg width="10" height="10"><rect width="10" height="10" '
        'fill="#112233" stroke="#445566" stroke-width="1"/></svg>',
        width: 10,
        height: 10,
      );
      expect(
        content,
        contains('0.06666666666666667 0.13333333333333333 0.2 rg'),
      );
      expect(
        content,
        contains('0.26666666666666666 0.3333333333333333 0.4 RG'),
      );
      expect(content, isNot(contains(' k\n')));
    });

    test('alpha becomes a graphics state, not a color change', () async {
      String content = await drawContent(
        '<svg width="10" height="10"><rect width="10" height="10" '
        'fill="rgba(17, 34, 51, 0.5)"/></svg>',
        width: 10,
        height: 10,
        mapColor: (RGB c) => cmyk(1, 0, 0, 0),
      );
      expect(content, contains('1 0 0 0 k'));
      expect(content, matches(RegExp(r'/\S+ gs')));
    });

    test('none and transparent paint nothing', () async {
      int mapped = 0;
      String content = await drawContent(
        '<svg width="20" height="10">'
        '<rect width="10" height="10" fill="none" stroke="transparent"/>'
        '<path d="M10 0L20 0" stroke="currentColor" fill="none"/></svg>',
        width: 20,
        height: 10,
        mapColor: (RGB c) {
          mapped++;
          return cmyk(0, 0, 0, 1);
        },
      );
      expect(content, contains('0 0 0 1 K'));
      expect(mapped, 1);
    });

    test('applies stroke-dasharray and stroke-dashoffset', () async {
      String content = await drawContent(
        '<svg width="40" height="40">'
        '<line x1="0" y1="0" x2="10" y2="0" stroke="#000" '
        'stroke-dasharray="4 2" stroke-dashoffset="1"/>'
        '<path d="M0 5L10 5" stroke="#000" fill="none" '
        'stroke-dasharray="4,2" stroke-dashoffset="1"/>'
        '<rect width="10" height="10" stroke="#000" '
        'style="stroke-dasharray: 4, 2; stroke-dashoffset: 1"/>'
        '<circle cx="20" cy="20" r="5" stroke="#000" '
        'stroke-dasharray="4 2" stroke-dashoffset="1"/>'
        '<polygon points="0,0 10,0 10,10" stroke="#000" '
        'stroke-dasharray="4 2" stroke-dashoffset="1"/></svg>',
        width: 40,
        height: 40,
      );
      expect(count(content, '[4 2] 1 d'), 5);
      expect(content, isNot(contains('[] 0 d')));
    });

    test('inherits dash patterns and lets children reset them', () async {
      String content = await drawContent(
        '<svg width="20" height="20">'
        '<g stroke="#000" stroke-dasharray="3" stroke-dashoffset="-1">'
        '<path d="M0 0L10 0" fill="none"/>'
        '<path d="M0 5L10 5" fill="none" stroke-dasharray="none"/>'
        '<path d="M0 10L10 10" fill="none" stroke-dasharray="10%"/>'
        '</g></svg>',
      );
      expect(content, contains('[3 3] 5 d'));
      expect(content, contains('[] 0 d'));
      expect(content, contains('[2 2] 3 d'));
    });

    test('resolves dash percent against the nearest viewport', () async {
      String content = await drawContent(
        '<svg width="100" height="100">'
        '<path d="M0 0L10 0" stroke="#000" fill="none" '
        'stroke-dasharray="10%" stroke-dashoffset="5%"/>'
        '<svg width="20" height="20" viewBox="0 0 20 20" '
        'stroke-dasharray="10%" stroke-dashoffset="5%">'
        '<path d="M0 5L10 5" stroke="#000" fill="none"/></svg>'
        '<g stroke-dasharray="20%" stroke-dashoffset="15%">'
        '<svg width="20" height="20" viewBox="0 0 20 20">'
        '<path d="M0 10L10 10" stroke="#000" fill="none"/></svg></g></svg>',
        width: 100,
        height: 100,
      );
      expect(content, contains('[10 10] 5 d'));
      expect(content, contains('[2 2] 1 d'));
      expect(content, contains('[4 4] 3 d'));
    });

    test('ignores bad dash values', () async {
      String content = await drawContent(
        '<svg width="20" height="20">'
        '<g stroke="#000" stroke-dasharray="3" stroke-dashoffset="1">'
        '<path d="M0 0L10 0" fill="none" stroke-dasharray="4 2abc"/>'
        '<path d="M0 5L10 5" fill="none" stroke-dashoffset="2abc"/>'
        '<path d="M0 10L10 10" fill="none" stroke-dasharray="4px, 2" '
        'stroke-dashoffset="1px"/>'
        '<line x1="0" y1="0" x2="10" y2="0" stroke-dashoffset="Infinity"/>'
        '</g></svg>',
      );
      expect(count(content, '[3 3] 1 d'), 3);
      expect(content, contains('[4 2] 1 d'));
      expect(content, isNot(contains('NaN')));
    });

    test('each element: q, clip, cm, draw, Q', () async {
      String content = await drawContent(
        '<svg width="10" height="10" viewBox="0 0 10 10">'
        '<text x="5" y="5" text-anchor="middle">Hi</text></svg>',
        width: 10,
        height: 10,
      );
      expect(content, contains('q\n0 10 m\n10 10 l\n10 0 l\n0 0 l\nh\nW\nn\n'));
      expect(content, contains('1 0 0 1 5 5 cm'));
      expect(content, contains('Tj'));
    });
  });

  group('fonts', () {
    test('selectFontNames picks the best font per text', () {
      Set<String> names = SvgPlugin.selectFontNames(
        '<svg><g font-weight="700"><text font-family="Missing, Brand">A'
        '</text></g><text style="font-family: Other">B</text></svg>',
        <String>['Brand', 'Brand_bold', 'Other Sans'],
      );
      expect(names, <String>{'Brand_bold', 'Other Sans'});
    });

    test('a text draws with the selected font', () async {
      PDFDocument doc = await renderSchema(
        const SvgPlugin(),
        '<svg width="10" height="10"><text font-family="BrandFont" '
        'font-weight="700" y="8">A</text></svg>',
        <String, dynamic>{
          'position': <String, double>{'x': 0, 'y': 0},
          'width': 10,
          'height': 10,
        },
        options: GenerateOptions(
          font: <String, FontSource>{'BrandFont': FontStore.defaultFont},
        ),
      );
      String content = await pageContent(doc);
      expect(content, contains('Tj'));
      expect(await doc.save(), isNotEmpty);
    });
  });

  group('plugins', () {
    test('svg skips values without <svg and </svg>', () async {
      for (String v in <String>['', '<svg/>', 'hello']) {
        PDFDocument doc = await renderSchema(
          const SvgPlugin(),
          v,
          <String, dynamic>{'width': 10, 'height': 10},
        );
        expect(await pageContent(doc), isNot(contains('cm')));
      }
    });

    test('svg rotation wraps the drawing around the box center', () async {
      PDFDocument doc = await renderSchema(
        const SvgPlugin(),
        '<svg width="10" height="10"><rect width="10" height="10" '
        'fill="#112233"/></svg>',
        <String, dynamic>{
          'position': <String, double>{'x': 20, 'y': 30},
          'width': 40,
          'height': 10,
          'rotate': 30,
        },
      );
      double height = mm(10);
      double y = 283.46 - mm(30) - height;
      String cx = numberToString(mm(20) + mm(40) / 2);
      String cy = numberToString(y + height / 2);
      String content = await pageContent(doc);
      expect(content, contains('q\n1 0 0 1 $cx $cy cm\n'));
      expect(content, contains(rotateDegrees(-30).toString()));
      expect(content, contains('1 0 0 1 -$cx -$cy cm'));
    });

    test('checkbox icon follows pdfme', () {
      expect(
        CheckboxPlugin.icon(true, '#000000'),
        '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
        'viewBox="0 0 24 24" fill="none" stroke="#000000" stroke-width="2" '
        'stroke-linecap="round" stroke-linejoin="round">'
        '<rect width="18" height="18" x="3" y="3" rx="2"/>'
        '<path d="m16 9-5.5 5.5L8 12"/></svg>',
      );
      // pdfme's default stroke: `currentColor` (black)
      expect(
        CheckboxPlugin.icon(false, null),
        contains('stroke="currentColor"'),
      );
      expect(RadioGroupPlugin.icon(true, 'red'), contains('r="1"'));
    });
  });

  group('render', skip: hasPdftoppm ? false : 'no pdftoppm', () {
    Map<String, dynamic> box(double x, double y, double w, double h) =>
        <String, dynamic>{
          'position': <String, double>{'x': x, 'y': y},
          'width': w,
          'height': h,
        };

    test('svg shapes land in the box', () async {
      PDFDocument doc = await renderSchema(
        const SvgPlugin(),
        '<svg width="10" height="10" viewBox="0 0 10 10">'
        '<rect x="0" y="0" width="5" height="10" fill="red"/>'
        '<circle cx="7.5" cy="5" r="2" fill="#0000ff"/></svg>',
        box(10, 10, 40, 40),
      );
      Raster r = await Raster.of(doc);
      expect(r.isRed(mm(15), mm(30)), isTrue);
      expect(r.at(mm(40), mm(30)), 0x0000ff);
      expect(r.isWhite(mm(40), mm(15)), isTrue);
      expect(r.isWhite(mm(5), mm(30)), isTrue);
    });

    test('meet quirk: a wide box is scaled by its height', () async {
      // a 100 x 10 view box in a 40 x 10 mm box: pdfme scales by the
      // height (1 mm per unit) and the clip cuts the rest; a correct meet
      // would scale by 0.4 and leave the top and bottom white.
      PDFDocument doc = await renderSchema(
        const SvgPlugin(),
        '<svg viewBox="0 0 100 10"><rect width="50" height="10" fill="red"/>'
        '</svg>',
        box(0, 0, 40, 10),
      );
      Raster r = await Raster.of(doc);
      expect(r.isRed(mm(10), mm(1)), isTrue);
      expect(r.isWhite(mm(30), mm(5)), isTrue);
    });

    test('nested svg clips; transforms move shapes', () async {
      PDFDocument doc = await renderSchema(
        const SvgPlugin(),
        '<svg width="100" height="100" viewBox="0 0 100 100">'
        '<svg x="0" y="0" width="50" height="50" viewBox="0 0 50 50">'
        '<rect width="100" height="100" fill="red"/></svg>'
        '<g transform="translate(60 60) rotate(45 10 10)">'
        '<rect width="20" height="20" fill="#0000ff"/></g></svg>',
        box(0, 0, 100, 100),
      );
      Raster r = await Raster.of(doc);
      expect(r.isRed(mm(25), mm(25)), isTrue);
      // clipped by the nested svg
      expect(r.isWhite(mm(55), mm(25)), isTrue);
      expect(r.at(mm(70), mm(70)), 0x0000ff);
      // a corner of the unturned square is outside the turned one
      expect(r.isWhite(mm(61), mm(61)), isTrue);
    });

    test('svg rotation turns the drawing', () async {
      PDFDocument doc = await renderSchema(
        const SvgPlugin(),
        '<svg viewBox="0 0 40 10" preserveAspectRatio="none">'
        '<rect width="40" height="10" fill="red"/></svg>',
        <String, dynamic>{...box(30, 45, 40, 10), 'rotate': 90},
      );
      Raster r = await Raster.of(doc);
      expect(r.isRed(mm(50), mm(50)), isTrue);
      expect(r.isRed(mm(50), mm(32)), isTrue);
      expect(r.isWhite(mm(33), mm(50)), isTrue);
    });

    test('image: a data URL png fills its box', () async {
      PDFDocument doc = await renderSchema(
        const SvgPlugin(),
        '<svg width="20" height="20" viewBox="0 0 20 20">'
        '<image x="10" y="0" width="10" height="20" '
        'href="ignored" xlink:href="${pngDataUrl(2, 2, <int>[255, 0, 0])}" '
        'xmlns:xlink="http://www.w3.org/1999/xlink"/></svg>',
        box(0, 0, 20, 20),
      );
      Raster r = await Raster.of(doc);
      // a square image fits in the middle of the 10 x 20 box
      expect(r.isRed(mm(15), mm(10)), isTrue);
      expect(r.isWhite(mm(15), mm(2)), isTrue);
      expect(r.isWhite(mm(5), mm(10)), isTrue);
    });

    test('checkbox: border, check mark, no color', () async {
      // icon units: 24 into 24 mm, so 1 unit = 1 mm
      Map<String, dynamic> s = <String, dynamic>{
        ...box(10, 10, 24, 24),
        'color': '#ff0000',
      };
      Raster on = await Raster.of(
        await renderSchema(const CheckboxPlugin(), 'true', s),
      );
      expect(on.isRed(mm(10 + 12), mm(10 + 3)), isTrue);
      // on the check mark: from (8,12) to (10.5,14.5)
      expect(on.isRed(mm(10 + 10.5), mm(10 + 14.5)), isTrue);
      Raster off = await Raster.of(
        await renderSchema(const CheckboxPlugin(), 'TRUE', s),
      );
      expect(off.isRed(mm(10 + 12), mm(10 + 3)), isTrue);
      expect(off.isWhite(mm(10 + 10.5), mm(10 + 14.5)), isTrue);
      Raster none = await Raster.of(
        await renderSchema(const CheckboxPlugin(), 'true', box(10, 10, 24, 24)),
      );
      // no color: pdfme draws it black (`currentColor`)
      expect(none.isWhite(mm(10 + 12), mm(10 + 3)), isFalse);
      expect(none.isRed(mm(10 + 12), mm(10 + 3)), isFalse);
    });

    test('radioGroup: ring, dot when checked', () async {
      Map<String, dynamic> s = <String, dynamic>{
        ...box(10, 10, 24, 24),
        'color': '#ff0000',
      };
      Raster on = await Raster.of(
        await renderSchema(const RadioGroupPlugin(), 'true', s),
      );
      expect(on.isRed(mm(10 + 12), mm(10 + 2)), isTrue);
      expect(on.isRed(mm(10 + 12), mm(10 + 12)), isTrue);
      Raster off = await Raster.of(
        await renderSchema(const RadioGroupPlugin(), '', s),
      );
      expect(off.isRed(mm(10 + 12), mm(10 + 2)), isTrue);
      expect(off.isWhite(mm(10 + 12), mm(10 + 12)), isTrue);
    });
  });
}
