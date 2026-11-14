import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

// small OFL subsets of Noto Sans (TrueType) and Noto Sans JP (CFF)
Uint8List _font(String name) =>
    File('test/fixtures/fonts/$name').readAsBytesSync();

void main() {
  Uint8List ttf = _font('noto-sans-test.ttf');
  Uint8List otf = _font('noto-sans-jp-test.otf');

  test('measures like pdf-lib + fontkit', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFFont f = await doc.embedFont(ttf);
    // values of pdf-lib 1.17.1 + @pdf-lib/fontkit 1.1.1
    expect(f.name, 'NotoSans-Regular');
    expect(f.widthOfTextAtSize('office fi', 12), 41.484);
    expect(f.encodeText('office fi').toString(), '<005000DF00440046000100DD>');
    expect(f.heightAtSize(10), 13.620000000000001);
    expect(f.heightAtSize(10, descender: false), 10.69);
    expect(f.sizeAtHeight(10), 7.342143906020558);
    List<int> cs = f.getCharacterSet();
    expect(<int>[cs.length, cs.first, cs.last], <int>[207, 32, 65535]);
  });

  test(
    'takes bytes, base64 and data URIs; features turn ligatures off',
    () async {
      PDFDocument doc = await PDFDocument.create();
      PDFFont a = await doc.embedFont(otf.buffer);
      PDFFont b = await doc.embedFont(
        'data:font/otf;base64,${base64.encode(otf)}',
        features: <String, bool>{'liga': false},
      );
      expect(a.name, 'NotoSansJP-Regular');
      // ffi is one glyph with liga, three without
      expect(a.encodeText('ffi').toString().length, 2 + 4);
      expect(b.encodeText('ffi').toString().length, 2 + 12);
      PDFFont std = await doc.embedFont('Helvetica');
      expect(std.name, 'Helvetica');
    },
  );

  test('a broken font file is an error', () async {
    PDFDocument doc = await PDFDocument.create();
    expect(() => doc.embedFont(Uint8List(4)), throwsA(isA<PDFLibError>()));
  });

  test('draws text in a subset font and saves', () async {
    for (bool subset in <bool>[false, true]) {
      PDFDocument doc = await PDFDocument.create();
      PDFFont f = await doc.embedFont(otf, subset: subset, customName: 'My');
      PDFPage page = doc.addPage();
      page.setFont(f);
      page.drawText('日本語のテキスト office', x: 20, y: 700, size: 20);
      page.drawText(
        'long text that wraps in a custom font',
        x: 20,
        y: 600,
        maxWidth: 100,
      );
      Uint8List bytes = await doc.save(useObjectStreams: false);
      String text = latin1.decode(bytes);
      expect(text, contains('/BaseFont/My/'));
      expect(text, contains('/Encoding/Identity-H'));
      // a subset is small; the full font is in the file
      expect(bytes.length < otf.length ~/ 2, subset);
      PDFDocument again = await PDFDocument.load(bytes);
      expect(again.getPageCount(), 1);
    }
  });
}
