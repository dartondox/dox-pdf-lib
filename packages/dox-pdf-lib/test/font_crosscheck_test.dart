// Embeds the same custom fonts with dox_pdf_lib and with pdf-lib +
// @pdf-lib/fontkit (tool/crosscheck/fonts.mjs), then compares:
// - the font metrics and the encoded text, exactly;
// - the rendered pages (pdftoppm), pixel by pixel with a small tolerance;
// - the text that pdftotext reads (the ToUnicode CMap).
// Needs `npm ci` in tool/crosscheck, poppler-utils and the test fonts
// (downloaded once); skipped without them.
import 'dart:convert';
import 'dart:io';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

import 'render_support.dart';

/// Keep in sync with fonts.mjs.
const List<String> _fonts = <String>[
  'Lato-Regular.ttf',
  'SourceSans3-Regular.otf',
  'NotoSansJP-Regular.otf',
];

const List<String> _latin = <String>[
  'Hello World',
  'office fi ffl AVATAR Wa To. Ta Ty',
  'Grüße € „Quote“ naïve façade',
  'é a‍b x­z   ‑',
  '0123456789 ½ 1/2 ©®™',
  '',
];

const List<String> _japanese = <String>[
  '日本語のテキスト、カタカナ。',
  '漢字とひらがな ABC 123',
  '𠮷野家 ｱｲｳ',
];

List<String> _samples(String font) =>
    font.startsWith('NotoSansJP') ? <String>[..._latin, ..._japanese] : _latin;

/// Only Japanese for the CJK font: in Latin text, it lays out digits with
/// glyphs that its cmap does not have, and pdf-lib's full font has no width
/// for them (so it draws them 1000 wide; we do not).
String _paragraph(String font) => font.startsWith('NotoSansJP')
    ? _japanese.join(' ')
    : 'Wrapped text in a custom font, office files and fine ligatures here. '
          '${_latin.join(' ')}';

/// The same as fonts.mjs: metrics, then one page.
Future<Map<String, Object?>> _scene(
  String font,
  bool subset,
  String out,
) async {
  PDFDocument doc = await PDFDocument.create();
  PDFFont f = await doc.embedFont(testFont(font), subset: subset);
  List<String> set = _samples(font);
  List<int> cs = f.getCharacterSet();
  Map<String, Object?> metrics = <String, Object?>{
    'font': font,
    'subset': subset,
    'name': f.name,
    'widths': <double>[for (String t in set) f.widthOfTextAtSize(t, 12.5)],
    'height': f.heightAtSize(12.5),
    'heightNoDescender': f.heightAtSize(12.5, descender: false),
    'sizeAtHeight': f.sizeAtHeight(20),
    'charset': <int>[cs.length, cs.first, cs.last],
    'encoded': <String>[for (String t in set) f.encodeText(t).toString()],
  };
  PDFPage page = doc.addPage(<double>[600, 800]);
  double y = 760;
  for (String t in set) {
    page.drawText(t, x: 30, y: y, size: 18, font: f);
    y -= 30;
  }
  page.drawText(
    _paragraph(font),
    x: 30,
    y: y,
    size: 14,
    font: f,
    maxWidth: 400,
    lineHeight: 18,
    color: rgb(0.1, 0.3, 0.6),
  );
  File(out).writeAsBytesSync(await doc.save());
  return metrics;
}

void main() {
  late Directory tmp;
  late bool fonts;
  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('dox_pdf_fonts');
    fonts = await fetchTestFonts();
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  bool ready = hasNode && hasPdftoppm && hasPdftotext;
  String skip = 'needs npm ci in tool/crosscheck and poppler-utils';

  test(
    'custom fonts measure, render and extract like pdf-lib + fontkit',
    () async {
      if (!fonts) {
        markTestSkipped('the test fonts could not be downloaded');
        return;
      }
      ProcessResult r = await Process.run('node', <String>[
        '$crosscheckDir/fonts.mjs',
        tmp.path,
        testFontDir,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      List<Object?> theirs = jsonDecode(r.stdout as String) as List<Object?>;
      int i = 0;
      for (String font in _fonts) {
        for (bool subset in <bool>[false, true]) {
          String ours = '${tmp.path}/ours-$font-$subset.pdf';
          // The pages are compared with pdf-lib's full font: its CFF subset
          // (fontkit's CFFSubset) does not load in poppler, which then
          // draws another font, and its subset has no W width for
          // `.notdef` (we add it).
          String other = '${tmp.path}/theirs-$font-false.pdf';
          Map<String, Object?> m = await _scene(font, subset, ours);
          expect(
            asDoubles(jsonDecode(jsonEncode(m))),
            asDoubles(theirs[i++]),
            reason: '$font subset: $subset',
          );
          await sameRender(ours, other, 1);
          expect(
            await pdfText(ours),
            await pdfText('${tmp.path}/theirs-$font-$subset.pdf'),
            reason: '$font subset: $subset',
          );
        }
      }
    },
    skip: ready ? false : skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
