import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

void main() {
  test('size', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage();
    page.setSize(300, 400);
    expect(page.getSize(), (width: 300.0, height: 400.0));
    page.setWidth(310);
    expect(page.getWidth(), 310);
    expect(page.getHeight(), 400);
    page.setHeight(410.5);
    expect(page.getSize(), (width: 310.0, height: 410.5));
  });

  test('boxes fall back like pdf-lib', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage(<double>[100, 200]);
    PDFBox media = (x: 0.0, y: 0.0, width: 100.0, height: 200.0);
    expect(page.getCropBox(), media);
    expect(page.getBleedBox(), media);
    page.setCropBox(1, 2, 50, 60);
    PDFBox crop = (x: 1.0, y: 2.0, width: 50.0, height: 60.0);
    expect(page.getCropBox(), crop);
    expect(page.getTrimBox(), crop);
    expect(page.getArtBox(), crop);
    page.setBleedBox(3, 4, 5, 6);
    page.setTrimBox(7, 8, 9, 10);
    page.setArtBox(11, 12, 13, 14);
    page.setMediaBox(-10, -10, 120, 220);
    expect(page.getBleedBox(), (x: 3.0, y: 4.0, width: 5.0, height: 6.0));
    expect(page.getTrimBox(), (x: 7.0, y: 8.0, width: 9.0, height: 10.0));
    expect(page.getArtBox(), (x: 11.0, y: 12.0, width: 13.0, height: 14.0));
    expect(page.getMediaBox(), (
      x: -10.0,
      y: -10.0,
      width: 120.0,
      height: 220.0,
    ));
  });

  test('setSize moves boxes that were the media box', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage(<double>[100, 200]);
    page.setCropBox(0, 0, 100, 200);
    page.setTrimBox(5, 5, 10, 10);
    page.setSize(300, 400);
    expect(page.getCropBox(), (x: 0.0, y: 0.0, width: 300.0, height: 400.0));
    expect(page.getTrimBox(), (x: 5.0, y: 5.0, width: 10.0, height: 10.0));
  });

  test('rotation', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage();
    expect(page.getRotation(), degrees(0));
    page.setRotation(degrees(-90));
    expect(page.getRotation().angle, -90);
    page.setRotation(radians(3.141592653589793));
    expect(page.getRotation().angle, 180);
    expect(() => page.setRotation(degrees(45)), throwsA(isA<PDFLibError>()));
    PDFDocument again = await PDFDocument.load(await doc.save());
    expect(again.getPage(0).getRotation(), degrees(180));
  });

  test('page sizes and helpers', () {
    expect(PageSizes.A4, <double>[595.28, 841.89]);
    expect(PageSizes.$4A0, <double>[4767.87, 6740.79]);
    expect(toDegrees(radians(degreesToRadians(90))), closeTo(90, 1e-9));
    expect(rgb(1, 0, 0.5), const RGB(1, 0, 0.5));
    expect(cmyk(0, 0, 0, 1).type, ColorTypes.cmyk);
    expect(grayscale(0.5).gray, 0.5);
    expect(() => rgb(2, 0, 0), throwsRangeError);
  });
}
