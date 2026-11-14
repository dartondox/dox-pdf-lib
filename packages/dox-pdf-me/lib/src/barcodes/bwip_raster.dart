import 'dart:math' as math;

import 'barcode_symbol.dart';

/// One bar as BWIPP's `renlinear` draws it. x is in BWIPP x units
/// (modules), y in points with the y axis up; 0 is the bar baseline.
class BwippBar {
  const BwippBar(this.center, this.width, this.bottom, this.height);

  final double center;
  final double width;
  final double bottom;
  final double height;
}

/// The bearer box of ITF-14 (BWIPP `showborder`): offsets out of the bars
/// area and the line width, in BWIPP units.
class BwippBorder {
  const BwippBorder({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.lineWidth,
  });

  final double left;
  final double right;
  final double top;
  final double bottom;
  final double lineWidth;
}

/// Turns BWIPP bars into the SVG geometry of bwip-js 4.11.4 (`scale: 5`
/// and `width`, as pdfme calls it).
///
/// bwip-js snaps every bar to whole SVG units: the bar center is rounded,
/// the stroke width is `floor(w + 0.66)`, and odd widths move half a unit.
/// The page looks the same as pdfme only with the same snapping, so this
/// class copies it (bwip-js `BWIPJS.prototype.stroke`, `bbox` and the SVG
/// `line` and `polygon` drawing).
class BwipRaster {
  BwipRaster({required double widthMm, required this.symbolWidth})
    : sx = 5 * widthMm / 25.4 * 72 / symbolWidth;

  /// The width of the bars area, in BWIPP x units (`pixx`).
  final double symbolWidth;

  /// SVG units per BWIPP x unit.
  final double sx;

  /// SVG units per point.
  static const double sy = 5;

  /// From the text base to the lowest text pixel of OCR-B digits.
  static const int textDepth = 40;

  /// From the bars bottom (or frame bottom) to the text baseline.
  static const double baselineGap = 38.35;

  /// The height of an OCR-B digit, in SVG units.
  static const double capHeight = 33.4;

  /// The symbol of [bars], with the [border] and the [text] line, in SVG
  /// units. [textAdvances] are the OCR-B advances of the text (font
  /// units); [textDescent] is how much lower than digits the text goes.
  BarcodeSymbol render(
    List<BwippBar> bars, {
    BwippBorder? border,
    String? text,
    List<int> textAdvances = const <int>[],
    int textDescent = 0,
  }) {
    _Bounds b = _Bounds();
    List<_DeviceBar> device = <_DeviceBar>[
      for (BwippBar bar in bars) _bar(bar, b),
    ];
    _DeviceBorder? frame = border == null ? null : _border(border, bars, b);
    int textBase = frame == null ? 0 : frame.y0 - frame.bigH;
    if (text != null) b.addY(textBase - textDepth - textDescent);

    double dx = sx.floor().isOdd ? -0.5 : 0.5;
    // bwip-js moves a bar with no height by half a unit, like a bar's x
    double dy = sy.floor().isOdd ? -0.5 : 0.5;
    List<BarcodeRect> strokes = <BarcodeRect>[
      for (_DeviceBar d in device)
        BarcodeRect(
          d.x - b.minX + (d.pen.isOdd ? dx : 0) - d.pen / 2,
          (b.maxY - d.y1) + (d.pen.isOdd && d.y0 == d.y1 ? dy : 0),
          d.pen.toDouble(),
          (d.y1 - d.y0 + 1).toDouble(),
        ),
    ];
    return BarcodeSymbol(
      width: (b.maxX - b.minX + 1).toDouble(),
      height: (b.maxY - b.minY + 1).toDouble(),
      rects: frame == null ? const <BarcodeRect>[] : frame.bands(b),
      bars: strokes,
      text: text == null
          ? null
          : BarcodeTextLine(
              text: text,
              left:
                  sx * symbolWidth / 2 - b.minX - _textWidth(textAdvances) / 2,
              width: _textWidth(textAdvances),
              baseline: b.maxY - textBase + 1 + baselineGap,
              capHeight: capHeight,
            ),
    );
  }

