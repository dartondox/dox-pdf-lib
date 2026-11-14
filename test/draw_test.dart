import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

final List<int> _crcTable = List<int>.generate(256, (int n) {
  int c = n;
  for (int k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc(List<int> data) {
  int c = 0xffffffff;
  for (int b in data) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}

/// An RGBA PNG with stored (not compressed) zlib blocks, so a big file is
/// easy to make.
Uint8List _png(int width, int height, int Function(int x, int y) pixel) {
  BytesBuilder raw = BytesBuilder();
  for (int y = 0; y < height; y++) {
    raw.addByte(0); // filter: none
    for (int x = 0; x < width; x++) {
      int p = pixel(x, y);
      raw.add(<int>[p >> 24 & 0xff, p >> 16 & 0xff, p >> 8 & 0xff, p & 0xff]);
    }
  }
  Uint8List data = raw.takeBytes();
  BytesBuilder z = BytesBuilder()..add(<int>[0x78, 0x01]);
  for (int i = 0; i < data.length; i += 65535) {
    int n = (data.length - i).clamp(0, 65535);
    z
      ..addByte(i + n >= data.length ? 1 : 0)
      ..add(<int>[n & 0xff, n >> 8, ~n & 0xff, (~n >> 8) & 0xff])
      ..add(Uint8List.sublistView(data, i, i + n));
  }
  int a = 1, b = 0;
  for (int v in data) {
    a = (a + v) % 65521;
    b = (b + a) % 65521;
  }
  z.add(<int>[b >> 8, b & 0xff, a >> 8, a & 0xff]);
  BytesBuilder out = BytesBuilder()
    ..add(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  void chunk(String type, List<int> body) {
    List<int> typed = <int>[...type.codeUnits, ...body];
    out
      ..add((ByteData(4)..setUint32(0, body.length)).buffer.asUint8List())
      ..add(typed)
      ..add((ByteData(4)..setUint32(0, _crc(typed))).buffer.asUint8List());
  }

  ByteData header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', z.takeBytes());
  chunk('IEND', const <int>[]);
  return out.takeBytes();
}

void main() {
  test('standard font metrics', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFFont helvetica = await doc.embedFont(StandardFonts.helvetica);
    expect(helvetica.name, 'Helvetica');
    // values from pdf-lib 1.17.1
    expect(helvetica.widthOfTextAtSize('Hello', 24), 54.672000000000004);
    expect(helvetica.heightAtSize(12.5), 11.5625);
    expect(helvetica.heightAtSize(12.5, descender: false), 8.975);
    expect(helvetica.sizeAtHeight(20), 21.62162162162162);
    expect(helvetica.getCharacterSet().length, 218);
    expect(helvetica.encodeText('Hi').toString(), '<4869>');
    PDFFont custom = doc.embedStandardFont(StandardFonts.courier, 'MyCourier');
    expect(custom.name, 'Courier');
    // a custom name that is not ASCII is fine (UTF-8, escaped in the name)
    PDFFont unicode = doc.embedStandardFont(StandardFonts.courier, 'Schrift ü');
    doc.addPage().drawText('x', font: unicode);
    PDFDocument again = await PDFDocument.load(await doc.save());
    expect(again.getPageCount(), 1);
  });

  test('text a font can not encode throws like pdf-lib', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFFont f = doc.embedStandardFont(StandardFonts.helvetica);
    Matcher error = throwsA(
      isA<PDFLibError>().having(
        (PDFLibError e) => e.message,
        'message',
        'WinAnsi cannot encode "世" (0x4e16)',
      ),
    );
    expect(() => f.widthOfTextAtSize('a世', 12), error);
    expect(() => doc.addPage().drawText('a世'), error);
    expect(() => doc.embedFont(Uint8List(4)), throwsA(isA<UnsupportedError>()));
  });

  test('every draw call and a save and load round trip', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage(<double>[300, 300]);
    PDFImage png = await doc.embedPng(_fixture('rgba-interlaced.png'));
    PDFImage jpg = await doc.embedJpg(_fixture('rgb.jpg'));
    page
      ..drawText('Hello', x: 10, y: 10, opacity: 0.5)
      ..drawText('wrap me please', maxWidth: 30, wordBreaks: <String>[' '])
      ..drawRectangle(borderColor: rgb(1, 0, 0), borderWidth: 2)
      ..drawSquare(size: 20, color: cmyk(0, 0, 0, 1))
      ..drawEllipse(rotate: degrees(10))
      ..drawCircle(size: 5, borderColor: grayscale(0.2))
      ..drawLine(start: (x: 0, y: 0), end: (x: 100, y: 100), opacity: 0.4)
      ..drawSvgPath('M 0 0 L 10 10 A 5 5 0 0 1 20 20 Z', scale: 2)
      ..drawImage(png, x: 50, y: 50)
      ..drawImage(jpg, width: 10, height: 10, blendMode: BlendMode.screen)
      ..pushOperators(<PDFOperator>[pushGraphicsState(), popGraphicsState()])
      ..translateContent(5, 5)
      ..scaleContent(0.5, 0.5)
      ..resetPosition()
      ..drawText('after reset');
    page.scale(2, 2);
    expect(page.getSize(), (width: 600.0, height: 600.0));

    PDFDocument again = await PDFDocument.load(await doc.save());
    PDFPage loaded = again.getPage(0);
    // drawing on a loaded page wraps its old content
    loaded.drawText('on a loaded page', x: 20, y: 20);
    PDFDocument third = await PDFDocument.load(await again.save());
    expect(third.getPageCount(), 1);
  });

  test('page position and text state', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage();
    expect(page.getPosition(), (x: 0.0, y: 0.0));
    page
      ..moveTo(10, 20)
      ..moveUp(5)
      ..moveRight(3)
      ..moveDown(1)
      ..moveLeft(2);
    expect(page.getX(), 11);
    expect(page.getY(), 24);
    page.resetPosition();
    expect(page.getPosition(), (x: 0.0, y: 0.0));
  });

  test('options are checked like pdf-lib', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage();
    expect(() => page.drawRectangle(opacity: 2), throwsRangeError);
    expect(
      () => page.drawText('a', maxWidth: 10, wordBreaks: <String>['\n']),
      throwsArgumentError,
    );
    PDFDocument other = await PDFDocument.create();
    PDFFont foreign = other.embedStandardFont(StandardFonts.courier);
    expect(() => page.drawText('a', font: foreign), throwsArgumentError);
    expect(() => page.setFont(foreign), throwsArgumentError);
    // the page font did not change, so drawing still works
    page.drawText('a');
    PDFImage image = await other.embedJpg(_fixture('rgb.jpg'));
    expect(() => page.drawImage(image), throwsArgumentError);
  });

  test('images: size, errors, and a big PNG on a native thread', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFImage jpg = await doc.embedJpg(_fixture('cmyk.jpg'));
    expect((jpg.width, jpg.height), (40, 30));
    expect(jpg.scale(0.5), (width: 20.0, height: 15.0));
    expect(jpg.scaleToFit(80, 30), (width: 40.0, height: 30.0));
    expect(jpg.size(), (width: 40.0, height: 30.0));
    for (String f in <String>[
      'rgb16.png',
      'gray16.png',
      'gray1.png',
      'palette-trns.png',
    ]) {
      PDFImage img = await doc.embedPng(_fixture(f));
      expect((img.width, img.height), (40, 30), reason: f);
    }
    expect(
      () => doc.embedJpg(Uint8List.fromList(<int>[1, 2, 3])),
      throwsA(isA<PDFLibError>()),
    );
    expect(
      () => doc.embedPng(Uint8List.fromList(<int>[1, 2, 3])),
      throwsA(isA<PDFLibError>()),
    );
    Uint8List big = _png(600, 600, (int x, int y) => x << 24 | y << 8 | 0xff);
    expect(big.length, greaterThan(1 << 20));
    PDFImage image = await doc.embedPng(big);
    expect((image.width, image.height), (600, 600));
    // base64 input, like pdf-lib
    PDFImage small = await doc.embedPng(
      'data:image/png;base64,${base64Of(_fixture('gray1.png'))}',
    );
    expect(small.width, 40);
    doc.addPage().drawImage(image);
    expect(await doc.save(), isNotEmpty);
  });

  test('an SVG path with missing numbers throws', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage();
    for (String path in <String>['M 1 2 L', 'M', 'M1E-3 2', 'M1.2.3.4']) {
      expect(
        () => page.drawSvgPath(path),
        throwsA(isA<PDFLibError>()),
        reason: path,
      );
    }
    page.drawSvgPath('M1e-3 2 L 3 4');
  });

  test('a small PNG file of a big image is embedded', () async {
    // 1-bit gray, 2000 x 2000: a small file, 16 MB as RGBA, so it is
    // decoded on a native thread
    PDFDocument doc = await PDFDocument.create();
    PDFImage image = await doc.embedPng(_fixture('big-gray1.png'));
    expect((image.width, image.height), (2000, 2000));
  });

  test('operators write numbers like pdf-lib', () {
    expect(numberToString(1.0), '1');
    expect(numberToString(-0.0), '0');
    expect(numberToString(1.5e-7), '0.00000015');
    expect(numberToString(1e21), '1000000000000000000000');
    expect(setDashPattern(<num>[3, 1.5], 0).toString(), '[3 1.5] 0 d');
    expect(setFontAndSize('F 1', 12).toString(), '/F#201 12 Tf');
    expect(setFillingColor(rgb(1, 0.5, 0)).toString(), '1 0.5 0 rg');
    expect(showText(const PDFHexString('41')).toString(), '<41> Tj');
  });
}

String base64Of(List<int> bytes) => base64Encode(bytes);
