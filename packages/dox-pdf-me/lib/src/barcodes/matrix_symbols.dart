import 'dart:math' as math;

import 'package:barcode/barcode.dart';

import 'barcode_symbol.dart';

/// A 2D barcode: its module grid and the size bwip-js gives it.
class MatrixSymbol {
  const MatrixSymbol(this.grid, {this.rowHeight = 1});

  final ModuleGrid grid;

  /// The height of one grid row, in modules (3 for PDF417, like BWIPP).
  final int rowHeight;

  /// The natural width : height of the symbol (no quiet zone).
  double get ratio => grid.columns / (grid.rows * rowHeight);

  /// The symbol in module units, ready to be stretched to its fitted box.
  BarcodeSymbol toSymbol() {
    List<BarcodeRect> rects = <BarcodeRect>[
      for (BarcodeRect r in grid.runs())
        BarcodeRect(r.x, r.y * rowHeight, r.width, r.height * rowHeight),
    ];
    return BarcodeSymbol(
      width: grid.columns.toDouble(),
      height: (grid.rows * rowHeight).toDouble(),
      rects: rects,
    );
  }
}

/// Builds the 2D barcodes (qrcode, gs1datamatrix, pdf417) with the
/// `barcode` package, set up to look like bwip-js.
class MatrixSymbolBuilder {
  const MatrixSymbolBuilder._();

  /// The symbol of [type] for [value], or null when it can not be encoded.
  static MatrixSymbol? build(String type, String value) {
    try {
      return switch (type) {
        'qrcode' => qrCode(value),
        'gs1datamatrix' => gs1DataMatrix(value),
        'pdf417' => pdf417(value),
        _ => null,
      };
    } on BarcodeException {
      return null;
    } on RangeError {
      // the barcode package's PDF417 fails this way on too much binary
      // data (bwip-js fails too: the data is too long)
      return null;
    }
  }

  /// QR code with error correction level M, like bwip-js.
  static MatrixSymbol qrCode(String value) => MatrixSymbol(
    readGrid(
      Barcode.qrCode(errorCorrectLevel: BarcodeQRCorrectionLevel.medium)
          .make(value, width: 1000, height: 1000),
    ),
  );

  /// GS1 Data Matrix: FNC1 first, then the element string without the
  /// parentheses, and FNC1 after each field of variable length.
  static MatrixSymbol? gs1DataMatrix(String value) {
    List<(String, String)>? fields = parseGs1(value);
    if (fields == null) return null;
    DataMatrixEncoder encoder = DataMatrixEncoder()..fnc1();
    for (int i = 0; i < fields.length; i++) {
      String ai = fields[i].$1;
      encoder.ascii(ai + fields[i].$2);
      if (i < fields.length - 1 && !_fixedLength(ai)) encoder.fnc1();
    }
    return MatrixSymbol(
      readGrid(
        Barcode.dataMatrix().makeBytes(
          encoder.toBytes(),
          width: 1000,
          height: 1000,
        ),
      ),
    );
  }

  /// `(01)123...(10)ABC` as `[('01', '123...'), ('10', 'ABC')]`, or null
  /// when it is not a GS1 element string.
  static List<(String, String)>? parseGs1(String value) {
    List<(String, String)> out = <(String, String)>[];
    int end = 0;
    for (RegExpMatch m in _gs1Field.allMatches(value)) {
      if (m.start != end) return null;
      out.add((m.group(1)!, m.group(2)!));
      end = m.end;
    }
    return out.isEmpty || end != value.length ? null : out;
  }

  static final RegExp _gs1Field = RegExp(r'\((\d{2,4})\)([^()]*)');

  /// GS1 application identifiers with a predefined length need no FNC1
  /// after them.
  static bool _fixedLength(String ai) => const <String>{
    '00', '01', '02', '03', '04', '11', '12', '13', '14', '15', '16', //
    '17', '18', '19', '20', '31', '32', '33', '34', '35', '36', '41',
  }.contains(ai.substring(0, 2));

