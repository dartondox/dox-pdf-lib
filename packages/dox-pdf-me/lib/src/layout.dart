import 'dart:math' as math;

import 'constants.dart';
import 'model/schema.dart';
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

  /// pdfme's `convertForPdfLayoutProps` for [schema] on a page
  /// [pageHeight] points high. [x], [y] is the bottom left corner. With
  /// [applyRotateTranslate], that corner is turned around the box center,
  /// so pdf-lib (which turns around the corner) puts the box where the
  /// designer shows it.
  factory PdfLayout.of(
    Schema schema,
    double pageHeight, {
    bool applyRotateTranslate = true,
  }) => _layout(
    schema.position.x,
    schema.position.y,
    schema.width,
    schema.height,
    schema.rotate,
    schema.opacity,
    pageHeight,
    applyRotateTranslate,
  );

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

/// [PdfLayout.of] for the JSON form of a schema.
PdfLayout layoutOf(
  RawSchema schema,
  double pageHeight, {
  bool applyRotateTranslate = true,
}) => _layout(
  schema.x,
  schema.y,
  schema.width,
  schema.height,
  schema.rotate,
  schema.opacity,
  pageHeight,
  applyRotateTranslate,
);

PdfLayout _layout(
  double schemaX,
  double schemaY,
  double schemaWidth,
  double schemaHeight,
  double? r,
  double? opacity,
  double pageHeight,
  bool applyRotateTranslate,
) {
  // the schema turns clockwise, PDF turns counter-clockwise
  double rotate = r == null || r == 0 ? 0 : -r;
  double width = mm2pt(schemaWidth);
  double height = mm2pt(schemaHeight);
  double x = mm2pt(schemaX);
  double y = pageHeight - mm2pt(schemaY) - height;
  if (rotate != 0 && applyRotateTranslate) {
    Point pivot = (
      x: x + width / 2,
      y: pageHeight - mm2pt(schemaY) - height / 2,
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
    opacity: opacity,
  );
}
