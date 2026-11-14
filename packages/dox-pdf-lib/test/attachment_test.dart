import 'dart:convert';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

void main() {
  test('attach and read back after save and load', () async {
    PDFDocument doc = await PDFDocument.create();
    await doc.attach(
      Uint8List.fromList(utf8.encode('hello')),
      'hello.txt',
      mimeType: 'text/plain',
      description: 'Grüße',
      creationDate: DateTime.utc(2020, 1, 2, 3, 4, 5),
      modificationDate: DateTime.utc(2021, 1, 2, 3, 4, 5),
      afRelationship: AFRelationship.data,
    );
    await doc.attach(base64Encode(<int>[1, 2, 3]), '世界.bin');
    await doc.attach('data:text/plain;base64,${base64Encode(<int>[9])}', 'u');
    PDFDocument again = await PDFDocument.load(await doc.save());
    List<PDFAttachment> files = again.getAttachments();
    // sorted by name, as the PDF spec asks
    expect(files.map((PDFAttachment f) => f.name), <String>[
      'hello.txt',
      'u',
      '世界.bin',
    ]);
    PDFAttachment a = files[0];
    expect(utf8.decode(a.data), 'hello');
    expect(a.mimeType, 'text/plain');
    expect(a.description, 'Grüße');
    expect(a.creationDate, DateTime.utc(2020, 1, 2, 3, 4, 5));
    expect(a.modificationDate, DateTime.utc(2021, 1, 2, 3, 4, 5));
    expect(a.afRelationship, 'Data');
    expect(files[2].data, <int>[1, 2, 3]);
    expect(files[2].mimeType, isNull);
    expect(files[1].data, <int>[9]);
  });

  test('a big file is compressed on a native thread', () async {
    PDFDocument doc = await PDFDocument.create();
    Uint8List big = Uint8List(3 << 20)..fillRange(0, 1000, 7);
    await doc.attach(big, 'big.bin');
    PDFDocument again = await PDFDocument.load(await doc.save());
    expect(again.getAttachments().single.data, big);
  });

  test('no attachments', () async {
    PDFDocument doc = await PDFDocument.create();
    expect(doc.getAttachments(), isEmpty);
  });
}
