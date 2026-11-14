import 'dart:math' as math;

import 'constants.dart';
import 'schema.dart';

/// A point in PDF space (points, origin at the bottom left).
typedef Point = ({double x, double y});

/// The box of a schema in PDF space, like pdfme's
/// `convertForPdfLayoutProps`.
class PdfLayout {
  const PdfLayout({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.rotate,
    required this.opacity,
  });

  /// pdfme's `convertForPdfLayoutProps`. [x], [y] is the bottom left corner.
  /// With [applyRotateTranslate], that corner is turned around the box
  /// center, so pdf-lib (which turns around the corner) puts the box where
  /// the designer shows it.
  factory PdfLayout.of(
    Schema schema,
    double pageHeight, {
    bool applyRotateTranslate = true,
  }) {
    double? r = schema.rotate;
    // the schema turns clockwise, PDF turns counter-clockwise
    double rotate = r == null || r == 0 ? 0 : -r;
    double width = mm2pt(schema.width);
    double height = mm2pt(schema.height);
    double x = mm2pt(schema.x);
    double y = pageHeight - mm2pt(schema.y) - height;
    if (rotate != 0 && applyRotateTranslate) {
      Point pivot = (
        x: x + width / 2,
        y: pageHeight - mm2pt(schema.y) - height / 2,
      );
      Point p = rotatePoint((x: x, y: y), pivot, rotate);
      x = p.x;
      y = p.y;
    }
    return PdfLayout(
      x: x,
      y: y,
      width: width,
      height: height,
      rotate: rotate,
      opacity: schema.opacity,
    );
  }

  final double x;
  final double y;
  final double width;
  final double height;

  /// Degrees, counter-clockwise (the PDF way).
  final double rotate;

  final double? opacity;
}

/// Turns [point] around [pivot] by [angleDegrees] (counter-clockwise).
Point rotatePoint(Point point, Point pivot, double angleDegrees) {
  double a = angleDegrees * math.pi / 180;
  double dx = point.x - pivot.x;
  double dy = point.y - pivot.y;
  return (
    x: math.cos(a) * dx - math.sin(a) * dy + pivot.x,
    y: math.sin(a) * dx + math.cos(a) * dy + pivot.y,
  );
}
