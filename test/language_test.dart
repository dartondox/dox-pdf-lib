// The language matrix: real sentences in Noto fonts, full and subset.
// For each language:
// - copy: pdftotext gives back the text, also of a wrapped paragraph;
// - render: the page renders like pdf-lib's (languages that fontkit lays
//   out like HarfBuzz), or is not blank and has no `.notdef` glyph;
// - width: widthOfTextAtSize equals pdf-lib + fontkit exactly, or for a
//   complex script HarfBuzz's advances (`hb-shape`), and the glyphs equal
//   hb-shape's;
// - wrap: a wrapped line never starts inside a cluster (a mark).
// Needs node (npm ci in tool/crosscheck), poppler-utils, hb-shape
// (libharfbuzz-bin) and the test fonts (downloaded once).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

import 'render_support.dart';

class _Lang {
  const _Lang(
    this.font,
    this.lines, {
    this.complex = false,
    this.pdfLibRender = true,
  });

  final String font;
  final List<String> lines;

  /// Laid out by HarfBuzz's rules (fontkit can not lay it out the same).
  final bool complex;

  /// pdf-lib renders it right. Not for Korean: fontkit's Hangul layout
  /// makes a space glyph that the cmap has not, and pdf-lib's full font has
  /// no width for it, so it draws it 1000 units wide.
  final bool pdfLibRender;
}

const Map<String, _Lang> _langs = <String, _Lang>{
  'English': _Lang('NotoSans-Regular.ttf', <String>[
    'The quick brown fox jumps over the lazy dog.',
    'Office affinity: fine, fluffy waffles.',
  ]),
  'German': _Lang('NotoSans-Regular.ttf', <String>[
    'Größe, Übermaß und Fußgänger: Äpfel, Öl.',
    'GROẞE STRAẞE, schön müde Bären.',
  ]),
  'Vietnamese': _Lang('NotoSans-Regular.ttf', <String>[
    'Tiếng Việt có dấu: phở bò, chữ Nôm.',
    'Người ở đâu? Nghiêng ngả, ước mơ.',
  ]),
  'Japanese': _Lang('NotoSansJP-Regular.otf', <String>[
    '日本語のテキスト、カタカナとひらがな。',
    '東京都の天気は晴れです。',
  ]),
  'Chinese': _Lang('NotoSansSC-Regular.otf', <String>[
    '中文简体：我们在北京学习汉语。',
    '今天天气很好，欢迎光临！',
  ]),
  'Korean': _Lang('NotoSansKR-Regular.otf', <String>[
    '한국어 문장입니다.',
    '안녕하세요, 세계! 반갑습니다.',
  ], pdfLibRender: false),
  'Thai': _Lang('NotoSansThai-Regular.ttf', <String>[
    'ภาษาไทยมีวรรณยุกต์ น้ำใจ ผู้ใหญ่',
    'สวัสดีครับ ค่ำคืนนี้ทำอาหาร',
  ], complex: true),
  'Myanmar': _Lang('NotoSansMyanmar-Regular.ttf', <String>[
    'မြန်မာဘာသာ မင်္ဂလာပါ',
    'နေကောင်းလား ကျေးဇူးတင်ပါတယ်',
  ], complex: true),
  'Khmer': _Lang('NotoSansKhmer-Regular.ttf', <String>[
    'ភាសាខ្មែរ សួស្តី ពិភពលោក',
    'អរគុណច្រើន ស្រុកខ្មែរ',
  ], complex: true),
  'Arabic': _Lang('NotoSansArabic-Regular.ttf', <String>[
    'مرحبا بالعالم',
    'اللغة العربية جميلة',
  ], complex: true),
  'Hindi': _Lang('NotoSansDevanagari-Regular.ttf', <String>[
    'हिन्दी भाषा में नमस्ते',
    'क्षत्रिय विद्यालय दुनिया',
  ], complex: true),
};

/// The lines, then the lines as one wrapped paragraph. The same as
/// languages.mjs. A complex script wraps at any cluster (`''`), the others
/// at spaces, like pdf-lib.
Future<Uint8List> _draw(_Lang lang, bool subset) async {
  PDFDocument doc = await PDFDocument.create();
  PDFFont f = await doc.embedFont(testFont(lang.font), subset: subset);
  PDFPage page = doc.addPage(<double>[500, 500]);
  double y = 460;
  for (String t in lang.lines) {
    page.drawText(t, x: 20, y: y, size: 16, font: f);
    y -= 30;
  }
  page.drawText(
    lang.lines.join(' '),
    x: 20,
    y: y,
    size: 14,
    font: f,
    maxWidth: 150,
    lineHeight: 22,
    wordBreaks: lang.complex ? <String>[''] : null,
  );
  return doc.save();
}

/// units per em, from the `head` table
int _upem(Uint8List font) {
  ByteData d = ByteData.sublistView(font);
  for (int i = 0; i < d.getUint16(4); i++) {
    int rec = 12 + i * 16;
    if (ascii.decode(font.sublist(rec, rec + 4)) == 'head') {
      return d.getUint16(d.getUint32(rec + 8) + 18);
    }
  }
  throw StateError('no head table');
}

