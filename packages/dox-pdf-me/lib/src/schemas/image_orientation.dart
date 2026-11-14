import 'dart:typed_data';

/// The EXIF orientation of a JPEG or PNG image, like pdfme's
/// `orientation.ts`.
///
/// pdfme turns the pixels and encodes the image again. This port keeps
/// the image as it is and turns it with a transform when it draws it. The
/// page looks the same.
class ImageOrientation {
  const ImageOrientation._();

  /// The orientation (1 to 8) of [bytes], or 1 when there is none.
  static int read(Uint8List bytes) {
    try {
      if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8) {
        return _jpeg(bytes) ?? 1;
      }
      if (bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50) {
        return _png(bytes) ?? 1;
      }
    } on RangeError {
      return 1;
    }
    return 1;
  }

  /// True when the image is turned by 90 degrees (orientations 5 to 8):
  /// its width and height swap.
  static bool swaps(int orientation) => orientation >= 5;

  /// The matrix `[a, b, c, d, e, f]` that maps the unit square of the
  /// stored image to the unit square of the image as it is shown (PDF
  /// image space: y up).
  static List<double> matrix(int orientation) => switch (orientation) {
    2 => const <double>[-1, 0, 0, 1, 1, 0],
    3 => const <double>[-1, 0, 0, -1, 1, 1],
    4 => const <double>[1, 0, 0, -1, 0, 1],
    5 => const <double>[0, -1, -1, 0, 1, 1],
    6 => const <double>[0, -1, 1, 0, 0, 1],
    7 => const <double>[0, 1, 1, 0, 0, 0],
    8 => const <double>[0, 1, -1, 0, 1, 0],
    _ => const <double>[1, 0, 0, 1, 0, 0],
  };

  /// JPEG: the first `APP1` `Exif` segment with an orientation.
  static int? _jpeg(Uint8List bytes) {
    int pos = 2;
    while (pos < bytes.length) {
      if (bytes[pos] != 0xff) return null;
      while (pos < bytes.length && bytes[pos] == 0xff) {
        pos++;
      }
      if (pos >= bytes.length) return null;
      int marker = bytes[pos++];
      // markers with no length: TEM, RST0-7, SOI
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) continue;
      if (marker == 0xda || marker == 0xd9) return null;
      if (pos + 2 > bytes.length) return null;
      int size = bytes[pos] << 8 | bytes[pos + 1];
      if (size < 2 || pos + size > bytes.length) return null;
      if (marker == 0xe1 && size >= 8 && _isExif(bytes, pos + 2)) {
        int? o = _tiff(Uint8List.sublistView(bytes, pos + 8, pos + size));
        if (o != null) return o;
      }
      pos += size;
    }
    return null;
  }

  static bool _isExif(Uint8List b, int p) =>
      b[p] == 0x45 &&
      b[p + 1] == 0x78 &&
      b[p + 2] == 0x69 &&
      b[p + 3] == 0x66 &&
      b[p + 4] == 0 &&
      b[p + 5] == 0;

  /// PNG: the `eXIf` chunk (a TIFF block).
  static int? _png(Uint8List bytes) {
    ByteData view = ByteData.sublistView(bytes);
    int pos = 8;
    while (pos + 12 <= bytes.length) {
      int length = view.getUint32(pos);
      if (pos + 12 + length > bytes.length) return null;
      String type = String.fromCharCodes(bytes, pos + 4, pos + 8);
      if (type == 'eXIf') {
        return _tiff(Uint8List.sublistView(bytes, pos + 8, pos + 8 + length));
      }
      if (type == 'IEND') return null;
      pos += 12 + length;
    }
    return null;
  }

  /// The orientation tag (0x0112) of the first IFD of a TIFF block.
  static int? _tiff(Uint8List tiff) {
    if (tiff.length < 8) return null;
    bool le = tiff[0] == 0x49 && tiff[1] == 0x49;
    if (!le && !(tiff[0] == 0x4d && tiff[1] == 0x4d)) return null;
    Endian e = le ? Endian.little : Endian.big;
    ByteData view = ByteData.sublistView(tiff);
    if (view.getUint16(2, e) != 42) return null;
    int ifd = view.getUint32(4, e);
    if (ifd + 2 > tiff.length) return null;
    int n = view.getUint16(ifd, e);
    for (int i = 0; i < n; i++) {
      int entry = ifd + 2 + i * 12;
      if (entry + 12 > tiff.length) return null;
      if (view.getUint16(entry, e) != 0x0112) continue;
      if (view.getUint16(entry + 2, e) != 3) return null;
      if (view.getUint32(entry + 4, e) != 1) return null;
      int value = view.getUint16(entry + 8, e);
      return value >= 1 && value <= 8 ? value : null;
    }
    return null;
  }
}