  /// PDF417 in the shape BWIPP picks: error correction level by data size
  /// (2 to 5), `columns = round(sqrt((m + k) / 3))`, row height 3 modules.
  ///
  /// The `barcode` package can not be told the column count, only a
  /// preferred width : height ratio. So we find the number of data
  /// codewords `m` of the package's encoding first, then ask for the
  /// exact ratio of the BWIPP shape.
  static MatrixSymbol pdf417(String value) {
    int m = _pdf417DataCodewords(value);
    int level = m <= 40
        ? 2
        : m <= 160
        ? 3
        : m <= 320
        ? 4
        : 5;
    int k = 1 << (level + 1);
    int columns = math.max(2, math.sqrt((m + k) / 3).round());
    int rows = math.max(2, ((m + k + 1) / columns).ceil());
    return MatrixSymbol(
      _pdf417Grid(
        value,
        Pdf417SecurityLevel.values[level],
        (17 * columns + 69) / (rows * 3),
        3,
      ),
      rowHeight: 3,
    );
  }

  /// The number of data codewords of [value] (without the length word).
  ///
  /// With level 0 (2 correction words) and a huge preferred ratio, the
  /// package takes the most columns that still give 2 rows: `m + 2`. Past
  /// 60 columns the count is only known to a window, so it is refined by
  /// asking for a narrower shape.
  static int _pdf417DataCodewords(String value) {
    ModuleGrid g = _pdf417Grid(value, Pdf417SecurityLevel.level0, 1e9, 1);
    int columns = (g.columns - 69) ~/ 17;
    if (columns < 60) return columns - 2;
    // total = m + 3 is in (columns * (rows - 1), columns * rows]
    int low = columns * (g.rows - 1) + 1;
    int high = columns * g.rows;
    for (int i = 0; i < 3 && low < high; i++) {
      int c = math.max(2, (high / 60).ceil());
      int r = ((low + high) / 2 / c).ceil();
      g = _pdf417Grid(value, Pdf417SecurityLevel.level0, (17 * c + 69) / r, 1);
      c = (g.columns - 69) ~/ 17;
      low = math.max(low, c * (g.rows - 1) + 1);
      high = math.min(high, c * g.rows);
    }
    return (low + high) ~/ 2 - 3;
  }

  static ModuleGrid _pdf417Grid(
    String value,
    Pdf417SecurityLevel level,
    double ratio,
    double moduleHeight,
  ) => readGrid(
    Barcode.pdf417(
      securityLevel: level,
      moduleHeight: moduleHeight,
      preferredRatio: ratio,
    ).make(value, width: 10000, height: 10000),
  );

  /// The module grid of 2D barcode [elements] from the `barcode` package.
  /// One module is the narrowest run; one row is the height of a bar.
  static ModuleGrid readGrid(Iterable<BarcodeElement> elements) {
    List<BarcodeBar> bars = <BarcodeBar>[
      for (BarcodeElement e in elements)
        if (e is BarcodeBar) e,
    ];
    double left = double.infinity, top = double.infinity;
    double right = 0, bottom = 0, unit = double.infinity;
    for (BarcodeBar b in bars) {
      left = math.min(left, b.left);
      top = math.min(top, b.top);
      right = math.max(right, b.left + b.width);
      bottom = math.max(bottom, b.top + b.height);
      unit = math.min(unit, b.width);
    }
    double rowHeight = bars.first.height;
    ModuleGrid grid = ModuleGrid(
      ((right - left) / unit).round(),
      ((bottom - top) / rowHeight).round(),
    );
    for (BarcodeBar b in bars) {
      if (!b.black) continue;
      int column = ((b.left - left) / unit).round();
      int row = ((b.top - top) / rowHeight).round();
      int length = (b.width / unit).round();
      for (int i = 0; i < length; i++) {
        grid.setDark(column + i, row);
      }
    }
    return grid;
  }
}
