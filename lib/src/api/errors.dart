/// Base of the errors of this package. Names follow pdf-lib.
class PDFLibError implements Exception {
  PDFLibError(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

class EncryptedPDFError extends PDFLibError {
  EncryptedPDFError()
    : super(
        'Input document to `PDFDocument.load` is encrypted. You can use '
        '`PDFDocument.load(..., ignoreEncryption: true)` if you wish to load '
        'the document anyways.',
      );
}

class RemovePageFromEmptyDocumentError extends PDFLibError {
  RemovePageFromEmptyDocumentError()
    : super(
        'PDFDocument has no pages so `PDFDocument.removePage` cannot be '
        'called',
      );
}

class ForeignPageError extends PDFLibError {
  ForeignPageError()
    : super(
        'A `page` passed to `PDFDocument.addPage` or `PDFDocument.insertPage` '
        'was from a different (foreign) PDF document. If you want to copy '
        'pages from one PDFDocument to another, you must use '
        '`PDFDocument.copyPages(...)` to copy the pages before adding or '
        'inserting them.',
      );
}

/// The input is not a PDF that can be read.
class PDFParsingError extends PDFLibError {
  PDFParsingError(super.message);
}

class InvalidPDFDateStringError extends PDFLibError {
  InvalidPDFDateStringError(String value)
    : super('Invalid PDF date string: $value');
}
