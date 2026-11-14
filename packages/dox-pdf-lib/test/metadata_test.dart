import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

void main() {
  test('create sets producer, creator and dates', () async {
    DateTime before = DateTime.now().subtract(const Duration(seconds: 2));
    PDFDocument doc = await PDFDocument.create();
    String producer = 'dox_pdf_lib (https://github.com/dartondox/dox-pdf-lib)';
    expect(doc.getProducer(), producer);
    expect(doc.getCreator(), producer);
    expect(doc.getCreationDate()!.isAfter(before), isTrue);
    expect(doc.getModificationDate(), doc.getCreationDate());
    expect(doc.getTitle(), isNull);

    PDFDocument plain = await PDFDocument.create(updateMetadata: false);
    expect(plain.getProducer(), isNull);
  });

  test('set and read again after save', () async {
    PDFDocument doc = await PDFDocument.create();
    DateTime date = DateTime.utc(2020, 2, 3, 4, 5, 6);
    doc
      ..setTitle('Grüße 世界 😀', showInWindowTitleBar: true)
      ..setAuthor('Ann')
      ..setSubject('Sub')
      ..setKeywords(<String>['a', 'b c'])
      ..setCreator('me')
      ..setProducer('you')
      ..setLanguage('en-US')
      ..setCreationDate(date)
      ..setModificationDate(date);
    PDFDocument again = await PDFDocument.load(
      await doc.save(),
      updateMetadata: false,
    );
    expect(again.getTitle(), 'Grüße 世界 😀');
    expect(again.getAuthor(), 'Ann');
    expect(again.getSubject(), 'Sub');
    expect(again.getKeywords(), 'a b c');
    expect(again.getCreator(), 'me');
    expect(again.getProducer(), 'you');
    expect(again.getLanguage(), 'en-US');
    expect(again.getCreationDate(), date);
    expect(again.getModificationDate(), date);

    // load with updateMetadata keeps creator and creation date
    PDFDocument updated = await PDFDocument.load(await doc.save());
    expect(updated.getCreator(), 'me');
    expect(updated.getCreationDate(), date);
    expect(updated.getProducer(), startsWith('dox_pdf_lib'));
    expect(updated.getModificationDate()!.year, DateTime.now().toUtc().year);
  });
}
