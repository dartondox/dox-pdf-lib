import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import 'barcode_symbol.dart';

/// Draws a [BarcodeSymbol] on a page as vectors: all bars in one filled
/// path, and the text with a standard font.
///
/// The symbol is stretched to the target rectangle on its own in each
/// direction, like pdfme stretches the bwip-js SVG
/// (`preserveAspectRatio="none"`).
///
/// The text: bwip-js draws it in OCR-B, which we do not have. We draw it in
/// Helvetica instead. Its capitals are as high as the OCR-B digits, and the
/// line is stretched to the width of the OCR-B line, at the same baseline.
/// So the text sits in the same place and takes the same room, but the
/// glyph shapes and the spacing inside the line differ a little.
class BarcodePainter {
  const BarcodePainter(this.page);

  final PDFPage page;

  /// Helvetica's cap height, in em (its AFM `CapHeight` 718).
  static const double helveticaCapHeight = 0.718;

  /// Draws [symbol] into the rectangle with the top left corner [left],
  /// [top] (PDF points, y up).
  void paint(
    BarcodeSymbol symbol, {
    required double left,
    required double top,
    required double width,
    required double height,
    required Color barColor,
    Color? textColor,
    PDFFont? font,
    double? opacity,
  }) {
    if (symbol.width <= 0 || symbol.height <= 0) return;
    double sx = width / symbol.width;
    double sy = height / symbol.height;
    if (symbol.rects.isNotEmpty) {
      page.drawSvgPath(
        rectsPath(symbol.rects, sx, sy),
        x: left,
        y: top,
        color: barColor,
        opacity: opacity,
      );
    }
    _paintBars(
      symbol.bars,
      (left: left, top: top, width: width, height: height),
      sx,
      sy,
      barColor,
      opacity,
    );
    BarcodeTextLine? text = symbol.text;
    if (text != null && font != null && text.text.isNotEmpty) {
      _paintText(
        text,
        left: left + text.left * sx,
        baseline: top - text.baseline * sy,
        width: text.width * sx,
        size: text.capHeight * sy / helveticaCapHeight,
        color: textColor ?? const RGB(0, 0, 0),
        font: font,
        opacity: opacity,
      );
    }
  }

  /// Strokes [bars] like pdfme draws the bwip-js SVG: one path per stroke
  /// width, clipped to the rectangle, in SVG units under a stretching
  /// matrix.
  void _paintBars(
    List<BarcodeRect> bars,
    ({double left, double top, double width, double height}) box,
    double sx,
    double sy,
    Color color,
    double? opacity,
  ) {
    Map<double, StringBuffer> paths = <double, StringBuffer>{};
    for (BarcodeRect r in bars) {
      String x = _n(r.x + r.width / 2);
      paths
          .putIfAbsent(r.width, StringBuffer.new)
          .write('M$x ${_n(r.y + r.height)}L$x ${_n(r.y)}');
    }
    for (MapEntry<double, StringBuffer> e in paths.entries) {
      page.pushOperators(<PDFOperator>[
        pushGraphicsState(),
        rectangle(box.left, box.top - box.height, box.width, box.height),
        clip(),
        endPath(),
        concatTransformationMatrix(sx, 0, 0, sy, box.left, box.top),
      ]);
      page.drawSvgPath(
        e.value.toString(),
        x: 0,
        y: 0,
        borderColor: color,
        borderWidth: e.key,
        borderOpacity: opacity,
      );
      page.pushOperators(<PDFOperator>[popGraphicsState()]);
    }
  }

  void _paintText(
    BarcodeTextLine text, {
    required double left,
    required double baseline,
    required double width,
    required double size,
    required Color color,
    required PDFFont font,
    double? opacity,
  }) {
    double natural = font.widthOfTextAtSize(text.text, size);
    if (natural <= 0 || size <= 0) return;
    page.pushOperators(<PDFOperator>[
      pushGraphicsState(),
      concatTransformationMatrix(width / natural, 0, 0, 1, left, baseline),
    ]);
    page.drawText(
      text.text,
      x: 0,
      y: 0,
      size: size,
      font: font,
      color: color,
      opacity: opacity,
    );
    page.pushOperators(<PDFOperator>[popGraphicsState()]);
  }

  /// An SVG path (y down) of all [rects], scaled by [sx] and [sy].
  static String rectsPath(List<BarcodeRect> rects, double sx, double sy) {
    StringBuffer out = StringBuffer();
    for (BarcodeRect r in rects) {
      String x0 = _n(r.x * sx);
      String x1 = _n((r.x + r.width) * sx);
      out.write(
        'M$x0 ${_n(r.y * sy)}H${x1}V${_n((r.y + r.height) * sy)}H${x0}Z',
      );
    }
    return out.toString();
  }

  static String _n(double v) {
    String s = v.toStringAsFixed(3);
    if (!s.contains('.')) return s;
    s = s.replaceFirst(RegExp(r'0+$'), '');
    return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
  }
}
