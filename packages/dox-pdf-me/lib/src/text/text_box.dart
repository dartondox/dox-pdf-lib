import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import '../color.dart';
import '../constants.dart';
import '../layout.dart';
import '../options.dart';
import '../schema.dart';

/// Sizes of the 4 sides of a box, in millimetres. A missing side is 0.
class BoxSides {
  const BoxSides(this.top, this.right, this.bottom, this.left);

  /// pdfme's `normalizeBoxDimension`: only a map has sides.
  factory BoxSides.fromJson(Object? json) {
    double side(String key) {
      Object? v = json is Map ? json[key] : null;
      return v is num ? v.toDouble() : 0;
    }

    return BoxSides(side('top'), side('right'), side('bottom'), side('left'));
  }

  final double top;
  final double right;
  final double bottom;
  final double left;

  bool get any => top > 0 || right > 0 || bottom > 0 || left > 0;
}

/// The content area of a text box: the box minus border and padding, like
/// pdfme's `getBoxContentArea`. Millimetres.
class BoxArea {
  const BoxArea({
    required this.width,
    required this.height,
    required this.leftInset,
    required this.bottomInset,
  });

  factory BoxArea.of(RawSchema schema) {
    BoxSides border = BoxSides.fromJson(schema['borderWidth']);
    BoxSides padding = BoxSides.fromJson(schema['padding']);
    double left = border.left + padding.left;
    double top = border.top + padding.top;
    double right = border.right + padding.right;
    double bottom = border.bottom + padding.bottom;
    double clamp(double v) => v < 0 ? 0 : v;
    return BoxArea(
      width: clamp(schema.width - left - right),
      height: clamp(schema.height - top - bottom),
      leftInset: left,
      bottomInset: bottom,
    );
  }

  final double width;
  final double height;
  final double leftInset;
  final double bottomInset;
}

/// The background and the border of a text box, like pdfme's
/// `drawTextBoxDecoration`. The border is 4 filled bars.
class TextBoxDecoration {
  TextBoxDecoration(this.schema, this.box, this.pivot, this.colorType);

  final RawSchema schema;
  final PdfLayout box;
  final Point pivot;
  final ColorType? colorType;

  void draw(PDFPage page) {
    String? background = schema.string('backgroundColor');
    if (background != null && background.isNotEmpty) {
      HexAlpha c = splitHexAlpha(background);
      _rect(page, box.x, box.y, box.width, box.height, c);
    }
    String? borderColor = schema.string('borderColor');
    BoxSides border = BoxSides.fromJson(schema['borderWidth']);
    if (borderColor == null || borderColor.isEmpty || !border.any) return;
    HexAlpha c = splitHexAlpha(borderColor);
    double top = mm2pt(border.top);
    double right = mm2pt(border.right);
    double bottom = mm2pt(border.bottom);
    double left = mm2pt(border.left);
    double x = box.x;
    double y = box.y;
    double w = box.width;
    double h = box.height;
    _rect(page, x, y + h - top, w, top, c);
    _rect(page, x + w - right, y, right, h, c);
    _rect(page, x, y, w, bottom, c);
    _rect(page, x, y, left, h, c);
  }

  void _rect(
    PDFPage page,
    double x,
    double y,
    double width,
    double height,
    HexAlpha c,
  ) {
    Color? color = hexToPrintingColor(c.color, colorType);
    if (color == null || width <= 0 || height <= 0) return;
    Point p = box.rotate == 0
        ? (x: x, y: y)
        : rotatePoint((x: x, y: y), pivot, box.rotate);
    page.drawRectangle(
      x: p.x,
      y: p.y,
      width: width,
      height: height,
      rotate: degrees(box.rotate),
      color: color,
      opacity: (schema.opacity ?? 1) * c.alpha,
    );
  }
}