/// hb-shape's glyphs (hex, like encodeText) and the sum of the advances.
(String, int) _hbShape(String font, String text) {
  ProcessResult r = Process.runSync('hb-shape', <String>[
    '--output-format=json',
    '--no-glyph-names',
    '$testFontDir/$font',
    '-u',
    text.runes.map((int c) => 'U+${c.toRadixString(16)}').join(','),
  ]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  List<Object?> glyphs = jsonDecode(r.stdout as String) as List<Object?>;
  String hex = glyphs
      .map((Object? g) => ((g! as Map<String, Object?>)['g']! as int))
      .map((int g) => g.toRadixString(16).toUpperCase().padLeft(4, '0'))
      .join();
  int advance = glyphs.fold(
    0,
    (int a, Object? g) => a + ((g! as Map<String, Object?>)['ax']! as int),
  );
  return ('<$hex>', advance);
}

final RegExp _mark = RegExp(r'^\p{M}', unicode: true);

String _noSpace(String s) => s.replaceAll(RegExp(r'\s'), '');

void main() {
  late Directory tmp;
  late bool fonts;
  late Map<String, Object?> theirs;
  bool ready = hasNode && hasPdftoppm && hasPdftotext && _tool('hb-shape');
  String skip = 'needs npm ci in tool/crosscheck, poppler-utils and hb-shape';

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('dox_pdf_lang');
    fonts = ready && await fetchTestFonts();
    if (!fonts) return;
    Map<String, Object?> simple = <String, Object?>{
      for (MapEntry<String, _Lang> e in _langs.entries)
        if (!e.value.complex)
          e.key: <String, Object?>{
            'font': e.value.font,
            'lines': e.value.lines,
          },
    };
    ProcessResult r = await Process.run('node', <String>[
      '$crosscheckDir/languages.mjs',
      tmp.path,
      testFontDir,
      jsonEncode(simple),
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    theirs = jsonDecode(r.stdout as String) as Map<String, Object?>;
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  for (MapEntry<String, _Lang> e in _langs.entries) {
    String name = e.key;
    _Lang lang = e.value;
    for (bool subset in <bool>[false, true]) {
      String mode = subset ? 'subset' : 'full';
      String pdf() => '${tmp.path}/ours-$name-$mode.pdf';
      Future<void> make() async {
        if (!File(pdf()).existsSync()) {
          File(pdf()).writeAsBytesSync(await _draw(lang, subset));
        }
      }

      group('$name $mode', skip: ready ? false : skip, () {
        test('copy and wrap', () async {
          if (!fonts) return markTestSkipped('no test fonts');
          await make();
          List<String> got = (await pdfText(pdf()))
              .split('\n')
              // pdftotext marks right-to-left lines with bidi controls
              .map(
                (String l) =>
                    l.replaceAll(RegExp('[\u202A-\u202E]'), '').trim(),
              )
              .where((String l) => l.isNotEmpty)
              .toList();
          expect(got.take(lang.lines.length), lang.lines);
          List<String> wrapped = got.skip(lang.lines.length).toList();
          expect(wrapped.length, greaterThan(1), reason: 'the text wraps');
          expect(_noSpace(wrapped.join()), _noSpace(lang.lines.join()));
          for (String l in wrapped) {
            expect(
              _mark.hasMatch(l),
              isFalse,
              reason: 'a line starts with a mark: $l',
            );
          }
        });

        test('render', () async {
          if (!fonts) return markTestSkipped('no test fonts');
          await make();
          if (!lang.complex && lang.pdfLibRender) {
            await sameRender(pdf(), '${tmp.path}/theirs-$name.pdf', 1);
            return;
          }
          List<Ppm> pages = await render(pdf(), '${pdf()}.png');
          int dark = 0;
          for (int i = 0; i < pages[0].pixels.length; i += 3) {
            if (pages[0].pixels[i] < 128) dark++;
          }
          expect(dark, greaterThan(200), reason: 'the page is not blank');
          PDFDocument doc = await PDFDocument.create();
          PDFFont f = await doc.embedFont(testFont(lang.font));
          for (String t in lang.lines) {
            String hex = f.encodeText(t).toString();
            expect(
              RegExp('.{4}')
                  .allMatches(hex.substring(1, hex.length - 1))
                  .map((Match m) => m[0]),
              isNot(contains('0000')),
              reason: 'no .notdef in $t',
            );
          }
        });

        test('width', () async {
          if (!fonts) return markTestSkipped('no test fonts');
          PDFDocument doc = await PDFDocument.create();
          Uint8List bytes = testFont(lang.font);
          PDFFont f = await doc.embedFont(bytes, subset: subset);
          if (!lang.complex) {
            expect(<double>[
              for (String t in lang.lines) f.widthOfTextAtSize(t, 16),
            ], theirs[name]);
            return;
          }
          int upem = _upem(bytes);
          for (String t in lang.lines) {
            var (String hex, int advance) = _hbShape(lang.font, t);
            if (!subset) expect(f.encodeText(t).toString(), hex, reason: t);
            expect(
              f.widthOfTextAtSize(t, 16),
              closeTo(advance * 16 / upem, 1e-9),
              reason: t,
            );
          }
        });
      });
    }
  }
}

bool _tool(String name) {
  try {
    return Process.runSync(name, <String>['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
