// pdf-lib's operator helpers (`operators.ts`), for `PDFPage.pushOperators`.
import 'dart:math' as math;

import 'colors.dart';
import 'rotations.dart';

enum LineCapStyle { butt, round, projecting }

enum LineJoinStyle { miter, round, bevel }

enum TextRenderingMode {
  fill,
  outline,
  fillAndOutline,
  invisible,
  fillAndClip,
  outlineAndClip,
  fillAndOutlineAndClip,
  clip,
}

/// Text as hex codes, eg. from `PDFFont.encodeText`.
class PDFHexString {
  const PDFHexString(this.value);

  final String value;

  @override
  String toString() => '<$value>';
}

/// One content stream operator with its arguments, like pdf-lib's.
class PDFOperator {
  PDFOperator(this.name, [this.args = const <String>[]]);

  final String name;

  /// The arguments as they are written in the content stream.
  final List<String> args;

  @override
  String toString() => args.isEmpty ? name : '${args.join(' ')} $name';
}

/// A number as pdf-lib writes it: no exponent, `-0` is `0`.
String numberToString(num value) {
  if (value == 0) return '0';
  if (value is int) return value.toString();
  double v = value as double;
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v > 0 ? 'Infinity' : '-Infinity';
  if (v == v.truncateToDouble() && v.abs() < 1e21) {
    return v.toStringAsFixed(0);
  }
  String s = v.toString();
  int e = s.indexOf('e');
  if (e < 0) return s;
  // eg. 1.5e-7 -> 0.00000015
  bool negative = s.startsWith('-');
  String mantissa = s.substring(negative ? 1 : 0, e);
  int exponent = int.parse(s.substring(e + 1));
  int dot = mantissa.indexOf('.');
  String digits = mantissa.replaceFirst('.', '');
  int point = (dot < 0 ? mantissa.length : dot) + exponent;
  String out = point <= 0
      ? '0.${'0' * -point}$digits'
      : point >= digits.length
      ? digits + '0' * (point - digits.length)
      : '${digits.substring(0, point)}.${digits.substring(point)}';
  return negative ? '-$out' : out;
}

String _name(String name) {
  StringBuffer out = StringBuffer('/');
  for (int c in name.codeUnits) {
    bool plain = c > 0x20 && c < 0x7f && !'#()<>[]{}/%'.codeUnits.contains(c);
    out.write(
      plain
          ? String.fromCharCode(c)
          : '#${c.toRadixString(16).padLeft(2, '0').toUpperCase()}',
    );
  }
  return out.toString();
}

PDFOperator _op(String name, [List<num> args = const <num>[]]) =>
    PDFOperator(name, <String>[for (num a in args) numberToString(a)]);

// Clipping path

PDFOperator clip() => _op('W');
PDFOperator clipEvenOdd() => _op('W*');

// Graphics state

PDFOperator concatTransformationMatrix(
  num a,
  num b,
  num c,
  num d,
  num e,
  num f,
) => _op('cm', <num>[a, b, c, d, e, f]);

PDFOperator translate(num xPos, num yPos) =>
    concatTransformationMatrix(1, 0, 0, 1, xPos, yPos);

PDFOperator scale(num xPos, num yPos) =>
    concatTransformationMatrix(xPos, 0, 0, yPos, 0, 0);

PDFOperator rotateRadians(num angle) => concatTransformationMatrix(
  math.cos(angle),
  math.sin(angle),
  -math.sin(angle),
  math.cos(angle),
  0,
  0,
);

PDFOperator rotateDegrees(num angle) =>
    rotateRadians(degreesToRadians(angle.toDouble()));

PDFOperator skewRadians(num xSkewAngle, num ySkewAngle) =>
    concatTransformationMatrix(
      1,
      math.tan(xSkewAngle),
      math.tan(ySkewAngle),
      1,
      0,
      0,
    );

PDFOperator skewDegrees(num xSkewAngle, num ySkewAngle) => skewRadians(
  degreesToRadians(xSkewAngle.toDouble()),
  degreesToRadians(ySkewAngle.toDouble()),
);

PDFOperator setDashPattern(List<num> dashArray, num dashPhase) =>
    PDFOperator('d', <String>[
      '[${dashArray.map(numberToString).join(' ')}]',
      numberToString(dashPhase),
    ]);

PDFOperator restoreDashPattern() => setDashPattern(const <num>[], 0);

PDFOperator setLineCap(LineCapStyle style) => _op('J', <num>[style.index]);

PDFOperator setLineJoin(LineJoinStyle style) => _op('j', <num>[style.index]);

PDFOperator setGraphicsState(String state) =>
    PDFOperator('gs', <String>[_name(state)]);

PDFOperator pushGraphicsState() => _op('q');
PDFOperator popGraphicsState() => _op('Q');

PDFOperator setLineWidth(num width) => _op('w', <num>[width]);

// Path construction

