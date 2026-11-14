// FFI calls of native/src/page.rs.
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:ffi';

/// Box kinds.
const int boxMedia = 0;
const int boxCrop = 1;
const int boxBleed = 2;
const int boxTrim = 3;
const int boxArt = 4;

@Native<Int32 Function(Pointer<Void>, Int64, Int32, Pointer<Double>)>(
  symbol: 'dox_pdf_page_get_box',
  isLeaf: true,
)
external int doxPdfPageGetBox(
  Pointer<Void> handle,
  int page,
  int kind,
  Pointer<Double> out,
);

@Native<
  Int32 Function(Pointer<Void>, Int64, Int32, Double, Double, Double, Double)
>(symbol: 'dox_pdf_page_set_box', isLeaf: true)
external int doxPdfPageSetBox(
  Pointer<Void> handle,
  int page,
  int kind,
  double x,
  double y,
  double width,
  double height,
);

/// A NaN width or height keeps that side.
@Native<Int32 Function(Pointer<Void>, Int64, Double, Double)>(
  symbol: 'dox_pdf_page_set_size',
  isLeaf: true,
)
external int doxPdfPageSetSize(
  Pointer<Void> handle,
  int page,
  double width,
  double height,
);

@Native<Int32 Function(Pointer<Void>, Int64, Pointer<Double>)>(
  symbol: 'dox_pdf_page_get_rotation',
  isLeaf: true,
)
external int doxPdfPageGetRotation(
  Pointer<Void> handle,
  int page,
  Pointer<Double> out,
);

@Native<Int32 Function(Pointer<Void>, Int64, Double)>(
  symbol: 'dox_pdf_page_set_rotation',
  isLeaf: true,
)
external int doxPdfPageSetRotation(
  Pointer<Void> handle,
  int page,
  double degrees,
);
