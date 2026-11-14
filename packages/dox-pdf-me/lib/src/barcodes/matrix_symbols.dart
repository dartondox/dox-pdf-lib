import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:barcode/barcode.dart';

import 'barcode_symbol.dart';
import 'datamatrix_encoder.dart';
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
    }
  }

  /// QR code with our port of the BWIPP encoder, so the modules are the
  /// same as in bwip-js. Null when the data is too long.
  static MatrixSymbol? qrCode(String value) {
    ModuleGrid? grid = QrEncoder.encode(value);
    return grid == null ? null : MatrixSymbol(grid);
  }

  /// GS1 Data Matrix: FNC1 first, then the element string without the
  /// parentheses, and FNC1 after each field of variable length.
  static MatrixSymbol? gs1DataMatrix(String value) {
    List<(String, String)>? fields = parseGs1(value);
    if (fields == null) return null;
    List<int> msg = <int>[DataMatrixCodewords.fnc1];
    for (int i = 0; i < fields.length; i++) {
      String ai = fields[i].$1;
      msg.addAll(utf8.encode(ai + fields[i].$2));
      if (i < fields.length - 1 && !_fixedLength(ai)) {
        msg.add(DataMatrixCodewords.fnc1);
      }
    }
    List<int>? cws = DataMatrixCodewords.codewords(msg);
    if (cws == null) return null;
    return MatrixSymbol(
      readGrid(
        Barcode.dataMatrix().makeBytes(
          Uint8List.fromList(cws),
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

  /// PDF417 with our port of the BWIPP encoder, so the codewords, the
  /// columns and the rows are the same as in bwip-js. Row height 3
  /// modules. Null when the data is too long.
  static MatrixSymbol? pdf417(String value) {
    Pdf417Symbol? symbol = Pdf417Encoder.encode(value);
    return symbol == null ? null : MatrixSymbol(symbol.grid(), rowHeight: 3);
  }

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