PDFOperator appendBezierCurve(num x1, num y1, num x2, num y2, num x3, num y3) =>
    _op('c', <num>[x1, y1, x2, y2, x3, y3]);

PDFOperator appendQuadraticCurve(num x1, num y1, num x2, num y2) =>
    _op('v', <num>[x1, y1, x2, y2]);

PDFOperator closePath() => _op('h');

PDFOperator moveTo(num xPos, num yPos) => _op('m', <num>[xPos, yPos]);

PDFOperator lineTo(num xPos, num yPos) => _op('l', <num>[xPos, yPos]);

PDFOperator rectangle(num xPos, num yPos, num width, num height) =>
    _op('re', <num>[xPos, yPos, width, height]);

PDFOperator square(num xPos, num yPos, num size) =>
    rectangle(xPos, yPos, size, size);

// Path painting

PDFOperator stroke() => _op('S');
PDFOperator fill() => _op('f');
PDFOperator fillAndStroke() => _op('B');
PDFOperator endPath() => _op('n');

// Text

PDFOperator nextLine() => _op('T*');

PDFOperator moveText(num x, num y) => _op('Td', <num>[x, y]);

PDFOperator showText(PDFHexString text) =>
    PDFOperator('Tj', <String>[text.toString()]);

PDFOperator beginText() => _op('BT');
PDFOperator endText() => _op('ET');

PDFOperator setFontAndSize(String name, num size) =>
    PDFOperator('Tf', <String>[_name(name), numberToString(size)]);

PDFOperator setCharacterSpacing(num spacing) => _op('Tc', <num>[spacing]);

PDFOperator setWordSpacing(num spacing) => _op('Tw', <num>[spacing]);

/// Horizontal character spacing.
PDFOperator setCharacterSqueeze(num squeeze) => _op('Tz', <num>[squeeze]);

PDFOperator setLineHeight(num lineHeight) => _op('TL', <num>[lineHeight]);

PDFOperator setTextRise(num rise) => _op('Ts', <num>[rise]);

PDFOperator setTextRenderingMode(TextRenderingMode mode) =>
    _op('Tr', <num>[mode.index]);

PDFOperator setTextMatrix(num a, num b, num c, num d, num e, num f) =>
    _op('Tm', <num>[a, b, c, d, e, f]);

PDFOperator rotateAndSkewTextRadiansAndTranslate(
  num rotationAngle,
  num xSkewAngle,
  num ySkewAngle,
  num x,
  num y,
) => setTextMatrix(
  math.cos(rotationAngle),
  math.sin(rotationAngle) + math.tan(xSkewAngle),
  -math.sin(rotationAngle) + math.tan(ySkewAngle),
  math.cos(rotationAngle),
  x,
  y,
);

PDFOperator rotateAndSkewTextDegreesAndTranslate(
  num rotationAngle,
  num xSkewAngle,
  num ySkewAngle,
  num x,
  num y,
) => rotateAndSkewTextRadiansAndTranslate(
  degreesToRadians(rotationAngle.toDouble()),
  degreesToRadians(xSkewAngle.toDouble()),
  degreesToRadians(ySkewAngle.toDouble()),
  x,
  y,
);

// XObject

PDFOperator drawObject(String name) => PDFOperator('Do', <String>[_name(name)]);

// Color

PDFOperator setFillingGrayscaleColor(num gray) => _op('g', <num>[gray]);

PDFOperator setStrokingGrayscaleColor(num gray) => _op('G', <num>[gray]);

PDFOperator setFillingRgbColor(num red, num green, num blue) =>
    _op('rg', <num>[red, green, blue]);

PDFOperator setStrokingRgbColor(num red, num green, num blue) =>
    _op('RG', <num>[red, green, blue]);

PDFOperator setFillingCmykColor(num cyan, num magenta, num yellow, num key) =>
    _op('k', <num>[cyan, magenta, yellow, key]);

PDFOperator setStrokingCmykColor(num cyan, num magenta, num yellow, num key) =>
    _op('K', <num>[cyan, magenta, yellow, key]);

PDFOperator setFillingColor(Color color) => switch (color) {
  Grayscale c => setFillingGrayscaleColor(c.gray),
  RGB c => setFillingRgbColor(c.red, c.green, c.blue),
  CMYK c => setFillingCmykColor(c.cyan, c.magenta, c.yellow, c.key),
};

PDFOperator setStrokingColor(Color color) => switch (color) {
  Grayscale c => setStrokingGrayscaleColor(c.gray),
  RGB c => setStrokingRgbColor(c.red, c.green, c.blue),
  CMYK c => setStrokingCmykColor(c.cyan, c.magenta, c.yellow, c.key),
};

// Marked content

PDFOperator beginMarkedContent(String tag) =>
    PDFOperator('BMC', <String>[_name(tag)]);

PDFOperator endMarkedContent() => _op('EMC');
