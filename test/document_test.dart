import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

void main() {
  test('create, add pages, save and load again', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage a = doc.addPage();
    doc.addPage(PageSizes.Letter);
    doc.insertPage(0, <double>[100, 200]);
    expect(doc.getPageCount(), 3);
    expect(doc.getPage(1), same(a));
    expect(a.getSize(), (width: 595.28, height: 841.89));
    expect(doc.getPage(0).getSize(), (width: 100.0, height: 200.0));
    expect(doc.getPageIndices(), <int>[0, 1, 2]);

    Uint8List bytes = await doc.save();
    expect(String.fromCharCodes(bytes.take(8)), startsWith('%PDF-1.7'));

    PDFDocument again = await PDFDocument.load(bytes);
    expect(again.getPageCount(), 3);
    expect(again.getPage(2).getWidth(), 612);
    expect(again.isEncrypted, isFalse);
  });

  test('save adds a default page', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFDocument again = await PDFDocument.load(await doc.save());
    expect(again.getPageCount(), 1);
    expect(again.getPage(0).getSize(), (width: 595.28, height: 841.89));

    PDFDocument empty = await PDFDocument.create();
    PDFDocument none = await PDFDocument.load(
      await empty.save(addDefaultPage: false),
    );
    expect(none.getPageCount(), 0);
  });

  test('saveAsBase64', () async {
    PDFDocument doc = await PDFDocument.create();
    expect(await doc.saveAsBase64(), startsWith('JVBERi0'));
    expect(
      await doc.saveAsBase64(dataUri: true),
      startsWith('data:application/pdf;base64,JVBERi0'),
    );
  });

  test('both writers give a file that loads', () async {
    for (bool streams in <bool>[true, false]) {
      PDFDocument doc = await PDFDocument.create();
      doc.addPage();
      Uint8List bytes = await doc.save(useObjectStreams: streams);
      String text = String.fromCharCodes(bytes);
      expect(text.contains('/ObjStm'), streams);
      expect((await PDFDocument.load(bytes)).getPageCount(), 1);
    }
  });

  test('removePage and errors', () async {
    PDFDocument doc = await PDFDocument.create();
    expect(
      () => doc.removePage(0),
      throwsA(isA<RemovePageFromEmptyDocumentError>()),
    );
    doc.addPage();
    doc.addPage();
    expect(() => doc.removePage(2), throwsRangeError);
    expect(() => doc.insertPage(5), throwsRangeError);
    expect(() => doc.insertPage(-1), throwsRangeError);
    expect(() => doc.getPage(2), throwsRangeError);
    doc.removePage(0);
    expect(doc.getPageCount(), 1);

    PDFDocument other = await PDFDocument.create();
    expect(
      () => other.addPage(doc.getPage(0)),
      throwsA(isA<ForeignPageError>()),
    );
    expect(() => doc.addPage('A4'), throwsArgumentError);
  });

  test('copyPages and merge', () async {
    PDFDocument a = await PDFDocument.create();
    a.addPage(<double>[100, 100]).setRotation(degrees(90));
    a.addPage(<double>[200, 200]);
    PDFDocument b = await PDFDocument.load(await a.save());

    PDFDocument merged = await PDFDocument.create();
    List<PDFPage> pages = await merged.copyPages(b, <int>[1, 0, 1]);
    expect(merged.getPageCount(), 0);
    for (PDFPage p in pages) {
      merged.addPage(p);
    }
    PDFDocument again = await PDFDocument.load(await merged.save());
    expect(
      <double>[for (PDFPage p in again.getPages()) p.getWidth()],
      <double>[200, 100, 200],
    );
    expect(again.getPage(1).getRotation(), degrees(90));
    expect(() => merged.copyPages(b, <int>[5]), throwsRangeError);

    // a copy from the same document
    List<PDFPage> self = await merged.copyPages(merged, <int>[0]);
    merged.addPage(self.single);
    expect(merged.getPageCount(), 4);
  });

  test('broken input never crashes', () async {
    for (List<int> input in <List<int>>[
      <int>[],
      'hello'.codeUnits,
      '%PDF-1.7\n'.codeUnits,
      List<int>.filled(5000, 0x5b), // [[[[ ...
      '%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'
              'trailer\n<< /Root 1 0 R >>\n%%EOF'
          .codeUnits,
    ]) {
      await expectLater(
        PDFDocument.load(Uint8List.fromList(input)),
        throwsA(isA<PDFLibError>()),
      );
    }
  });

  test('dispose', () async {
    PDFDocument doc = await PDFDocument.create();
    doc.dispose();
    doc.dispose();
    expect(() => doc.getPageCount(), throwsStateError);
  });
}
