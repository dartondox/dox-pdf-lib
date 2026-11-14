import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import '../color.dart';
import '../constants.dart';
import '../fonts/font_metrics.dart';
import '../layout.dart';
import '../plugin.dart';
import '../schema.dart';
import 'text_box.dart';
import 'text_measure.dart';
import 'wrap.dart';

/// The `text` schema type, like pdfme's text plugin.
///
/// Props: `fontName`, `fontSize` (13), `alignment` (`left`, `center`,
/// `right`, `justify`), `verticalAlignment` (`top`, `middle`, `bottom`),
/// `lineHeight` (1), `characterSpacing` (0), `fontColor`,
/// `backgroundColor`, `borderColor`, `borderWidth`, `padding`,
/// `underline`, `strikethrough` and `dynamicFontSize`.
class TextPlugin extends SchemaPlugin {
  const TextPlugin();

  static const double defaultFontSize = 13;

  @override
  String get type => 'text';

  @override
  Future<void> pdf(RenderProps props) async {
    String value = props.value;
    if (value.isEmpty) return;
    Schema schema = props.schema;
    PDFPage page = props.page;
    double pageHeight = page.getHeight();
    PdfLayout box = PdfLayout.of(
      schema,
      pageHeight,
      applyRotateTranslate: false,
    );
    Point pivot = (
      x: box.x + box.width / 2,
      y: pageHeight - mm2pt(schema.y) - box.height / 2,
    );
    TextBoxDecoration(schema, box, pivot, props.options.colorType).draw(page);

    String fontName = props.fonts.resolve(schema.string('fontName'));
    PDFFont font = await props.fonts.embed(fontName);
    FontMetrics metrics = props.fonts.metrics(schema.string('fontName'));
    TextMeasure measure = TextMeasure(font, metrics);
    _TextLines(
      props: props,
      box: box,
      pivot: pivot,
      area: BoxArea.of(schema),
      font: font,
      measure: measure,
    ).draw();
  }
}

/// Lays out and draws the lines of one text schema.
class _TextLines {
  _TextLines({
    required this.props,
    required this.box,
    required this.pivot,
    required this.area,
    required this.font,
    required this.measure,
  }) : schema = props.schema;

  final RenderProps props;
  final Schema schema;
  final PdfLayout box;
  final Point pivot;
  final BoxArea area;
  final PDFFont font;
  final TextMeasure measure;

  String get _alignment => schema.string('alignment') ?? 'left';

  String get _verticalAlignment => schema.string('verticalAlignment') ?? 'top';

  double get _lineHeight => schema.number('lineHeight') ?? 1;

  double get _characterSpacing => schema.number('characterSpacing') ?? 0;

  /// pdfme's font size: the dynamic size, or `fontSize`, or 13.
  double _fontSize() {
    double? fontSize = schema.number('fontSize');
    DynamicFontSize? dynamic = DynamicFontSize.fromJson(
      schema['dynamicFontSize'],
    );
    bool expand = schema.string('overflow') == 'expand' && props.basePdf is Map;
    if (dynamic == null || expand) {
      return fontSize ?? TextPlugin.defaultFontSize;
    }
    // pdfme: `fontSize || 13`, so 0 is the default too
    return dynamic.resolveSize(
      measure: measure,
      value: props.value,
      startSize: fontSize == null || fontSize == 0
          ? TextPlugin.defaultFontSize
          : fontSize,
      boxWidth: area.width,
      boxHeight: area.height,
      characterSpacing: _characterSpacing,
      lineHeight: _lineHeight,
    );
  }

  void draw() {
    double fontSize = _fontSize();
    double lineHeight = _lineHeight;
    double characterSpacing = _characterSpacing;
    HexAlpha fontColor = splitHexAlpha(
      (schema.string('fontColor') ?? '').isEmpty
          ? '#000000'
          : schema.string('fontColor')!,
    );
    Color? color = hexToPrintingColor(fontColor.color, props.options.colorType);
    double? opacity = applyAlphaToOpacity(box.opacity, fontColor.alpha);

    double contentX = box.x + mm2pt(area.leftInset);
    double contentY = box.y + mm2pt(area.bottomInset);
    double contentWidth = mm2pt(area.width);
    double contentHeight = mm2pt(area.height);

    double firstLineHeight = measure.metrics.heightAtSize(fontSize);
    double descent = measure.metrics.descentAtSize(fontSize);
    double half = lineHeight == 0 ? 0 : (lineHeight - 1) * fontSize / 2;
    List<WrapLine> lines = measure.wrap(
      props.value,
      fontSize,
      characterSpacing,
      contentWidth,
    );

    bool decorated =
        schema.boolean('underline') || schema.boolean('strikethrough');
    bool needsWidth = _alignment != 'left' || decorated;

    double yOffset = 0;
    String vAlign = _verticalAlignment;
    if (vAlign == 'top') {
      yOffset = firstLineHeight + half;
    } else {
      double others = lineHeight * fontSize * (lines.length - 1);
      if (vAlign == 'bottom') {
        yOffset = contentHeight - others + descent - half;
      } else if (vAlign == 'middle') {
        yOffset =
            (contentHeight - others - firstLineHeight + descent) / 2 +
            firstLineHeight;
      }
    }

    for (int row = 0; row < lines.length; row++) {
      WrapLine line = lines[row];
      double textWidth = needsWidth
          ? measure.width(line.text, fontSize, characterSpacing)
          : 0;
      LineAlignment align = getLineAlignment(
        text: line.text,
        width: textWidth,
        hardBreak: line.hardBreak,
        containerWidth: contentWidth,
        alignment: _alignment,
      );
      double xLine = contentX + align.x;
      double yLine =
          contentY + contentHeight - yOffset - lineHeight * fontSize * row;
      if (decorated && textWidth > 0) {
        double textHeight = firstLineHeight;
        if (schema.boolean('strikethrough')) {
          _decoration(
            xLine,
            yLine + textHeight / 3,
            textWidth,
            fontSize,
            color,
            opacity,
          );
        }
        if (schema.boolean('underline')) {
          _decoration(
            xLine,
            yLine - textHeight / 12,
            textWidth,
            fontSize,
            color,
            opacity,
          );
        }
      }
      if (box.rotate != 0) {
        Point p = rotatePoint((x: xLine, y: yLine), pivot, box.rotate);
        xLine = p.x;
        yLine = p.y;
      }
      props.page.pushOperators(<PDFOperator>[
        setCharacterSpacing(characterSpacing + align.extraCharacterSpacing),
      ]);
      props.page.drawText(
        // pdfme: Acrobat shows an error for an empty text
        line.text.isEmpty ? '\r\n' : line.text,
        x: xLine,
        y: yLine,
        rotate: degrees(box.rotate),
        size: fontSize,
        color: color,
        lineHeight: lineHeight * fontSize,
        font: font,
        opacity: opacity,
      );
    }
    // pdfme sets `Tc` outside q/Q and leaves it set. Set it back to 0, so
    // text drawn later on the page (barcode text, SVG text, other plugins)
    // does not get this spacing.
    props.page.pushOperators(<PDFOperator>[setCharacterSpacing(0)]);
  }

  /// An underline or strikethrough line at [y], `1 pt` longer than the text.
  void _decoration(
    double x,
    double y,
    double textWidth,
    double fontSize,
    Color? color,
    double? opacity,
  ) {
    props.page.drawLine(
      start: rotatePoint((x: x, y: y), pivot, box.rotate),
      end: rotatePoint((x: x + textWidth + 1, y: y), pivot, box.rotate),
      thickness: fontSize / 12,
      color: color,
      opacity: opacity,
    );
  }
}
