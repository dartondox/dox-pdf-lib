import 'dart:math' as math;
import 'dart:typed_data';

import 'package:barcode/barcode.dart';

import 'barcode_symbol.dart';
import 'barcode_validator.dart';
import 'datamatrix_encoder.dart';
import 'gs1_process.dart';
import 'pdf417_encoder.dart';
import 'qr_encoder.dart';

/// A 2D barcode: its module grid and the size bwip-js gives it.
class MatrixSymbol {
  const MatrixSymbol(this.grid, {this.rowHeight = 1});

  final ModuleGrid grid;

  /// The height of one grid row, in modules (3 for PDF417, like BWIPP).
  final int rowHeight;

  /// The natural width : height of the symbol (no quiet zone).
  double get ratio => grid.columns / (grid.rows * rowHeight);

  /// The symbol in module units, ready to be stretched to its fitted box.
  ///
  /// With the fitted size ([widthMm] x [heightMm]) the module edges are
  /// rounded to whole bwip-js units (1/5 point at that size), like the
  /// SVG pdfme draws. That keeps the page the same at small sizes.
  BarcodeSymbol toSymbol({double? widthMm, double? heightMm}) {
    int units = grid.rows * rowHeight;
    if (widthMm == null || heightMm == null) {
      return BarcodeSymbol(
        width: grid.columns.toDouble(),
        height: units.toDouble(),
        rects: <BarcodeRect>[
          for (BarcodeRect r in grid.runs())
            BarcodeRect(r.x, r.y * rowHeight, r.width, r.height * rowHeight),
        ],
      );
    }
    double w = widthMm / 25.4 * 72 * 5;
    double h = heightMm / 25.4 * 72 * 5;
    double sx = w / grid.columns;
    double sy = h / units;
    double height = _jsRound(h);
    // bwip-js rounds y from the bottom of the symbol, then flips it
    double y(double fromTop) => height - _jsRound((units - fromTop) * sy);
    return BarcodeSymbol(
      width: _jsRound(w),
      height: height,
      rects: <BarcodeRect>[
        for (BarcodeRect r in grid.runs())
          _snapped(
            _jsRound(r.x * sx),
            _jsRound((r.x + r.width) * sx),
            y(r.y * rowHeight),
            y((r.y + r.height) * rowHeight),
          ),
      ],
    );
  }

  static BarcodeRect _snapped(double x0, double x1, double y0, double y1) =>
      BarcodeRect(x0, y0, x1 - x0, y1 - y0);

  /// JavaScript's `Math.round`: halves go up.
  static double _jsRound(double v) => (v + 0.5).floorToDouble();
}

/// Builds the 2D barcodes (qrcode, gs1datamatrix, pdf417), set up to look
/// like bwip-js. QR code and Data Matrix use the `barcode` package.
class MatrixSymbolBuilder {
  const MatrixSymbolBuilder._();

  /// The symbol of [type] for [value], or null when [value] is empty or
  /// [type] is not 2D. Throws a [BarcodeInputException] when bwip-js would
  /// throw.
  static MatrixSymbol? build(String type, String value) {
    if (value.isEmpty) return null;
    checkBwipText(value);
    try {
      return switch (type) {
        'qrcode' => qrCode(value),
        'gs1datamatrix' => gs1DataMatrix(value),
        'pdf417' => pdf417(value),
        _ => null,
      };
    } on BarcodeException {
      return null;
    }
  }

  /// QR code with our port of the BWIPP encoder, so the modules are the
  /// same as in bwip-js.
  static MatrixSymbol qrCode(String value) =>
      MatrixSymbol(QrEncoder.encode(value));

  /// GS1 Data Matrix: FNC1 first, then each AI and its value, and FNC1
  /// after each value of variable length ([Gs1Process], which also checks
  /// the data like bwip-js).
  static MatrixSymbol gs1DataMatrix(String value) {
    List<Gs1Element> fields = Gs1Process.parse(value);
    List<int> msg = <int>[DataMatrixCodewords.fnc1];
    for (Gs1Element f in fields) {
      msg.addAll('${f.ai}${f.value}'.codeUnits);
      if (f.fnc1After) msg.add(DataMatrixCodewords.fnc1);
    }
    return MatrixSymbol(
      readGrid(
        Barcode.dataMatrix().makeBytes(
          Uint8List.fromList(DataMatrixCodewords.codewords(msg)),
          width: 1000,
          height: 1000,
        ),
      ),
    );
  }

  /// PDF417 with our port of the BWIPP encoder, so the codewords, the
  /// columns and the rows are the same as in bwip-js. Row height 3
  /// modules. Null when the data is too long.
  static MatrixSymbol pdf417(String value) =>
      MatrixSymbol(Pdf417Encoder.encode(value).grid(), rowHeight: 3);

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
