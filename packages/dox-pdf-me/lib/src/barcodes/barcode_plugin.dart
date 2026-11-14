import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import '../color.dart';
import '../layout.dart';
import '../plugin.dart';
import '../schema.dart';
import 'barcode_fit_layout.dart';
import 'barcode_painter.dart';
import 'barcode_symbol.dart';
import 'barcode_validator.dart';
import 'linear_symbols.dart';
import 'matrix_symbols.dart';

export 'barcode_validator.dart'
    show BarcodeInputException, barcodeTypes, validateBarcodeInput;

/// A pdfme barcode schema type (one of [barcodeTypes]), drawn as vectors.
///
/// Like pdfme's barcode `pdfRender`: a value that is not valid for the
/// type draws nothing. A value that passes that check but that bwip-js can
/// not encode throws a [BarcodeInputException] with the bwip-js message,
/// so `generate` fails like in pdfme. The background fills the whole box. 1D barcodes
/// are stretched to the box; QR code, GS1 Data Matrix and PDF417 keep
/// their ratio and are centered ("contain"). There is no quiet zone.
///
/// The bars and modules follow bwip-js (which pdfme uses). The human
/// readable text is drawn in Helvetica, not OCR-B: see [BarcodePainter].
class BarcodePlugin extends SchemaPlugin {
  const BarcodePlugin(this.type);

  @override
  final String type;

  static const String _fontKey = 'barcode:helvetica';

  @override
  Future<void> pdf(RenderProps props) async {
    String value = props.value;
    if (!validateBarcodeInput(type, value)) return;
    Schema schema = props.schema;
    MatrixSymbol? matrix = MatrixSymbolBuilder.build(type, value);
    // pdfme asks bwip-js for a 2D symbol of the fitted size (in mm)
    BarcodeFitLayout? fitted = matrix == null
        ? null
        : getBarcodeFitLayout(
            boxWidth: schema.width,
            boxHeight: schema.height,
            naturalWidth: matrix.ratio,
            naturalHeight: 1,
          );
    BarcodeSymbol? symbol =
        matrix?.toSymbol(widthMm: fitted?.width, heightMm: fitted?.height) ??
        LinearSymbolBuilder.build(
          type,
          value,
          widthMm: schema.width,
          heightMm: schema.height,
          includeText: _includeText(schema),
        );
    if (symbol == null) return;

    PDFPage page = props.page;
    PdfLayout box = PdfLayout.of(
      schema,
      page.getHeight(),
      applyRotateTranslate: false,
    );
    String? colorType = props.options.colorType;
    bool rotated = box.rotate != 0;
    if (rotated) {
      double px = box.x + box.width / 2;
      double py = box.y + box.height / 2;
      page.pushOperators(<PDFOperator>[
        pushGraphicsState(),
        translate(px, py),
        rotateDegrees(box.rotate),
        translate(-px, -py),
      ]);
    }
    try {
      _drawBackground(page, schema, box, colorType);
      _drawSymbol(props, box, symbol, matrix?.ratio);
    } finally {
      if (rotated) page.pushOperators(<PDFOperator>[popGraphicsState()]);
    }
  }

  /// Draws [symbol] in [box]: stretched to the box, or centered with the
  /// natural [ratio] (width : height) of a 2D symbol.
  void _drawSymbol(
    RenderProps props,
    PdfLayout box,
    BarcodeSymbol symbol,
    double? ratio,
  ) {
    BarcodeFitLayout fit = getBarcodeFitLayout(
      boxWidth: box.width,
      boxHeight: box.height,
      naturalWidth: ratio,
      naturalHeight: ratio == null ? null : 1,
    );
    String? colorType = props.options.colorType;
    Schema schema = props.schema;
    BarcodePainter(props.page).paint(
      symbol,
      left: box.x + fit.offsetX,
      top: box.y + box.height - fit.offsetY,
      width: fit.width,
      height: fit.height,
      barColor: hexToPrintingColor(
        _bwipColor(schema.string('barColor')),
        colorType,
      )!,
      textColor: hexToPrintingColor(
        _bwipColor(schema.string('textColor')),
        colorType,
      ),
      font: symbol.text == null ? null : _font(props),
      opacity: box.opacity,
    );
  }

  /// `includetext`: true when the key is missing, like pdfme.
  static bool _includeText(Schema schema) =>
      !schema.json.containsKey('includetext') ||
      schema.json['includetext'] == true;

  /// pdfme's `ensureHexColorHash` + `mapHexColorForBwipJsLib`: `#` added
  /// when missing, alpha dropped, black when empty.
  static String _bwipColor(String? color) {
    String? hex = _withHash(color);
    if (hex == null || hex.isEmpty) return '#000000';
    return splitHexAlpha(hex).color;
  }

  static String? _withHash(String? color) =>
      color != null && !color.startsWith('#') && isHexValid('#$color')
      ? '#$color'
      : color;

  static void _drawBackground(
    PDFPage page,
    Schema schema,
    PdfLayout box,
    String? colorType,
  ) {
    String? hex = _withHash(schema.string('backgroundColor'));
    if (hex == null || hex.isEmpty) return;
    HexAlpha c = splitHexAlpha(hex);
    if (c.alpha <= 0) return;
    page.drawRectangle(
      x: box.x,
      y: box.y,
      width: box.width,
      height: box.height,
      color: hexToPrintingColor(c.color, colorType),
      opacity: applyAlphaToOpacity(box.opacity, c.alpha),
    );
  }

  /// Helvetica, embedded once per document.
  static PDFFont _font(RenderProps props) => props.cache.putIfAbsent(
    _fontKey,
    () => props.doc.embedStandardFont(StandardFonts.helvetica),
  ) as PDFFont;
}
