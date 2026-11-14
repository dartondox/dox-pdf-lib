// FFI calls of native/src/embed.rs.
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:ffi';

/// Embeds `count` pages of `src` into `dst`. `boxes` has 4 values per page
/// and `matrices` 6; a NaN first value means the default. Writes the
/// XObject refs into `outRefs` and width, height into `outSizes`.
@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Int64>,
    Int64,
    Pointer<Double>,
    Pointer<Double>,
    Pointer<Int64>,
    Pointer<Double>,
  )
>(symbol: 'dox_pdf_embed_pages', isLeaf: true)
external int doxPdfEmbedPages(
  Pointer<Void> dst,
  Pointer<Void> src,
  Pointer<Int64> pages,
  int count,
  Pointer<Double> boxes,
  Pointer<Double> matrices,
  Pointer<Int64> outRefs,
  Pointer<Double> outSizes,
);

/// `values` = x, y, xScale, yScale, rotate, xSkew, ySkew (radians),
/// opacity (NaN = none). `blend` = the blend mode index, or -1.
@Native<Int32 Function(Pointer<Void>, Int64, Int64, Pointer<Double>, Int32)>(
  symbol: 'dox_pdf_draw_page',
  isLeaf: true,
)
external int doxPdfDrawPage(
  Pointer<Void> handle,
  int page,
  int xobject,
  Pointer<Double> values,
  int blend,
);
