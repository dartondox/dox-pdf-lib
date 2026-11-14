// FFI calls of native/src/image.rs.
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:ffi';

import 'ffi_util.dart';

/// `out` = image ref, width, height.
@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int64, Pointer<Int64>)>(
  symbol: 'dox_pdf_embed_jpg',
  isLeaf: true,
)
external int doxPdfEmbedJpg(
  Pointer<Void> handle,
  Pointer<Uint8> bytes,
  int length,
  Pointer<Int64> out,
);

/// Small input: `out` = image ref, width, height. Big input returns
/// `PENDING`; the callback gets a decoded image for [doxPdfPngAdd].
@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Int64,
    Pointer<Int64>,
    Pointer<NativeFunction<DoneNative>>,
    Int64,
  )
>(symbol: 'dox_pdf_embed_png', isLeaf: true)
external int doxPdfEmbedPng(
  Pointer<Void> handle,
  Pointer<Uint8> bytes,
  int length,
  Pointer<Int64> out,
  Pointer<NativeFunction<DoneNative>> done,
  int id,
);

/// Adds the image a `PENDING` [doxPdfEmbedPng] decoded (and frees it).
/// `out` = image ref, width, height.
@Native<Int32 Function(Pointer<Void>, Int64, Pointer<Int64>)>(
  symbol: 'dox_pdf_png_add',
  isLeaf: true,
)
external int doxPdfPngAdd(Pointer<Void> handle, int png, Pointer<Int64> out);
