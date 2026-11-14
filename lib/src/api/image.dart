part of 'document.dart';

/// An embedded JPEG or PNG image, like pdf-lib's `PDFImage`.
class PDFImage {
  PDFImage._(this.doc, this.ref, this.width, this.height);

  final PDFDocument doc;

  /// The object number of the image, `number << 16 | generation`.
  final int ref;

  /// Size in pixels.
  final int width;
  final int height;

  ({double width, double height}) scale(double factor) =>
      (width: width * factor, height: height * factor);

  /// The largest size that fits in [width] x [height], with the same
  /// aspect ratio.
  ({double width, double height}) scaleToFit(double width, double height) =>
      scale(math.min(width / this.width, height / this.height));

  ({double width, double height}) size() => scale(1);
}

/// pdf-lib's `toUint8Array`: bytes, or a base64 text or `data:` URI.
Uint8List _imageBytes(Object input, String name) => switch (input) {
  Uint8List b => b,
  List<int> b => Uint8List.fromList(b),
  String s => base64Decode(
    s.contains(',') ? s.substring(s.indexOf(',') + 1) : s,
  ),
  _ => throw ArgumentError.value(
    input,
    name,
    'must be bytes or a base64 String',
  ),
};

/// Images, like pdf-lib's `embedJpg` and `embedPng`.
extension PDFDocumentImages on PDFDocument {
  /// Embeds a JPEG. The bytes go into the file as they are.
  Future<PDFImage> embedJpg(Object jpg) async {
    Uint8List bytes = _imageBytes(jpg, 'jpg');
    Int64List out = Int64List(3);
    check(doxPdfEmbedJpg(_handle, bytes.address, bytes.length, out.address));
    return PDFImage._(this, out[0], out[1], out[2]);
  }

  /// Embeds a PNG. A big one is decoded on a native thread.
  Future<PDFImage> embedPng(Object png) async {
    Uint8List bytes = _imageBytes(png, 'png');
    Int64List out = Int64List(3);
    int id = Pending.nextId();
    int status = check(
      doxPdfEmbedPng(
        _handle,
        bytes.address,
        bytes.length,
        out.address,
        Pending.callback,
        id,
      ),
    );
    if (status == statusPending) {
      int png = await Pending.wait(id);
      check(doxPdfPngAdd(_handle, png, out.address));
    }
    return PDFImage._(this, out[0], out[1], out[2]);
  }
}
