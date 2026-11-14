import 'dart:convert';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

/// What we read from [doc], in the shape of tool/crosscheck/inspect.mjs.
Map<String, Object?> describe(PDFDocument doc) {
  List<double> box(PDFBox b) => <double>[b.x, b.y, b.width, b.height];
  return <String, Object?>{
    'pageCount': doc.getPageCount(),
    'pages': <Object?>[
      for (PDFPage p in doc.getPages())
        <String, Object?>{
          'size': <double>[p.getWidth(), p.getHeight()],
          'rotation': p.getRotation().angle,
          'mediaBox': box(p.getMediaBox()),
          'cropBox': box(p.getCropBox()),
          'bleedBox': box(p.getBleedBox()),
          'trimBox': box(p.getTrimBox()),
          'artBox': box(p.getArtBox()),
        },
    ],
    'title': doc.getTitle(),
    'author': doc.getAuthor(),
    'subject': doc.getSubject(),
    'keywords': doc.getKeywords(),
    'creator': doc.getCreator(),
    'producer': doc.getProducer(),
    'creationDate': doc.getCreationDate()?.toUtc().toIso8601String(),
    'modificationDate': doc.getModificationDate()?.toUtc().toIso8601String(),
    'language': doc.getLanguage(),
  };
}

/// A PDF file from object bodies (object i+1 is `objects[i]`) with a
/// correct xref table. For hand-made test files.
Uint8List buildPdf(List<String> objects, {String trailer = '/Root 1 0 R'}) {
  BytesBuilder out = BytesBuilder()..add(latin1.encode('%PDF-1.7\n'));
  List<int> offsets = <int>[];
  for (int i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.add(latin1.encode('${i + 1} 0 obj\n${objects[i]}\nendobj\n'));
  }
  int xref = out.length;
  StringBuffer table = StringBuffer('xref\n0 ${objects.length + 1}\n')
    ..write('0000000000 65535 f \n');
  for (int o in offsets) {
    table.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  table.write(
    'trailer\n<< /Size ${objects.length + 1} $trailer >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  out.add(latin1.encode(table.toString()));
  return out.takeBytes();
}
