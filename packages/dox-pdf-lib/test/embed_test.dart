import 'dart:convert';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

import 'support.dart';

/// One page of 200 x 100 with a content stream and a font from the parent
/// page node (inherited resources).
Uint8List _source() => buildPdf(<String>[
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 100] '
      '/Resources << /Font << /F1 5 0 R >> >> >>',
  '<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>',
  '<< /Length 22 >>\nstream\n0 0 50 50 re f BT ET\nendstream',
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
]);

void main() {
  test('embedPdf gives the page size, scale and size', () async {
    PDFDocument doc = await PDFDocument.create();
    List<PDFEmbeddedPage> pages = await doc.embedPdf(_source());
    PDFEmbeddedPage p = pages.single;
    expect(p.width, 200);
    expect(p.height, 100);
    expect(p.size(), (width: 200.0, height: 100.0));
    expect(p.scale(0.5), (width: 100.0, height: 50.0));
  });

  test('embedPdf takes base64 and a data URI', () async {
    PDFDocument doc = await PDFDocument.create();
    String b64 = base64Encode(_source());
    expect((await doc.embedPdf(b64)).single.width, 200);
    String uri = 'data:application/pdf;base64,$b64';
    expect((await doc.embedPdf(uri)).single.height, 100);
  });

  test('a bounding box or matrix that is not finite throws', () async {
    PDFDocument src = await PDFDocument.load(_source());
    PDFDocument doc = await PDFDocument.create();
    expect(
      () => doc.embedPage(src.getPage(0), (
        left: 0,
        bottom: double.nan,
        right: 10,
        top: 10,
      )),
      throwsArgumentError,
    );
    expect(
      () => doc.embedPage(src.getPage(0), null, <double>[
        1,
        0,
        0,
        1,
        double.infinity,
        0,
      ]),
      throwsArgumentError,
    );
  });

  test('the same page twice gives the same XObject', () async {
    PDFDocument src = await PDFDocument.load(_source());
    PDFDocument doc = await PDFDocument.create();
    List<PDFEmbeddedPage> a = await doc.embedPages(<PDFPage>[
      src.getPage(0),
      src.getPage(0),
    ]);
    PDFEmbeddedPage b = await doc.embedPage(src.getPage(0));
    expect(a[0].ref, a[1].ref);
    expect(b.ref, a[0].ref);
    PDFEmbeddedPage clipped = await doc.embedPage(src.getPage(0), (
      left: 10,
      bottom: 10,
      right: 60,
      top: 40,
    ));
    expect(clipped.ref, isNot(a[0].ref));
    expect(clipped.size(), (width: 50.0, height: 30.0));
  });

  test('drawPage writes a file that loads again', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFEmbeddedPage e = (await doc.embedPdf(_source())).single;
    PDFPage page = doc.addPage(<double>[400, 400]);
    page.drawPage(
      e,
      x: 50,
      y: 60,
      width: 100,
      rotate: degrees(30),
      xSkew: degrees(5),
      opacity: 0.5,
      blendMode: BlendMode.multiply,
    );
    page.drawPage(e, xScale: 0.25, yScale: 0.25);
    PDFDocument again = await PDFDocument.load(await doc.save());
    expect(again.getPageCount(), 1);
  });

  test('a page of the same document can be embedded', () async {
    PDFDocument doc = await PDFDocument.load(_source());
    PDFEmbeddedPage e = await doc.embedPage(doc.getPage(0));
    doc.addPage().drawPage(e);
    expect((await doc.save()).length, greaterThan(0));
  });

  test('errors like pdf-lib', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFDocument blank = await PDFDocument.create();
    blank.addPage();
    expect(
      () => doc.embedPage(blank.getPage(0)),
      throwsA(isA<MissingPageContentsEmbeddingError>()),
    );
    PDFDocument src = await PDFDocument.load(_source());
    expect(
      () => doc.embedPages(<PDFPage>[src.getPage(0), blank.getPage(0)]),
      throwsA(isA<PageEmbeddingMismatchedContextError>()),
    );
    PDFEmbeddedPage e = await src.embedPage(src.getPage(0));
    expect(() => doc.addPage().drawPage(e), throwsArgumentError);
    expect(
      () => src.getPage(0).drawPage(e, opacity: 2),
      throwsA(isA<RangeError>()),
    );
    expect(await doc.embedPages(<PDFPage>[]), isEmpty);
  });
}
