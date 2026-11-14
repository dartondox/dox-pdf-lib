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

class MissingPageContentsEmbeddingError extends PDFLibError {
  MissingPageContentsEmbeddingError()
    : super("Can't embed page with missing Contents");
}

class PageEmbeddingMismatchedContextError extends PDFLibError {
  PageEmbeddingMismatchedContextError()
    : super(
        'Found mismatched contexts while embedding pages. All pages in the '
        'array passed to `PDFDocument.embedPages()` must be from the same '
        'document.',
      );
}

// ---------------------------------------------------------------- forms

class NoSuchFieldError extends PDFLibError {
  NoSuchFieldError(String name)
    : super('PDFDocument has no form field with the name "$name"');
}

class UnexpectedFieldTypeError extends PDFLibError {
  UnexpectedFieldTypeError(String name, String expected, String actual)
    : super(
        'Expected field "$name" to be of type $expected, but it is actually '
        'of type $actual',
      );
}

/// The form errors that come from the native core, with their message.
class FieldAlreadyExistsError extends PDFLibError {
  FieldAlreadyExistsError(super.message);
}

class InvalidFieldNamePartError extends PDFLibError {
  InvalidFieldNamePartError(super.message);
}

class RichTextFieldReadError extends PDFLibError {
  RichTextFieldReadError(super.message);
}

class CombedTextLayoutError extends PDFLibError {
  CombedTextLayoutError(super.message);
}

class ExceededMaxLengthError extends PDFLibError {
  ExceededMaxLengthError(super.message);
}

class InvalidMaxLengthError extends PDFLibError {
  InvalidMaxLengthError(super.message);
}

class MissingDAEntryError extends PDFLibError {
  MissingDAEntryError(super.message);
}

class MissingTfOperatorError extends PDFLibError {
  MissingTfOperatorError(super.message);
}

class InvalidAcroFieldValueError extends PDFLibError {
  InvalidAcroFieldValueError(super.message);
}

class MultiSelectValueError extends PDFLibError {
  MultiSelectValueError(super.message);
}

/// A form error from the native core: `<class name>\0<message>`.
PDFLibError formError(String raw) {
  int cut = raw.indexOf('\u0000');
  String name = cut < 0 ? '' : raw.substring(0, cut);
  String message = raw.substring(cut + 1);
  return switch (name) {
    'FieldAlreadyExistsError' => FieldAlreadyExistsError(message),
    'InvalidFieldNamePartError' => InvalidFieldNamePartError(message),
    'RichTextFieldReadError' => RichTextFieldReadError(message),
    'CombedTextLayoutError' => CombedTextLayoutError(message),
    'ExceededMaxLengthError' => ExceededMaxLengthError(message),
    'InvalidMaxLengthError' => InvalidMaxLengthError(message),
    'MissingDAEntryError' => MissingDAEntryError(message),
    'MissingTfOperatorError' => MissingTfOperatorError(message),
    'InvalidAcroFieldValueError' => InvalidAcroFieldValueError(message),
    'MultiSelectValueError' => MultiSelectValueError(message),
    _ => PDFLibError(message),
  };
}
