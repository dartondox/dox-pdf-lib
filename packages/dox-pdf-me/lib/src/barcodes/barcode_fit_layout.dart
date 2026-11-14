/// Where a barcode goes in its box: pdfme's `getBarcodeFitLayout`.
class BarcodeFitLayout {
  const BarcodeFitLayout({
    required this.width,
    required this.height,
    required this.offsetX,
    required this.offsetY,
  });

  final double width;
  final double height;

  /// From the left edge of the box.
  final double offsetX;

  /// From the top edge of the box.
  final double offsetY;

  @override
  bool operator ==(Object other) =>
      other is BarcodeFitLayout &&
      other.width == width &&
      other.height == height &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY;

  @override
  int get hashCode => Object.hash(width, height, offsetX, offsetY);

  @override
  String toString() =>
      'BarcodeFitLayout($width x $height, offset $offsetX, $offsetY)';
}

/// pdfme's `getBarcodeFitLayout`. With a natural size, it is the centered
/// "contain" rectangle of that ratio. Without one, it is the whole box.
///
/// The limiting side stays exactly the box side, so a box that already has
/// the natural ratio comes back unchanged.
BarcodeFitLayout getBarcodeFitLayout({
  required double boxWidth,
  required double boxHeight,
  double? naturalWidth,
  double? naturalHeight,
}) {
  if (naturalWidth == null ||
      naturalHeight == null ||
      naturalWidth <= 0 ||
      naturalHeight <= 0) {
    return BarcodeFitLayout(
      width: boxWidth,
      height: boxHeight,
      offsetX: 0,
      offsetY: 0,
    );
  }
  double ratio = naturalWidth / naturalHeight;
  bool widthLimited = boxWidth / boxHeight <= ratio;
  double width = widthLimited ? boxWidth : boxHeight * ratio;
  double height = widthLimited ? boxWidth / ratio : boxHeight;
  return BarcodeFitLayout(
    width: width,
    height: height,
    offsetX: (boxWidth - width) / 2,
    offsetY: (boxHeight - height) / 2,
  );
}
