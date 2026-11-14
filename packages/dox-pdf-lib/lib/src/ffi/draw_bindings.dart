// FFI calls of native/src/draw.rs.
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:ffi';

/// Kinds of [doxPdfDraw] (`TEXT`, ... in draw.rs).
const int kindText = 0;
const int kindImage = 1;
const int kindLine = 2;
const int kindRectangle = 3;
const int kindEllipse = 4;
const int kindSvg = 5;
const int kindOperators = 6;

/// Kinds of [doxPdfPageChange].
const int changeTranslateContent = 0;
const int changeScaleContent = 1;
const int changeScale = 2;
const int changeResetPosition = 3;
const int changeScaleAnnotations = 4;

/// One draw call. `nums` starts with: opacity, border opacity, blend mode,
/// the color (type + 4 parts) and the border color (type + 4 parts). NaN,
/// -1 and color type 0 mean "not set". The numbers of the kind follow; see
/// `draw` in draw.rs.
@Native<
  Int32 Function(
    Pointer<Void>,
    Int64,
    Int32,
    Pointer<Double>,
    Int64,
    Pointer<Uint8>,
    Int64,
  )
>(symbol: 'dox_pdf_draw', isLeaf: true)
external int doxPdfDraw(
  Pointer<Void> handle,
  int page,
  int kind,
  Pointer<Double> nums,
  int numsLength,
  Pointer<Uint8> bytes,
  int bytesLength,
);

@Native<Int32 Function(Pointer<Void>, Int64, Int32, Double, Double)>(
  symbol: 'dox_pdf_page_change',
  isLeaf: true,
)
external int doxPdfPageChange(
  Pointer<Void> handle,
  int page,
  int kind,
  double x,
  double y,
);
