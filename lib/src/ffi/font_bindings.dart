// FFI calls of native/src/font.rs. A font is the index of `StandardFonts`.
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:ffi';

/// `out[0]` = the font ref.
@Native<
  Int32 Function(Pointer<Void>, Int32, Pointer<Uint8>, Int64, Pointer<Int64>)
>(symbol: 'dox_pdf_embed_standard_font', isLeaf: true)
external int doxPdfEmbedStandardFont(
  Pointer<Void> handle,
  int font,
  Pointer<Uint8> name,
  int nameLength,
  Pointer<Int64> out,
);

@Native<Int32 Function(Int32, Pointer<Uint8>, Int64, Double, Pointer<Double>)>(
  symbol: 'dox_pdf_font_width',
  isLeaf: true,
)
external int doxPdfFontWidth(
  int font,
  Pointer<Uint8> text,
  int length,
  double size,
  Pointer<Double> out,
);

/// `out` = top, bottom and descender of the font (1000 units per em).
@Native<Int32 Function(Int32, Pointer<Double>)>(
  symbol: 'dox_pdf_font_vertical',
  isLeaf: true,
)
external int doxPdfFontVertical(int font, Pointer<Double> out);

@Native<Int32 Function(Int32, Pointer<Int64>, Int64, Pointer<Int64>)>(
  symbol: 'dox_pdf_font_charset',
  isLeaf: true,
)
external int doxPdfFontCharset(
  int font,
  Pointer<Int64> out,
  int capacity,
  Pointer<Int64> count,
);

/// `out[0]` = a `Bytes` address of the hex codes.
@Native<Int32 Function(Int32, Pointer<Uint8>, Int64, Pointer<Int64>)>(
  symbol: 'dox_pdf_font_encode',
  isLeaf: true,
)
external int doxPdfFontEncode(
  int font,
  Pointer<Uint8> text,
  int length,
  Pointer<Int64> out,
);
