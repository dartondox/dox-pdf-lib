// FFI calls of native/src/font.rs. The first calls take a standard font
// (the index of `StandardFonts`), the `Doc` calls any font of a document.
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

// Custom fonts, and any font of a document by its ref.

/// `out[0]` = the font ref, `out[1]` = a `Bytes` address of the font name,
/// `vertical` = top, bottom and descender.
@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Int64,
    Int32,
    Pointer<Uint8>,
    Int64,
    Pointer<Uint8>,
    Int64,
    Pointer<Int64>,
    Pointer<Double>,
  )
>(symbol: 'dox_pdf_embed_font', isLeaf: true)
external int doxPdfEmbedFont(
  Pointer<Void> handle,
  Pointer<Uint8> data,
  int dataLength,
  int subset,
  Pointer<Uint8> name,
  int nameLength,
  Pointer<Uint8> features,
  int featuresLength,
  Pointer<Int64> out,
  Pointer<Double> vertical,
);

@Native<
  Int32 Function(
    Pointer<Void>,
    Int64,
    Pointer<Uint8>,
    Int64,
    Double,
    Pointer<Double>,
  )
>(symbol: 'dox_pdf_doc_font_width', isLeaf: true)
external int doxPdfDocFontWidth(
  Pointer<Void> handle,
  int font,
  Pointer<Uint8> text,
  int length,
  double size,
  Pointer<Double> out,
);

/// `out[0]` = a `Bytes` address of the hex codes.
@Native<
  Int32 Function(Pointer<Void>, Int64, Pointer<Uint8>, Int64, Pointer<Int64>)
>(symbol: 'dox_pdf_doc_font_encode', isLeaf: true)
external int doxPdfDocFontEncode(
  Pointer<Void> handle,
  int font,
  Pointer<Uint8> text,
  int length,
  Pointer<Int64> out,
);

@Native<
  Int32 Function(Pointer<Void>, Int64, Pointer<Int64>, Int64, Pointer<Int64>)
>(symbol: 'dox_pdf_doc_font_charset', isLeaf: true)
external int doxPdfDocFontCharset(
  Pointer<Void> handle,
  int font,
  Pointer<Int64> out,
  int capacity,
  Pointer<Int64> count,
);
