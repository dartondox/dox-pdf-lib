import 'dart:typed_data';

/// The font numbers pdfme measures with (fontkit): `head` and `hhea`.
class FontMetrics {
  const FontMetrics({
    required this.unitsPerEm,
    required this.ascent,
    required this.descent,
    required this.bboxMinY,
    required this.bboxMaxY,
  });

  /// Reads the `head` and `hhea` tables of a TrueType or OpenType file.
  factory FontMetrics.parse(Uint8List font) {
    ByteData data = ByteData.sublistView(font);
    int head = _table(data, 'head');
    int hhea = _table(data, 'hhea');
    return FontMetrics(
      unitsPerEm: data.getUint16(head + 18),
      bboxMinY: data.getInt16(head + 38).toDouble(),
      bboxMaxY: data.getInt16(head + 42).toDouble(),
      ascent: data.getInt16(hhea + 4).toDouble(),
      descent: data.getInt16(hhea + 6).toDouble(),
    );
  }

  final int unitsPerEm;

  /// `hhea` ascender, in font units.
  final double ascent;

  /// `hhea` descender, in font units (below zero).
  final double descent;

  final double bboxMinY;
  final double bboxMaxY;

  /// pdfme's `getFontDescentInPt`: below zero.
  double descentAtSize(double size) => descent / unitsPerEm * size;

  /// pdfme's `heightOfFontAtSize`: the height above the baseline.
  double heightAtSize(double size) {
    double scale = 1000 / unitsPerEm;
    double top = (ascent != 0 ? ascent : bboxMaxY) * scale;
    double bottom = (descent != 0 ? descent : bboxMinY) * scale;
    double height = top - bottom;
    height -= (descent * scale).abs();
    return height / 1000 * size;
  }

  static int _table(ByteData data, String tag) {
    int count = data.getUint16(4);
    for (int i = 0; i < count; i++) {
      int record = 12 + i * 16;
      String name = String.fromCharCodes(<int>[
        for (int j = 0; j < 4; j++) data.getUint8(record + j),
      ]);
      if (name == tag) return data.getUint32(record + 8);
    }
    throw FormatException('The font has no $tag table');
  }
}
