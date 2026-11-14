part of 'document.dart';

/// The 14 standard PDF fonts, like pdf-lib's `StandardFonts`. They need no
/// font file. The order is the font index of native/src/font.rs.
enum StandardFonts {
  courier('Courier'),
  courierBold('Courier-Bold'),
  courierOblique('Courier-Oblique'),
  courierBoldOblique('Courier-BoldOblique'),
  helvetica('Helvetica'),
  helveticaBold('Helvetica-Bold'),
  helveticaOblique('Helvetica-Oblique'),
  helveticaBoldOblique('Helvetica-BoldOblique'),
  timesRoman('Times-Roman'),
  timesRomanBold('Times-Bold'),
  timesRomanItalic('Times-Italic'),
  timesRomanBoldItalic('Times-BoldItalic'),
  symbol('Symbol'),
  zapfDingbats('ZapfDingbats');

  const StandardFonts(this.fontName);

  /// The PostScript name, eg. `Times-Roman`.
  final String fontName;
}

/// An embedded font, like pdf-lib's `PDFFont`.
class PDFFont {
  PDFFont._(this.doc, this.ref, this._font);

  final PDFDocument doc;

  /// The object number of the font dict, `number << 16 | generation`.
  final int ref;

  final StandardFonts _font;

  /// `top`, `bottom` and `descender` per font, read once.
  static final Map<StandardFonts, Float64List> _vertical =
      <StandardFonts, Float64List>{};

  String get name => _font.fontName;

  /// The text as hex codes of the font encoding. Throws when the font can
  /// not encode a character, like pdf-lib.
  PDFHexString encodeText(String text) {
    Uint8List bytes = utf8.encode(text);
    Int64List out = Int64List(1);
    check(
      doxPdfFontEncode(_font.index, bytes.address, bytes.length, out.address),
    );
    return PDFHexString(ascii.decode(takeBytes(out[0])));
  }

  /// The width of [text] at font [size], with kerning. The same as pdf-lib,
  /// to the last bit.
  double widthOfTextAtSize(String text, double size) {
    Uint8List bytes = utf8.encode(text);
    Float64List out = Float64List(1);
    check(
      doxPdfFontWidth(
        _font.index,
        bytes.address,
        bytes.length,
        size,
        out.address,
      ),
    );
    return out[0];
  }

  Float64List get _metrics => _vertical.putIfAbsent(_font, () {
    Float64List out = Float64List(3);
    check(doxPdfFontVertical(_font.index, out.address));
    return out;
  });

  /// The height of the font at [size]. Without the [descender], it is the
  /// height above the baseline.
  double heightAtSize(double size, {bool descender = true}) {
    Float64List m = _metrics;
    double height = m[0] - m[1];
    if (!descender) height += m[2];
    return (height / 1000) * size;
  }

  /// The font size for a font of [height].
  double sizeAtHeight(double height) {
    Float64List m = _metrics;
    return (1000 * height) / (m[0] - m[1]);
  }

  /// The unicode code points this font can encode, sorted.
  List<int> getCharacterSet() {
    Int64List count = Int64List(1);
    Int64List out = Int64List(256);
    check(
      doxPdfFontCharset(_font.index, out.address, out.length, count.address),
    );
    if (count[0] > out.length) {
      out = Int64List(count[0]);
      check(
        doxPdfFontCharset(_font.index, out.address, out.length, count.address),
      );
    }
    return List<int>.unmodifiable(out.sublist(0, count[0]));
  }
}

/// Fonts, like pdf-lib's `embedFont` and `embedStandardFont`.
extension PDFDocumentFonts on PDFDocument {
  /// Embeds a font. Only [StandardFonts] are supported for now; custom
  /// font files (pdf-lib uses fontkit for them) come later.
  Future<PDFFont> embedFont(
    Object font, {
    bool subset = false,
    String? customName,
  }) async {
    if (font is StandardFonts) return embedStandardFont(font, customName);
    throw UnsupportedError('Only StandardFonts can be embedded for now.');
  }

  /// Embeds one of the 14 standard fonts. [customName] replaces the
  /// `BaseFont` name in the file.
  PDFFont embedStandardFont(StandardFonts font, [String? customName]) {
    Uint8List name = ascii.encode(customName ?? '');
    Int64List out = Int64List(1);
    check(
      doxPdfEmbedStandardFont(
        _handle,
        font.index,
        name.address,
        name.length,
        out.address,
      ),
    );
    return PDFFont._(this, out[0], font);
  }
}
