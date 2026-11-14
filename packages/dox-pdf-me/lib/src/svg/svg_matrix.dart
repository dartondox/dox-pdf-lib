import 'dart:math' as math;

import 'svg_values.dart';

/// A PDF transformation matrix `[a b c d e f]`, like pdfme's SVG engine.
///
/// SVG transforms are turned into PDF space here: the y axis points up, so
/// `translate` uses `-ty`, and `rotate` and `skew` turn the other way.
class SvgMatrix {
  const SvgMatrix(this.a, this.b, this.c, this.d, this.e, this.f);

  static const SvgMatrix identity = SvgMatrix(1, 0, 0, 1, 0, 0);

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  List<double> get values => <double>[a, b, c, d, e, f];

  /// `this * other` (pdfme's `combineMatrix`): [other] works first.
  SvgMatrix multiply(SvgMatrix o) => SvgMatrix(
    a * o.a + c * o.b,
    b * o.a + d * o.b,
    a * o.c + c * o.d,
    b * o.c + d * o.d,
    a * o.e + c * o.f + e,
    b * o.e + d * o.f + f,
  );

  /// Moves the point [x], [y] with this matrix.
  ({double x, double y}) apply(double x, double y) =>
      (x: a * x + c * y + e, y: b * x + d * y + f);

  /// This matrix followed by the transform [name] with [args].
  SvgMatrix then(String name, List<double> args) =>
      multiply(SvgMatrix.transform(name, args));

  /// pdfme's `transformationToMatrix`. An unknown name is the identity.
  /// Missing arguments are NaN, like `undefined` in JS math.
  factory SvgMatrix.transform(String name, List<double> args) {
    double arg(int i, double fallback) => i < args.length ? args[i] : fallback;
    switch (name) {
      case 'scale' || 'scaleX' || 'scaleY':
        double sx = arg(0, double.nan);
        double sy = arg(1, sx);
        return SvgMatrix(
          name == 'scaleY' ? 1 : sx,
          0,
          0,
          name == 'scaleX' ? 1 : sy,
          0,
          0,
        );
      case 'translate' || 'translateX' || 'translateY':
        double tx = arg(0, double.nan);
        double ty = arg(1, tx);
        return SvgMatrix(
          1,
          0,
          0,
          1,
          name == 'translateY' ? 0 : tx,
          name == 'translateX' ? 0 : -ty,
        );
      case 'rotate':
        double x = arg(1, 0);
        double y = arg(2, 0);
        double r = -arg(0, double.nan) * math.pi / 180;
        SvgMatrix turn = SvgMatrix(
          math.cos(r),
          math.sin(r),
          -math.sin(r),
          math.cos(r),
          0,
          0,
        );
        // around a point: translate * rotate * -translate
        return SvgMatrix.transform('translate', <double>[
          x,
          y,
        ]).multiply(turn).then('translate', <double>[-x, -y]);
      case 'skewX' || 'skewY':
        double skew = math.tan(-arg(0, double.nan) * math.pi / 180);
        return SvgMatrix(
          1,
          name == 'skewY' ? skew : 0,
          name == 'skewX' ? skew : 0,
          1,
          0,
          0,
        );
      case 'matrix':
        SvgMatrix flip = const SvgMatrix(1, 0, 0, -1, 0, 0);
        SvgMatrix m = SvgMatrix(
          arg(0, double.nan),
          arg(1, double.nan),
          arg(2, double.nan),
          arg(3, double.nan),
          arg(4, double.nan),
          arg(5, double.nan),
        );
        return flip.multiply(m).multiply(flip);
      default:
        return identity;
    }
  }

  static final RegExp _transform = RegExp(r'(\w+)\((.+?)\)');
  static final RegExp _argSplit = RegExp(r'\s*,\s*|\s+');

  /// This matrix followed by each transform of the SVG [list], eg.
  /// `translate(10 20) rotate(45)`.
  SvgMatrix thenList(String list) {
    SvgMatrix m = this;
    for (RegExpMatch t in _transform.allMatches(list)) {
      List<double> args = <double>[
        for (String v in t[2]!.split(_argSplit))
          if (v.isNotEmpty) jsParseFloat(v),
      ];
      m = m.then(t[1]!, args);
    }
    return m;
  }

  @override
  String toString() => 'SvgMatrix($a, $b, $c, $d, $e, $f)';
}
