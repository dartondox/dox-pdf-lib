import 'dart:math' as math;

// Number, view box and dash readers of pdfme's SVG engine (pdf-lib fork,
// `api/svg.ts`), with the same quirks.

final RegExp _jsFloat = RegExp(
  r'^\s*[+-]?(?:Infinity|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)',
);

/// JavaScript's `parseFloat`: reads the number at the start of [value] and
/// ignores the rest (`'10px'` is 10). NaN when there is no number.
double jsParseFloat(String value) {
  String? m = _jsFloat.firstMatch(value)?.group(0);
  if (m == null) return double.nan;
  String s = m.trim();
  if (s.endsWith('Infinity')) {
    return s.startsWith('-') ? double.negativeInfinity : double.infinity;
  }
  // '1.' and '1.e5' are fine in JS, not in Dart.
  return double.parse(s.replaceFirst(RegExp(r'\.(?=[eE]|$)'), ''));
}

/// pdfme's `parseFloatValue`: null for a missing or bad value. A percent
/// value is a part of [reference].
double? parseFloatValue(String? value, [double reference = 1]) {
  if (value == null || value.isEmpty) return null;
  double v = jsParseFloat(value);
  if (v.isNaN) return null;
  if (value.endsWith('%')) return v * reference / 100;
  return v;
}

/// A box in SVG user units: a view box or a viewport.
class SvgBox {
  const SvgBox(this.x, this.y, this.width, this.height);

  /// pdfme's `parseViewBox`. Values are split on single spaces only, and a
  /// missing value is 0 0 1 1, like pdfme.
  factory SvgBox.parse(String viewBox) {
    List<double?> v = <double?>[
      for (String part in viewBox.split(' ')) parseFloatValue(part),
    ];
    double at(int i, double fallback) =>
        i < v.length && v[i] != null ? v[i]! : fallback;
    return SvgBox(at(0, 0), at(1, 0), at(2, 1), at(3, 1));
  }

  final double x;
  final double y;
  final double width;
  final double height;
}

/// One `stroke-dasharray` or `stroke-dashoffset` length, before percent
/// values are resolved.
typedef DashLength = ({double value, bool percent});

/// A resolved dash pattern. [array] is null when the element has none.
typedef DashPattern = ({List<double>? array, double offset});

/// `stroke-dasharray` and `stroke-dashoffset`, like pdfme.
abstract final class SvgDash {
  static final RegExp _length = RegExp(
    r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?(px|%)?$',
    caseSensitive: false,
  );

  /// One length. The whole token must be a finite number, maybe in px or %.
  static DashLength? parseLength(String token) {
    RegExpMatch? m = _length.firstMatch(token);
    if (m == null) return null;
    double v = jsParseFloat(token);
    if (!v.isFinite) return null;
    return (value: v, percent: m[1] == '%');
  }

  /// `stroke-dasharray`. Null when it is missing or bad, so the inherited
  /// pattern applies. Empty for a solid stroke.
  static List<DashLength>? parseArray(String? value) {
    if (value == null || value.isEmpty) return null;
    String trimmed = value.trim();
    if (trimmed.toLowerCase() == 'none') return <DashLength>[];
    List<DashLength?> dashes = <DashLength?>[
      for (String d in trimmed.split(RegExp(r'\s*,\s*|\s+')))
        if (d.isNotEmpty) parseLength(d),
    ];
    if (dashes.isEmpty) return null;
    if (dashes.any((DashLength? d) => d == null || d.value < 0)) return null;
    List<DashLength> lengths = dashes.cast<DashLength>();
    if (lengths.every((DashLength d) => d.value == 0)) return <DashLength>[];
    // an odd count is repeated to get an even count
    return lengths.length.isOdd
        ? <DashLength>[...lengths, ...lengths]
        : lengths;
  }

  /// `stroke-dashoffset`. Null when it is missing or bad.
  static DashLength? parseOffset(String? value) =>
      value == null || value.isEmpty ? null : parseLength(value.trim());

  /// pdfme's `resolveDashPattern`: percent values are parts of the
  /// normalized diagonal of [viewBox]; the offset is wrapped into the
  /// pattern length.
  static DashPattern resolve(
    List<DashLength>? array,
    DashLength? offset,
    SvgBox viewBox,
  ) {
    if (array == null) return (array: null, offset: 0);
    double reference = math.sqrt(
      (viewBox.width * viewBox.width + viewBox.height * viewBox.height) / 2,
    );
    double length(DashLength l) =>
        l.percent ? l.value * reference / 100 : l.value;
    List<double> lengths = <double>[for (DashLength l in array) length(l)];
    double total = lengths.fold(0, (double sum, double d) => sum + d);
    if (total <= 0 || !total.isFinite) return (array: <double>[], offset: 0);
    double o = offset == null ? 0 : length(offset);
    return (array: lengths, offset: ((o % total) + total) % total);
  }
}
