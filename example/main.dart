// Makes hello.pdf: one A4 page with a title, a line of wrapped text, a
// shape, and a small form field.
import 'dart:io';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

Future<void> main() async {
  PDFDocument doc = await PDFDocument.create();
  doc.setTitle('Hello');

  PDFFont bold = await doc.embedFont(StandardFonts.helveticaBold);
  PDFFont regular = await doc.embedFont(StandardFonts.helvetica);
  PDFPage page = doc.addPage(PageSizes.A4);

  page.drawText('Hello, PDF!', x: 50, y: 760, font: bold, size: 30);
  page.drawText(
    'This file was made with dox_pdf_lib. Long text wraps inside maxWidth.',
    x: 50,
    y: 720,
    font: regular,
    size: 12,
    maxWidth: 300,
    lineHeight: 16,
  );
  page.drawRectangle(
    x: 50,
    y: 600,
    width: 200,
    height: 60,
    color: rgb(0.9, 0.95, 1),
    borderColor: rgb(0.2, 0.4, 0.8),
    borderWidth: 1,
  );

  PDFTextField name = doc.getForm().createTextField('name');
  name.setText('Your name');
  name.addToPage(page, x: 50, y: 540, width: 200, height: 24);

  File('hello.pdf').writeAsBytesSync(await doc.save());
  print('Wrote hello.pdf');
}
