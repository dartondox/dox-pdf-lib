import 'dart:math' as math;

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import 'svg_values.dart';

/// A CSS color: the RGB color and its alpha. [alpha] is null when the color
/// is opaque (alpha 1), like the `color` npm package that pdfme uses.
typedef CssColorValue = ({RGB rgb, double? alpha});

/// Reads CSS color strings like pdf-lib's `colorString` (the `color` npm
/// package): names, `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`,
/// `rgba()`, `hsl()` and `hsla()`.
abstract final class CssColor {
  static final RegExp _shortHex = RegExp(
    r'^#([a-f\d]{3,4})$',
    caseSensitive: false,
  );
  static final RegExp _longHex = RegExp(
    r'^#([a-f\d]{6})([a-f\d]{2})?$',
    caseSensitive: false,
  );
  static final RegExp _rgb = RegExp(
    r'^rgba?\(\s*([+-]?\d+)(?=[\s,])\s*(?:,\s*)?([+-]?\d+)(?=[\s,])\s*'
    r'(?:,\s*)?([+-]?\d+)\s*(?:[,|/]\s*([+-]?[\d.]+)(%?)\s*)?\)$',
  );
  static final RegExp _rgbPercent = RegExp(
    r'^rgba?\(\s*([+-]?[\d.]+)%\s*,?\s*([+-]?[\d.]+)%\s*,?\s*([+-]?[\d.]+)%'
    r'\s*(?:[,|/]\s*([+-]?[\d.]+)(%?)\s*)?\)$',
  );
  static final RegExp _hsl = RegExp(
    r'^hsla?\(\s*([+-]?(?:\d{0,3}\.)?\d+)(?:deg)?\s*,?\s*([+-]?[\d.]+)%\s*,?'
    r'\s*([+-]?[\d.]+)%\s*(?:[,|/]\s*([+-]?(?=\.\d|\d)(?:0|[1-9]\d*)?'
    r'(?:\.\d*)?(?:[eE][+-]?\d+)?)\s*)?\)$',
  );

  /// Parses [input]. Throws an [ArgumentError] for a value it can not read,
  /// like pdfme (eg. `url(#gradient)`).
  static CssColorValue parse(String input) {
    String s = input.trim();
    List<double>? rgba =
        _hex(s) ?? _rgbFunction(s) ?? _hslFunction(s) ?? _named(s);
    if (rgba == null) {
      throw ArgumentError('Unable to parse color from string: $input');
    }
    double alpha = rgba[3];
    return (
      rgb: rgb(rgba[0] / 255, rgba[1] / 255, rgba[2] / 255),
      alpha: alpha == 1 ? null : alpha,
    );
  }

  static List<double>? _hex(String s) {
    RegExpMatch? m = _longHex.firstMatch(s);
    if (m != null) {
      String h = m[1]!;
      String? a = m[2];
      return <double>[
        for (int i = 0; i < 6; i += 2)
          int.parse(h.substring(i, i + 2), radix: 16).toDouble(),
        a == null ? 1 : _hexAlpha(a),
      ];
    }
    m = _shortHex.firstMatch(s);
    if (m == null) return null;
    String h = m[1]!;
    return <double>[
      for (int i = 0; i < 3; i++) int.parse(h[i] * 2, radix: 16).toDouble(),
      h.length == 4 ? _hexAlpha(h[3] * 2) : 1,
    ];
  }

  /// color-string rounds a hex alpha to 2 decimals.
  static double _hexAlpha(String hex) =>
      (int.parse(hex, radix: 16) / 255 * 100).round() / 100;

  static List<double>? _rgbFunction(String s) {
    RegExpMatch? m = _rgb.firstMatch(s);
    bool percent = m == null;
    m ??= _rgbPercent.firstMatch(s);
    if (m == null) return null;
    double alpha = 1;
    if (m[4] != null) {
      // JS parseFloat: '0.5.1' reads as 0.5
      alpha = jsParseFloat(m[4]!);
      if (m[5]!.isNotEmpty) alpha *= 0.01;
    }
    List<double> out = <double>[];
    for (int i = 1; i <= 3; i++) {
      double v = jsParseFloat(m[i]!);
      out.add(_clamp(percent ? (v * 2.55).roundToDouble() : v, 0, 255));
    }
    return <double>[...out, _clamp(alpha, 0, 1)];
  }

