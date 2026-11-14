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

/// An embedded font, like pdf-lib's `PDFFont`: a standard font or a custom
/// font file (TrueType or OpenType).
class PDFFont {
  PDFFont._(this.doc, this.ref, this._standard)
    : name = _standard!.fontName,
      _custom = null;

  PDFFont._custom(this.doc, this.ref, this.name, Float64List vertical)
    : _standard = null,
      _custom = vertical;

  final PDFDocument doc;

  /// The object number of the font dict, `number << 16 | generation`.
  final int ref;

  /// The PostScript name of the font (`Font` when the file has none), or
  /// the name of the standard font. Like pdf-lib, not the `customName`.
  final String name;

  final StandardFonts? _standard;

  /// `top`, `bottom` and `descender` of a custom font.
  final Float64List? _custom;

  /// `top`, `bottom` and `descender` per standard font, read once.
  static final Map<StandardFonts, Float64List> _vertical =
      <StandardFonts, Float64List>{};

  /// The text as hex codes of the font encoding. A standard font throws
  /// when it can not encode a character, like pdf-lib. A custom font gives
  /// glyph ids (`.notdef` for a missing character).
  PDFHexString encodeText(String text) {
    Uint8List bytes = utf8.encode(text);
    Int64List out = Int64List(1);
    StandardFonts? std = _standard;
    check(
      std != null
          ? doxPdfFontEncode(
              std.index,
              bytes.address,
              bytes.length,
              out.address,
            )
          : doxPdfDocFontEncode(
              doc._handle,
              ref,
              bytes.address,
              bytes.length,
              out.address,
            ),
    );
    return PDFHexString(ascii.decode(takeBytes(out[0])));
  }

  /// The width of [text] at font [size]. The same as pdf-lib, to the last
  /// bit: with kerning for a standard font; for a custom font, the advance
  /// widths of the laid out glyphs (ligatures, no kerning), like fontkit.
  double widthOfTextAtSize(String text, double size) {
    Uint8List bytes = utf8.encode(text);
    Float64List out = Float64List(1);
    StandardFonts? std = _standard;
    check(
      std != null
          ? doxPdfFontWidth(
              std.index,
              bytes.address,
              bytes.length,
              size,
              out.address,
            )
          : doxPdfDocFontWidth(
              doc._handle,
              ref,
              bytes.address,
              bytes.length,
              size,
              out.address,
            ),
    );
    return out[0];
  }

  Float64List get _metrics =>
      _custom ??
      _vertical.putIfAbsent(_standard!, () {
        Float64List out = Float64List(3);
        check(doxPdfFontVertical(_standard.index, out.address));
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

  /// The unicode code points this font can encode. Sorted for a standard
  /// font; in the order of the font's cmap for a custom font.
  List<int> getCharacterSet() {
    Int64List count = Int64List(1);
    Int64List out = Int64List(256);
    int call() {
      StandardFonts? std = _standard;
      return std != null
          ? doxPdfFontCharset(std.index, out.address, out.length, count.address)
          : doxPdfDocFontCharset(
              doc._handle,
              ref,
              out.address,
              out.length,
              count.address,
            );
    }

    check(call());
    if (count[0] > out.length) {
      out = Int64List(count[0]);
      check(call());
    }
    return List<int>.unmodifiable(out.sublist(0, count[0]));
  }
}

/// Fonts, like pdf-lib's `embedFont` and `embedStandardFont`.
///
/// pdf-lib needs `registerFontkit(fontkit)` before it can embed a font
/// file. Here the font code is built in, so there is no `registerFontkit`.
extension PDFDocumentFonts on PDFDocument {
  /// Embeds a font: a [StandardFonts] (or its name), or a TrueType or
  /// OpenType font file as bytes ([Uint8List], [ByteBuffer], `List<int>`)
  /// or as a base64 string or `data:` URI, like pdf-lib.
  ///
  /// [subset] embeds only the glyphs that are used. [customName] replaces
  /// the `BaseFont` name in the file. [features] turns OpenType features on
  /// or off, eg. `{'liga': false}`; the default ones (like `liga` and
  /// `kern`) are on, like fontkit.
  Future<PDFFont> embedFont(
    Object font, {
    bool subset = false,
    String? customName,
    Map<String, bool>? features,
  }) async {
    if (font is StandardFonts) return embedStandardFont(font, customName);
    if (font is String) {
      for (StandardFonts f in StandardFonts.values) {
        if (f.fontName == font) return embedStandardFont(f, customName);
      }
    }
    Uint8List data = switch (font) {
      Uint8List b => b,
      ByteBuffer b => b.asUint8List(),
      List<int> b => Uint8List.fromList(b),
      String s => base64.decode(
        s.startsWith('data:') ? s.substring(s.indexOf(',') + 1) : s,
      ),
      _ => throw ArgumentError.value(
        font,
        'font',
        'must be StandardFonts, a String, Uint8List or ByteBuffer',
      ),
    };
    Uint8List name = utf8.encode(customName ?? '');
    BytesBuilder feats = BytesBuilder();
    features?.forEach((String tag, bool on) {
      // OpenType tags only: 4 ASCII letters
      if (tag.length == 4 && tag.codeUnits.every((int c) => c < 128)) {
        feats
          ..add(ascii.encode(tag))
          ..addByte(on ? 1 : 0);
      }
    });
    Uint8List featBytes = feats.takeBytes();
    Int64List out = Int64List(2);
    Float64List vertical = Float64List(3);
    check(
      doxPdfEmbedFont(
        _handle,
        data.address,
        data.length,
        subset ? 1 : 0,
        name.address,
        name.length,
        featBytes.address,
        featBytes.length,
        out.address,
        vertical.address,
      ),
    );
    return PDFFont._custom(this, out[0], takeString(out[1]), vertical);
  }

  /// Embeds one of the 14 standard fonts. [customName] replaces the
  /// `BaseFont` name in the file.
  PDFFont embedStandardFont(StandardFonts font, [String? customName]) {
    Uint8List name = utf8.encode(customName ?? '');
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
