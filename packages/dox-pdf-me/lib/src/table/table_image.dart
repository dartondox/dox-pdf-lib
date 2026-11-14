import 'dart:convert';
import 'dart:typed_data';

import '../schemas/image_orientation.dart';

/// pdfme's `DEFAULT_TABLE_IMAGE_HEIGHT` (mm).
const double defaultTableImageHeight = 20;

/// pdfme's `TABLE_IMAGE_AUTO_SAFETY_MARGIN` (mm).
const double tableImageAutoSafetyMargin = 1;

final RegExp _dataUrl = RegExp(
  r'^data:image\/(png|jpe?g);base64,',
  caseSensitive: false,
);

/// pdfme's `resolveImageDimension`: the pixel size of a PNG or JPEG data
/// URL as it is shown (EXIF turns by 90 degrees swap it), or null for
/// other values and for broken images.
({double width, double height})? tableImageSize(String value) {
  if (!_dataUrl.hasMatch(value)) return null;
  try {
    Uint8List bytes = base64.decode(
      value.substring(value.indexOf(';base64,') + 8),
    );
    ({double width, double height}) size = _imageSize(bytes);
    return ImageOrientation.swaps(ImageOrientation.read(bytes))
        ? (width: size.height, height: size.width)
        : size;
  } on Object {
    return null;
  }
}

/// pdfme's `resolveTableImageContentHeight` (mm). `fixed` (the default)
/// is `imageHeight` (20 when not set), also for an empty or broken image,
/// so the rows of the column stay the same. `auto` is the image height at
/// the cell width, 0 for an empty or broken image.
double tableImageContentHeight({
  required String value,
  required String? mode,
  required double? imageHeight,
  required double contentWidth,
}) {
  bool auto = mode == 'auto';
  double fixed = imageHeight != null && imageHeight.isFinite && imageHeight > 0
      ? imageHeight
      : defaultTableImageHeight;
  if (value.isEmpty) return auto ? 0 : fixed;
  ({double width, double height})? size = tableImageSize(value);
  if (size == null || size.width <= 0) return auto ? 0 : fixed;
  return auto ? contentWidth * size.height / size.width : fixed;
}

/// pdfme's `getTableImageObjectPosition`.
String tableImageObjectPosition(String? alignment, String? verticalAlignment) {
  String h = alignment == 'center' || alignment == 'right'
      ? alignment!
      : 'left';
  String v = verticalAlignment == 'top' || verticalAlignment == 'bottom'
      ? verticalAlignment!
      : 'center';
  return '$h $v';
}

/// pdfme's `imageSize` (from image-size): PNG and JPEG headers only.
({double width, double height}) _imageSize(Uint8List b) {
  int u16(int i) => b[i] << 8 | b[i + 1];
  int u32(int i) => u16(i) * 65536 + u16(i + 2);
  String ascii(int start, int end) =>
      String.fromCharCodes(b.sublist(start, end));
  if (b.length >= 16 && ascii(1, 8) == 'PNG\r\n\x1a\n') {
    // "fried" PNGs (CgBI) have the IHDR chunk 16 bytes later
    bool fried = ascii(12, 16) == 'CgBI';
    String chunk = fried ? ascii(28, 32) : ascii(12, 16);
    if (chunk != 'IHDR') throw const FormatException('Invalid PNG');
    return fried
        ? (width: u32(32).toDouble(), height: u32(36).toDouble())
        : (width: u32(16).toDouble(), height: u32(20).toDouble());
  }
  if (b.length >= 2 && b[0] == 0xff && b[1] == 0xd8) {
    int pos = 4;
    while (pos < b.length) {
      int i = u16(pos);
      if (pos + i > b.length || b[pos + i] != 0xff) {
        throw const FormatException('Invalid JPG');
      }
      int next = b[pos + i + 1];
      if (next == 0xc0 || next == 0xc1 || next == 0xc2) {
        return (
          width: u16(pos + i + 7).toDouble(),
          height: u16(pos + i + 5).toDouble(),
        );
      }
      pos += i + 2;
    }
  }
  throw const FormatException('Unsupported image');
}
