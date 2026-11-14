part of 'document.dart';

/// pdf-lib's `AFRelationship` (PDF/A-3 associated files).
enum AFRelationship {
  source('Source'),
  data('Data'),
  alternative('Alternative'),
  supplement('Supplement'),
  encryptedPayload('EncryptedPayload'),
  // same value as encryptedPayload: pdf-lib has it so
  formData('EncryptedPayload'),
  schema('Schema'),
  unspecified('Unspecified');

  const AFRelationship(this.value);

  /// The PDF name.
  final String value;
}

/// A file attached to a document, from [PDFDocumentAttachments.getAttachments].
class PDFAttachment {
  PDFAttachment._({
    required this.name,
    required this.data,
    this.mimeType,
    this.description,
    this.creationDate,
    this.modificationDate,
    this.afRelationship,
  });

  final String name;
  final Uint8List data;
  final String? mimeType;
  final String? description;
  final DateTime? creationDate;
  final DateTime? modificationDate;

  /// The PDF name, eg. `Data`. See [AFRelationship].
  final String? afRelationship;
}

/// pdf-lib's `decodeFromBase64DataUri` / base64 input.
Uint8List _bytesOf(Object input, String name) => switch (input) {
  Uint8List() => input,
  String() => base64Decode(
    input.startsWith('data:') ? input.substring(input.indexOf(',') + 1) : input,
  ),
  _ => throw ArgumentError.value(input, name, 'must be a Uint8List or base64'),
};

DateTime? _tryParseDate(String? text) {
  if (text == null) return null;
  try {
    return _parseDate(text);
  } on InvalidPDFDateStringError {
    return null;
  }
}

/// File attachments, like pdf-lib.
extension PDFDocumentAttachments on PDFDocument {
  /// Attaches a file: bytes, or a base64 string or data URI.
  Future<void> attach(
    Object attachment,
    String name, {
    String? mimeType,
    String? description,
    DateTime? creationDate,
    DateTime? modificationDate,
    AFRelationship? afRelationship,
  }) async {
    Uint8List data = _bytesOf(attachment, 'attachment');
    List<String?> fields = <String?>[
      name,
      mimeType,
      description,
      creationDate == null ? null : _formatDate(creationDate),
      modificationDate == null ? null : _formatDate(modificationDate),
      afRelationship?.value,
    ];
    BytesBuilder texts = BytesBuilder(copy: false);
    Int64List lengths = Int64List(fields.length);
    for (int i = 0; i < fields.length; i++) {
      String? f = fields[i];
      if (f == null) {
        lengths[i] = -1;
        continue;
      }
      Uint8List b = utf8.encode(f);
      lengths[i] = b.length;
      texts.add(b);
    }
    Uint8List all = texts.takeBytes();
    int id = Pending.nextId();
    int status = check(
      doxPdfAttach(
        _handle,
        data.address,
        data.length,
        all.address,
        lengths.address,
        Pending.callback,
        id,
      ),
    );
    if (status == statusPending) await Pending.wait(id);
  }

  /// The attached files. pdf-lib has no getter; this is an extra.
  List<PDFAttachment> getAttachments() {
    Int64List out = Int64List(1);
    check(doxPdfGetAttachments(_handle, out.address));
    Uint8List bytes = takeBytes(out[0]);
    ByteData view = ByteData.sublistView(bytes);
    int at = 0;
    // views into the native buffer; file bytes are copied out (below), so
    // one small file does not keep the whole buffer alive
    Uint8List? next() {
      int len = view.getUint32(at, Endian.little);
      at += 4;
      if (len == 0xFFFFFFFF) return null;
      Uint8List v = Uint8List.sublistView(bytes, at, at + len);
      at += len;
      return v;
    }

    String? text() {
      Uint8List? b = next();
      return b == null ? null : utf8.decode(b);
    }

    int count = view.getUint32(0, Endian.little);
    at = 4;
    return <PDFAttachment>[
      for (int i = 0; i < count; i++)
        PDFAttachment._(
          name: text()!,
          data: Uint8List.fromList(next()!),
          mimeType: text(),
          description: text(),
          creationDate: _tryParseDate(text()),
          modificationDate: _tryParseDate(text()),
          afRelationship: text(),
        ),
    ];
  }
}