  _DeviceBar _bar(BwippBar bar, _Bounds b) {
    int x = _round(sx * bar.center);
    int pen = (bar.width * sx + 0.66).floor();
    int y0 = _round(sy * bar.bottom);
    int y1 = _round(sy * (bar.bottom + bar.height));
    b.add(x - pen / 2, y0, x + pen - pen / 2 - 1, y1);
    return _DeviceBar(x, pen, y0, y1);
  }

  _DeviceBorder _border(BwippBorder border, List<BwippBar> bars, _Bounds b) {
    double top = 0;
    for (BwippBar bar in bars) {
      top = math.max(top, bar.bottom + bar.height);
    }
    double half = border.lineWidth / 2;
    int penW = (border.lineWidth * sx + 0.66).floor();
    int penH = (border.lineWidth * sy + 0.66).floor();
    _DeviceBorder d = _DeviceBorder(
      x0: _round(-sx * (border.left + half)),
      y0: _round(-sy * (border.bottom + half)),
      x1: _round(sx * (symbolWidth + border.right + half)),
      y1: _round(sy * (top + border.top + half)),
      bigW: (penW / 2).ceil(),
      bigH: (penH / 2).ceil(),
      remW: penW - (penW / 2).ceil(),
      remH: penH - (penH / 2).ceil(),
    );
    b.add(d.x0 - d.bigW, d.y0 - d.bigH, d.x1 + d.bigW, d.y1 + d.bigH);
    return d;
  }

  /// The width of OCR-B text in SVG units, like bwip-js: the font is
  /// `floor(10 pt * sx)` units wide and each advance is rounded down
  /// (OCR-B ascent: 1106 font units).
  double _textWidth(List<int> advances) {
    int size = (10 * sx).floor();
    int width = 0;
    for (int a in advances) {
      width += a * size ~/ 1106;
    }
    return width.toDouble();
  }

  /// JavaScript `Math.round`: halves go up.
  static int _round(double v) => (v + 0.5).floor();
}

class _DeviceBar {
  const _DeviceBar(this.x, this.pen, this.y0, this.y1);

  final int x;
  final int pen;
  final int y0;
  final int y1;
}

class _DeviceBorder {
  const _DeviceBorder({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.bigW,
    required this.bigH,
    required this.remW,
    required this.remH,
  });

  final int x0;
  final int y0;
  final int x1;
  final int y1;
  final int bigW;
  final int bigH;
  final int remW;
  final int remH;

  /// The frame (outer box minus inner box) as 4 bands, in SVG units.
  List<BarcodeRect> bands(_Bounds b) {
    int left = x0 - b.minX, right = x1 - b.minX;
    int top = b.maxY - y1, bottom = b.maxY - y0;
    double oL = (left - bigW).toDouble(), oR = (right + bigW + 1).toDouble();
    double oT = (top - bigH).toDouble(), oB = (bottom + bigH + 1).toDouble();
    double iL = (left + remW).toDouble(), iR = (right - remW + 1).toDouble();
    double iT = (top + remH).toDouble(), iB = (bottom - remH + 1).toDouble();
    return <BarcodeRect>[
      BarcodeRect(oL, oT, oR - oL, iT - oT),
      BarcodeRect(oL, iB, oR - oL, oB - iB),
      BarcodeRect(oL, iT, iL - oL, iB - iT),
      BarcodeRect(iR, iT, oR - iR, iB - iT),
    ];
  }
}

/// bwip-js `bbox`: the pixel bounds of all drawing, y up.
class _Bounds {
  int minX = 1 << 30, maxX = -(1 << 30), minY = 1 << 30, maxY = -(1 << 30);

  void add(num x0, num y0, num x1, num y1) {
    minX = math.min(minX, x0.floor());
    maxX = math.max(maxX, x1.ceil());
    addY(y0.floor());
    maxY = math.max(maxY, y1.ceil());
  }

  void addY(int y) => minY = math.min(minY, y);
}
