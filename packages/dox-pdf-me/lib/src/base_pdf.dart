import 'dart:convert';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import 'constants.dart';
import 'options.dart';
import 'template.dart';

/// The base pages of a template: blank pages, or the pages of the base PDF
/// (embedded once, drawn on every copy).
class BasePages {
  BasePages._(this.doc, this.length, this._blankSize, this._embedded);

  static Future<BasePages> create(
    PDFDocument doc,
    Template template,
    GenerateOptions options,
  ) async {
    if (template.isBlank) {
      Map<dynamic, dynamic> b = template.basePdf! as Map<dynamic, dynamic>;
      return BasePages._(doc, template.schemas.length, <double>[
        mm2pt(b['width'] as num),
        mm2pt(b['height'] as num),
      ], const <PDFEmbeddedPage>[]);
    }
    PDFDocument source = await _load(_bytes(template.basePdf));
    try {
      List<PDFPage> pages = source.getPages();
      List<PageBoundingBox> boxes = <PageBoundingBox>[
        for (PDFPage p in pages) _boundingBox(p.getCropBox()),
      ];
      List<PDFEmbeddedPage> embedded = await doc.embedPages(pages, boxes);
      return BasePages._(doc, pages.length, null, embedded);
    } finally {
      source.dispose();
    }
  }

  final PDFDocument doc;

  /// The number of pages of one copy.
  final int length;

  final List<double>? _blankSize;
  final List<PDFEmbeddedPage> _embedded;

  /// Adds page [index] of one copy to the end of the document.
  PDFPage insert(int index) {
    List<double>? blank = _blankSize;
    if (blank != null) return doc.addPage(blank);
    PDFEmbeddedPage base = _embedded[index];
    double w = base.width;
    double h = base.height;
    PDFPage page = doc.addPage(<double>[w, h]);
    page.drawPage(base);
    page
      ..setMediaBox(0, 0, w, h)
      ..setBleedBox(0, 0, w, h)
      ..setTrimBox(0, 0, w, h);
    return page;
  }

  static PageBoundingBox _boundingBox(PDFBox b) =>
      (left: b.x, bottom: b.y, right: b.x + b.width, top: b.y + b.height);

  /// Loads the base PDF. Like pdfme, a file that opens with an empty
  /// password (owner password only) works.
  static Future<PDFDocument> _load(Uint8List bytes) async {
    try {
      return await PDFDocument.load(bytes);
    } on EncryptedPDFError {
      try {
        return await PDFDocument.load(bytes, ignoreEncryption: true);
      } on PDFLibError {
        throw ArgumentError(
          '[@pdfme/generator] basePdf is encrypted and requires a valid '
          'password. Pass options.basePdfPassword to generate().',
        );
      }
    }
  }

  static Uint8List _bytes(Object? basePdf) => switch (basePdf) {
    Uint8List b => b,
    ByteBuffer b => b.asUint8List(),
    List<int> b => Uint8List.fromList(b),
    String s => base64.decode(
      s.startsWith('data:') ? s.substring(s.indexOf(',') + 1) : s.trim(),
    ),
    _ => throw ArgumentError.value(
      basePdf,
      'basePdf',
      'must be a blank page map {width, height, padding}, PDF bytes or base64',
    ),
  };
}
