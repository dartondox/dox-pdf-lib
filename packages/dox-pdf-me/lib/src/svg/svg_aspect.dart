import 'svg_matrix.dart';

/// A rectangle in SVG user units.
typedef SvgRect = ({double x, double y, double width, double height});

/// `preserveAspectRatio` math of pdfme's SVG engine, with its quirks:
///
/// - only the exact values `none` and `xMinYMin` ... `xMaxYMax` are known;
///   anything else (also `xMinYMin meet`) is centered like `xMidYMid`.
/// - `slice` is not done.
/// - some offsets are odd (`xMaxYMin` moves down by half, `xMinYMid` by
///   all), like pdfme.
abstract final class SvgAspectRatio {
  /// The `[x, y]` offset for the free space [dx], [dy].
  static List<double> _offset(String? align, double dx, double dy) =>
      switch (align) {
        'xMinYMin' => <double>[0, 0],
        'xMidYMin' => <double>[dx / 2, 0],
        'xMaxYMin' => <double>[dx, dy / 2],
        'xMinYMid' => <double>[0, dy],
        'xMaxYMid' => <double>[dx, dy / 2],
        'xMinYMax' => <double>[0, dy],
        'xMidYMax' => <double>[dx / 2, dy],
        'xMaxYMax' => <double>[dx, dy],
        _ => <double>[dx / 2, dy / 2],
      };

  /// pdfme's `getAspectRatioTransformation`: the matrix of the clip box and
  /// the matrix of the content, for a view box of [width] x [height] drawn
  /// into [targetWidth] x [targetHeight].
  ///
  /// The `meet` scale has pdfme's bug: it is the y scale when the target is
  /// wider than tall, else the x scale.
  static ({SvgMatrix clipBox, SvgMatrix content}) transform(
    SvgMatrix matrix,
    double width,
    double height,
    double targetWidth,
    double targetHeight,
    String? preserveAspectRatio,
  ) {
    double scaleX = targetWidth / width;
    double scaleY = targetHeight / height;
    SvgMatrix box = matrix.then('scale', <double>[scaleX, scaleY]);
    if (preserveAspectRatio == 'none') return (clipBox: box, content: box);
    double scale = targetWidth > targetHeight ? scaleY : scaleX;
    List<double> o = _offset(
      preserveAspectRatio,
      targetWidth - width * scale,
      targetHeight - height * scale,
    );
    SvgMatrix content = matrix.then('translate', o).then('scale', <double>[
      scale,
    ]);
    return (clipBox: box, content: content);
  }

  /// pdfme's `getFittingRectangle`, for `<image>`: where an image of
  /// [width] x [height] goes in [targetWidth] x [targetHeight].
  static SvgRect fit(
    double width,
    double height,
    double targetWidth,
    double targetHeight,
    String? preserveAspectRatio,
  ) {
    if (preserveAspectRatio == 'none') {
      return (x: 0, y: 0, width: targetWidth, height: targetHeight);
    }
    double ratio = width / height;
    double targetRatio = targetWidth / targetHeight;
    double w = targetRatio > ratio ? ratio * targetHeight : targetWidth;
    double h = targetRatio >= ratio ? targetHeight : targetWidth / ratio;
    List<double> o = _offset(
      preserveAspectRatio,
      targetWidth - w,
      targetHeight - h,
    );
    return (x: o[0], y: o[1], width: w, height: h);
  }
}
