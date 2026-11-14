/// A filled rectangle of a barcode, in symbol units. The y axis points
/// down, like in SVG.
class BarcodeRect {
  const BarcodeRect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;

  @override
  String toString() => 'BarcodeRect($x, $y, $width, $height)';
}

/// The human readable text of a linear barcode: one centered line under
/// the bars.
class BarcodeTextLine {
  const BarcodeTextLine({
    required this.text,
    required this.left,
    required this.width,
    required this.baseline,
    required this.capHeight,
  });

  final String text;

  /// Where the text starts, in x units.
  final double left;

  /// How wide the text is, in x units.
  final double width;

  /// The baseline, in y units from the top.
  final double baseline;

  /// The height of a capital letter or digit, in y units.
  final double capHeight;
}

/// A barcode ready to draw, like the SVG of bwip-js.
///
/// It is a [width] x [height] box with filled [rects], stroked [bars]
/// and an optional [text]. The x and y units may differ: the painter stretches the box to
/// the target rectangle on its own in each direction, like pdfme stretches
/// the bwip-js SVG.
class BarcodeSymbol {
  const BarcodeSymbol({
    required this.width,
    required this.height,
    required this.rects,
    this.bars = const <BarcodeRect>[],
    this.border = const <BarcodeRect>[],
    this.text,
  });

  final double width;
  final double height;
  final List<BarcodeRect> rects;

  /// Bars drawn like bwip-js draws them: a stroked vertical line along the
  /// middle of the rectangle, the stroke as wide as the rectangle. A PDF
  /// viewer draws thin strokes a bit differently from thin fills, so this
  /// keeps the page look of pdfme.
  final List<BarcodeRect> bars;

  /// Filled rectangles that are always black: the bearer box of ITF-14
  /// (bwip-js draws it in its `bordercolor`, and pdfme does not set it).
  final List<BarcodeRect> border;
  final BarcodeTextLine? text;
}

/// A grid of dark and light modules (QR code, Data Matrix, PDF417).
class ModuleGrid {
  ModuleGrid(this.columns, this.rows)
    : _dark = List<bool>.filled(columns * rows, false);

  final int columns;
  final int rows;
  final List<bool> _dark;

  bool isDark(int column, int row) => _dark[row * columns + column];

  void setDark(int column, int row) => _dark[row * columns + column] = true;

  /// The dark modules as one rectangle per dark run of a row, in module
  /// units (row height 1).
  List<BarcodeRect> runs() {
    List<BarcodeRect> out = <BarcodeRect>[];
    for (int row = 0; row < rows; row++) {
      int start = -1;
      for (int column = 0; column <= columns; column++) {
        bool dark = column < columns && isDark(column, row);
        if (dark && start < 0) start = column;
        if (!dark && start >= 0) {
          out.add(
            BarcodeRect(
              start.toDouble(),
              row.toDouble(),
              (column - start).toDouble(),
              1,
            ),
          );
          start = -1;
        }
      }
    }
    return out;
  }
}
