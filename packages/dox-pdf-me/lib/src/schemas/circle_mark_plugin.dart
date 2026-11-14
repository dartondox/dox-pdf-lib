import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import '../color.dart';
import '../constants.dart';
import '../layout.dart';
import '../plugin.dart';
import '../schema.dart';

/// The `circleMark` schema type: a circle (or ellipse) line around the
/// box when the value is `'true'`. Props: `color` (the line color, a hex
/// value) and `borderWidth` (mm). Nothing is drawn when the width, the
/// height or `borderWidth` is not above 0, or `color` is not a valid hex
/// color.
class CircleMarkPlugin extends SchemaPlugin {
  const CircleMarkPlugin();

  @override
  String get type => 'circleMark';

  @override
  Future<void> pdf(RenderProps props) async {
    Schema schema = props.schema;
    String? color = schema.string('color');
    double borderWidthMm = schema.number('borderWidth') ?? 0;
    if (props.value != 'true' ||
        schema.width <= 0 ||
        schema.height <= 0 ||
        borderWidthMm <= 0 ||
        color == null ||
        !isHexValid(color)) {
      return;
    }
    double borderWidth = mm2pt(borderWidthMm);
    double pageHeight = props.page.getHeight();
    PdfLayout box = PdfLayout.of(schema, pageHeight);
    PdfLayout plain = PdfLayout.of(
      schema,
      pageHeight,
      applyRotateTranslate: false,
    );
    double xScale = box.width / 2 - borderWidth / 2;
    double yScale = box.height / 2 - borderWidth / 2;
    if (xScale <= 0 || yScale <= 0) return;
    HexAlpha border = splitHexAlpha(color);
    props.page.drawEllipse(
      x: plain.x + box.width / 2,
      y: plain.y + box.height / 2,
      xScale: xScale,
      yScale: yScale,
      rotate: degrees(box.rotate),
      borderWidth: borderWidth,
      borderColor: hexToPrintingColor(border.color, props.options.colorType),
      borderOpacity: applyAlphaToOpacity(box.opacity, border.alpha),
    );
  }
}
