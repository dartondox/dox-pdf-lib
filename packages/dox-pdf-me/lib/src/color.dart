import 'dart:math' as math;

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import 'options.dart';

final RegExp _validHex = RegExp(
  r'^#(?:[A-Fa-f0-9]{3,4}|[A-Fa-f0-9]{6}|[A-Fa-f0-9]{8})$',
);
final RegExp _alphaHex = RegExp(r'^(?:[0-9a-fA-F]{4}|[0-9a-fA-F]{8})$');

/// A hex color split into the color without alpha and the alpha (0 to 1).
typedef HexAlpha = ({String color, double alpha});

/// pdfme's `splitHexAlpha`: `#RGBA` and `#RRGGBBAA` give the color and the
/// alpha. Other values come back as they are, with alpha 1.
HexAlpha splitHexAlpha(String hexColor) {
  if (!hexColor.startsWith('#')) return (color: hexColor, alpha: 1);
  String hex = hexColor.substring(1);
  if (!_alphaHex.hasMatch(hex)) return (color: hexColor, alpha: 1);
  int rgbLength = hex.length == 4 ? 3 : 6;
  String alpha = hex.substring(rgbLength);
  return (
    color: '#${hex.substring(0, rgbLength)}',
    alpha: int.parse(alpha.length == 1 ? alpha * 2 : alpha, radix: 16) / 255,
  );
}

/// pdfme's `applyAlphaToOpacity`: alpha 1 keeps [opacity] (also null).
double? applyAlphaToOpacity(double? opacity, double alpha) =>
    alpha == 1 ? opacity : (opacity ?? 1) * alpha;

bool isHexValid(String hex) => _validHex.hasMatch(hex);

/// pdfme's `hex2PrintingColor`: null for an empty value, CMYK when
/// [colorType] is `cmyk`, else RGB. Throws for a bad hex value.
Color? hexToPrintingColor(String? hex, [ColorType? colorType]) {
  if (hex == null || hex.isEmpty) return null;
  if (!isHexValid(hex)) throw ArgumentError('Invalid hex color value $hex');
  List<int> c = _hexToRgb(hex);
  RGB color = rgb(c[0] / 255, c[1] / 255, c[2] / 255);
  return colorType == ColorType.cmyk ? rgbToCmyk(color) : color;
}

/// pdfme's `rgbColorToCmykColor`.
CMYK rgbToCmyk(RGB c) {
  double key = 1 - math.max(c.red, math.max(c.green, c.blue));
  double part(double v) => key == 1 ? 0 : (1 - v - key) / (1 - key);
  return cmyk(part(c.red), part(c.green), part(c.blue), key);
}

List<int> _hexToRgb(String hex) {
  String h = splitHexAlpha(hex).color.substring(1);
  if (h.length == 3) h = h.split('').map((String c) => c * 2).join();
  return <int>[
    for (int i = 0; i < 6; i += 2) int.parse(h.substring(i, i + 2), radix: 16),
  ];
}