  static List<double>? _hslFunction(String s) {
    RegExpMatch? m = _hsl.firstMatch(s);
    if (m == null) return null;
    double hue = ((jsParseFloat(m[1]!) % 360) + 360) % 360;
    double sat = _clamp(jsParseFloat(m[2]!), 0, 100);
    double light = _clamp(jsParseFloat(m[3]!), 0, 100);
    double alpha = m[4] == null ? 1 : _clamp(jsParseFloat(m[4]!), 0, 1);
    return <double>[..._hslToRgb(hue, sat, light), alpha];
  }

  /// color-convert's `hsl.rgb`, not rounded.
  static List<double> _hslToRgb(double hue, double sat, double light) {
    double h = hue / 360;
    double s = sat / 100;
    double l = light / 100;
    if (s == 0) return <double>[l * 255, l * 255, l * 255];
    double t2 = l < 0.5 ? l * (1 + s) : l + s - l * s;
    double t1 = 2 * l - t2;
    List<double> out = <double>[];
    for (int i = 0; i < 3; i++) {
      double t3 = h + 1 / 3 * -(i - 1);
      if (t3 < 0) t3++;
      if (t3 > 1) t3--;
      double v;
      if (6 * t3 < 1) {
        v = t1 + (t2 - t1) * 6 * t3;
      } else if (2 * t3 < 1) {
        v = t2;
      } else if (3 * t3 < 2) {
        v = t1 + (t2 - t1) * (2 / 3 - t3) * 6;
      } else {
        v = t1;
      }
      out.add(v * 255);
    }
    return out;
  }

  static List<double>? _named(String s) {
    // ponytail: names match in any case, like browsers.
    int? hex = _names[s.toLowerCase()];
    if (hex == null) return null;
    return <double>[
      ((hex >> 16) & 0xff).toDouble(),
      ((hex >> 8) & 0xff).toDouble(),
      (hex & 0xff).toDouble(),
      1,
    ];
  }

  static double _clamp(double v, double min, double max) =>
      math.min(math.max(min, v), max);

