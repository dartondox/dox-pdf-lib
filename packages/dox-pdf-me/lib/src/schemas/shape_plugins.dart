import 'dart:math' as math;

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import '../color.dart';
import '../constants.dart';
import '../layout.dart';
import '../plugin.dart';
import '../schema.dart';

/// The `line` schema type: a horizontal line through the middle of the box.
/// The box height is the line thickness. Prop: `color`.
class LinePlugin extends SchemaPlugin {
  const LinePlugin();

  @override
  String get type => 'line';

  @override
  Future<void> pdf(RenderProps props) async {
    Schema schema = props.schema;
    String? hex = schema.string('color');
    if (schema.width == 0 || schema.height == 0 || hex == null || hex.isEmpty) {
      return;
    }
    PdfLayout box = PdfLayout.of(
      schema,
      props.page.getHeight(),
      applyRotateTranslate: false,
    );
    Point pivot = (x: box.x + box.width / 2, y: box.y + box.height / 2);
    double middle = box.y + box.height / 2;
    HexAlpha c = splitHexAlpha(hex);
    props.page.drawLine(
      start: rotatePoint((x: box.x, y: middle), pivot, box.rotate),
      end: rotatePoint((x: box.x + box.width, y: middle), pivot, box.rotate),
      thickness: box.height,
      color: hexToPrintingColor(c.color, props.options.colorType),
      opacity: applyAlphaToOpacity(box.opacity, c.alpha),
    );
  }
}

/// The `rectangle` and `ellipse` schema types. Props: `color` (fill),
/// `borderColor`, `borderWidth` (mm) and, for a rectangle, `radius` (mm).
/// The border is drawn inside the box.
class ShapePlugin extends SchemaPlugin {
  const ShapePlugin._(this.type);

  /// The `rectangle` type.
  const ShapePlugin.rectangle() : this._('rectangle');

  /// The `ellipse` type.
  const ShapePlugin.ellipse() : this._('ellipse');

  @override
  final String type;

  /// pdf-lib's KAPPA, for the round corners.
  static final double kappa = 4.0 * ((math.sqrt(2) - 1.0) / 3.0);

  @override
  Future<void> pdf(RenderProps props) async {
    Schema schema = props.schema;
    String fillHex = schema.string('color') ?? '';
    String borderHex = schema.string('borderColor') ?? '';
    if (fillHex.isEmpty && borderHex.isEmpty) return;
    double pageHeight = props.page.getHeight();
    PdfLayout box = PdfLayout.of(schema, pageHeight);
    PdfLayout plain = PdfLayout.of(
      schema,
      pageHeight,
      applyRotateTranslate: false,
    );
    double? bw = schema.number('borderWidth');
    double borderWidth = bw == null || bw == 0 ? 0 : mm2pt(bw);
    HexAlpha fill = splitHexAlpha(fillHex);
    HexAlpha border = splitHexAlpha(borderHex);
    _ShapeStyle style = _ShapeStyle(
      rotate: degrees(box.rotate),
      borderWidth: borderWidth,
      color: hexToPrintingColor(fill.color, props.options.colorType),
      borderColor: hexToPrintingColor(border.color, props.options.colorType),
      opacity: applyAlphaToOpacity(box.opacity, fill.alpha),
      borderOpacity: applyAlphaToOpacity(box.opacity, border.alpha),
    );
    if (type == 'ellipse') {
      _ellipse(props.page, plain, style);
    } else {
      _rectangle(props.page, box, style, schema.number('radius') ?? 0);
    }
  }

  void _ellipse(PDFPage page, PdfLayout plain, _ShapeStyle s) {
    page.drawEllipse(
      x: plain.x + plain.width / 2,
      y: plain.y + plain.height / 2,
      xScale: plain.width / 2 - s.borderWidth / 2,
      yScale: plain.height / 2 - s.borderWidth / 2,
      rotate: s.rotate,
      borderWidth: s.borderWidth,
      color: s.color,
      borderColor: s.borderColor,
      opacity: s.opacity,
      borderOpacity: s.borderOpacity,
    );
  }

  void _rectangle(PDFPage page, PdfLayout box, _ShapeStyle s, double radius) {
    double bw = s.borderWidth;
    Point corner = (x: box.x, y: box.y);
    Point inset = rotatePoint(
      (x: box.x + bw / 2, y: box.y + bw / 2),
      corner,
      box.rotate,
    );
    double width = box.width - bw;
    double height = box.height - bw;
    if (radius == 0) {
      page.drawRectangle(
        x: inset.x,
        y: inset.y,
        width: width,
        height: height,
        rotate: s.rotate,
        borderWidth: bw,
        color: s.color,
        borderColor: s.borderColor,
        opacity: s.opacity,
        borderOpacity: s.borderOpacity,
      );
      return;
    }
    // dox_pdf_lib's drawRectangle has no radius (pdf-lib 1.17 has none),
    // so draw pdfme's rounded path as an SVG path. It flips y.
    page.drawSvgPath(
      _roundedPath(width, height, mm2pt(radius)),
      x: inset.x,
      y: inset.y,
      rotate: s.rotate,
      borderWidth: bw,
      color: s.color,
      borderColor: s.borderColor,
      opacity: s.opacity,
      borderOpacity: s.borderOpacity,
    );
  }

  /// pdfme's rounded rectangle (operations.ts), y turned down for SVG.
  static String _roundedPath(double width, double height, double radius) {
    double r = radius;
    if (r > width / 2 || r > height / 2) r = math.min(width / 2, height / 2);
    double o = kappa * r;
    String p(double x, double y) => '$x ${-y}';
    return 'M ${p(0, r)} '
        'C ${p(0, r - o)} ${p(r - o, 0)} ${p(r, 0)} '
        'L ${p(width - r, 0)} '
        'C ${p(width - r + o, 0)} ${p(width, r - o)} ${p(width, r)} '
        'L ${p(width, height - r)} '
        'C ${p(width, height - r + o)} ${p(width - r + o, height)} '
        '${p(width - r, height)} '
        'L ${p(r, height)} '
        'C ${p(r - o, height)} ${p(0, height - r + o)} ${p(0, height - r)} Z';
  }
}

class _ShapeStyle {
  const _ShapeStyle({
    required this.rotate,
    required this.borderWidth,
    required this.color,
    required this.borderColor,
    required this.opacity,
    required this.borderOpacity,
  });

  final Rotation rotate;
  final double borderWidth;
  final Color? color;
  final Color? borderColor;
  final double? opacity;
  final double? borderOpacity;
}
