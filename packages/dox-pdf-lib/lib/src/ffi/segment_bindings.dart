// FFI calls of native/src/segment.rs.
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:ffi';

/// Writes the word breaks of UTF-16 text (`length` code units) into `out`
/// (room for `length` values) and their number into `count`.
@Native<Int32 Function(Pointer<Uint16>, Int64, Pointer<Int32>, Pointer<Int64>)>(
  symbol: 'dox_pdf_word_breaks',
  isLeaf: true,
)
external int doxPdfWordBreaks(
  Pointer<Uint16> text,
  int length,
  Pointer<Int32> out,
  Pointer<Int64> count,
);