  /// The CSS color names.
  static const Map<String, int> _names = <String, int>{
    'aliceblue': 0xf0f8ff,
    'antiquewhite': 0xfaebd7,
    'aqua': 0x00ffff,
    'aquamarine': 0x7fffd4,
    'azure': 0xf0ffff,
    'beige': 0xf5f5dc,
    'bisque': 0xffe4c4,
    'black': 0x000000,
    'blanchedalmond': 0xffebcd,
    'blue': 0x0000ff,
    'blueviolet': 0x8a2be2,
    'brown': 0xa52a2a,
    'burlywood': 0xdeb887,
    'cadetblue': 0x5f9ea0,
    'chartreuse': 0x7fff00,
    'chocolate': 0xd2691e,
    'coral': 0xff7f50,
    'cornflowerblue': 0x6495ed,
    'cornsilk': 0xfff8dc,
    'crimson': 0xdc143c,
    'cyan': 0x00ffff,
    'darkblue': 0x00008b,
    'darkcyan': 0x008b8b,
    'darkgoldenrod': 0xb8860b,
    'darkgray': 0xa9a9a9,
    'darkgreen': 0x006400,
    'darkgrey': 0xa9a9a9,
    'darkkhaki': 0xbdb76b,
    'darkmagenta': 0x8b008b,
    'darkolivegreen': 0x556b2f,
    'darkorange': 0xff8c00,
    'darkorchid': 0x9932cc,
    'darkred': 0x8b0000,
    'darksalmon': 0xe9967a,
    'darkseagreen': 0x8fbc8f,
    'darkslateblue': 0x483d8b,
    'darkslategray': 0x2f4f4f,
    'darkslategrey': 0x2f4f4f,
    'darkturquoise': 0x00ced1,
    'darkviolet': 0x9400d3,
    'deeppink': 0xff1493,
    'deepskyblue': 0x00bfff,
    'dimgray': 0x696969,
    'dimgrey': 0x696969,
    'dodgerblue': 0x1e90ff,
    'firebrick': 0xb22222,
    'floralwhite': 0xfffaf0,
    'forestgreen': 0x228b22,
    'fuchsia': 0xff00ff,
    'gainsboro': 0xdcdcdc,
    'ghostwhite': 0xf8f8ff,
    'gold': 0xffd700,
    'goldenrod': 0xdaa520,
    'gray': 0x808080,
    'green': 0x008000,
    'greenyellow': 0xadff2f,
    'grey': 0x808080,
    'honeydew': 0xf0fff0,
    'hotpink': 0xff69b4,
    'indianred': 0xcd5c5c,
    'indigo': 0x4b0082,
    'ivory': 0xfffff0,
    'khaki': 0xf0e68c,
    'lavender': 0xe6e6fa,
    'lavenderblush': 0xfff0f5,
    'lawngreen': 0x7cfc00,
    'lemonchiffon': 0xfffacd,
    'lightblue': 0xadd8e6,
    'lightcoral': 0xf08080,
    'lightcyan': 0xe0ffff,
    'lightgoldenrodyellow': 0xfafad2,
    'lightgray': 0xd3d3d3,
    'lightgreen': 0x90ee90,
    'lightgrey': 0xd3d3d3,
    'lightpink': 0xffb6c1,
    'lightsalmon': 0xffa07a,
    'lightseagreen': 0x20b2aa,
    'lightskyblue': 0x87cefa,
    'lightslategray': 0x778899,
    'lightslategrey': 0x778899,
    'lightsteelblue': 0xb0c4de,
    'lightyellow': 0xffffe0,
    'lime': 0x00ff00,
    'limegreen': 0x32cd32,
    'linen': 0xfaf0e6,
    'magenta': 0xff00ff,
    'maroon': 0x800000,
    'mediumaquamarine': 0x66cdaa,
    'mediumblue': 0x0000cd,
    'mediumorchid': 0xba55d3,
    'mediumpurple': 0x9370db,
    'mediumseagreen': 0x3cb371,
    'mediumslateblue': 0x7b68ee,
    'mediumspringgreen': 0x00fa9a,
    'mediumturquoise': 0x48d1cc,
    'mediumvioletred': 0xc71585,
    'midnightblue': 0x191970,
    'mintcream': 0xf5fffa,
    'mistyrose': 0xffe4e1,
    'moccasin': 0xffe4b5,
    'navajowhite': 0xffdead,
    'navy': 0x000080,
    'oldlace': 0xfdf5e6,
    'olive': 0x808000,
    'olivedrab': 0x6b8e23,
    'orange': 0xffa500,
    'orangered': 0xff4500,
    'orchid': 0xda70d6,
    'palegoldenrod': 0xeee8aa,
    'palegreen': 0x98fb98,
    'paleturquoise': 0xafeeee,
    'palevioletred': 0xdb7093,
    'papayawhip': 0xffefd5,
    'peachpuff': 0xffdab9,
    'peru': 0xcd853f,
    'pink': 0xffc0cb,
    'plum': 0xdda0dd,
    'powderblue': 0xb0e0e6,
    'purple': 0x800080,
    'rebeccapurple': 0x663399,
    'red': 0xff0000,
    'rosybrown': 0xbc8f8f,
    'royalblue': 0x4169e1,
    'saddlebrown': 0x8b4513,
    'salmon': 0xfa8072,
    'sandybrown': 0xf4a460,
    'seagreen': 0x2e8b57,
    'seashell': 0xfff5ee,
    'sienna': 0xa0522d,
    'silver': 0xc0c0c0,
    'skyblue': 0x87ceeb,
    'slateblue': 0x6a5acd,
    'slategray': 0x708090,
    'slategrey': 0x708090,
    'snow': 0xfffafa,
    'springgreen': 0x00ff7f,
    'steelblue': 0x4682b4,
    'tan': 0xd2b48c,
    'teal': 0x008080,
    'thistle': 0xd8bfd8,
    'tomato': 0xff6347,
    'turquoise': 0x40e0d0,
    'violet': 0xee82ee,
    'wheat': 0xf5deb3,
    'white': 0xffffff,
    'whitesmoke': 0xf5f5f5,
    'yellow': 0xffff00,
    'yellowgreen': 0x9acd32,
  };
}
