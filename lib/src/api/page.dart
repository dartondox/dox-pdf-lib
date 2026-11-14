part of 'document.dart';

/// A page box: lower left corner, width and height.
typedef PDFBox = ({double x, double y, double width, double height});

/// Throws an [ArgumentError] for NaN and infinity: a PDF has no such
/// numbers.
void _finite(double value, String name) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, name, 'must be a finite number');
  }
}

/// One page, like pdf-lib's `PDFPage`. It belongs to [doc].
class PDFPage {
  PDFPage._(this.doc, this.ref);

  final PDFDocument doc;

  /// The object number of the page, `number << 16 | generation`.
  final int ref;

  PDFBox _box(int kind) {
    Float64List out = Float64List(4);
    check(doxPdfPageGetBox(doc._handle, ref, kind, out.address));
    return (x: out[0], y: out[1], width: out[2], height: out[3]);
  }

  void _setBox(int kind, double x, double y, double width, double height) {
    _finite(x, 'x');
    _finite(y, 'y');
    _finite(width, 'width');
    _finite(height, 'height');
    check(doxPdfPageSetBox(doc._handle, ref, kind, x, y, width, height));
  }

  /// Size of the media box.
  ({double width, double height}) getSize() {
    PDFBox box = getMediaBox();
    return (width: box.width, height: box.height);
  }

  double getWidth() => getSize().width;

  double getHeight() => getSize().height;

  /// Sets the media box size. Crop, bleed, trim and art boxes that were the
  /// same as the media box follow it.
  void setSize(double width, double height) {
    _finite(width, 'width');
    _finite(height, 'height');
    check(doxPdfPageSetSize(doc._handle, ref, width, height, 0));
  }

  void setWidth(double width) {
    _finite(width, 'width');
    check(doxPdfPageSetSize(doc._handle, ref, width, 0, keepHeight));
  }

  void setHeight(double height) {
    _finite(height, 'height');
    check(doxPdfPageSetSize(doc._handle, ref, 0, height, keepWidth));
  }

  /// Sets the rotation. It must be a multiple of 90 degrees.
  void setRotation(Rotation angle) =>
      check(doxPdfPageSetRotation(doc._handle, ref, toDegrees(angle)));

  Degrees getRotation() {
    Float64List out = Float64List(1);
    check(doxPdfPageGetRotation(doc._handle, ref, out.address));
    return degrees(out[0]);
  }

  PDFBox getMediaBox() => _box(boxMedia);

  /// The crop box, or the media box when there is none.
  PDFBox getCropBox() => _box(boxCrop);

  /// The bleed box, or the crop box when there is none.
  PDFBox getBleedBox() => _box(boxBleed);

  /// The trim box, or the crop box when there is none.
  PDFBox getTrimBox() => _box(boxTrim);

  /// The art box, or the crop box when there is none.
  PDFBox getArtBox() => _box(boxArt);

  void setMediaBox(double x, double y, double width, double height) =>
      _setBox(boxMedia, x, y, width, height);

  void setCropBox(double x, double y, double width, double height) =>
      _setBox(boxCrop, x, y, width, height);

  void setBleedBox(double x, double y, double width, double height) =>
      _setBox(boxBleed, x, y, width, height);

  void setTrimBox(double x, double y, double width, double height) =>
      _setBox(boxTrim, x, y, width, height);

  void setArtBox(double x, double y, double width, double height) =>
      _setBox(boxArt, x, y, width, height);
}
