// FFI calls of native/src/metadata.rs.
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:ffi';

/// Set modes.
const int metaText = 0;
const int metaLiteral = 1;
const int metaShowTitle = 4;

/// Returns `statusNotFound` when the key is not set.
@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int64, Pointer<Int64>)>(
  symbol: 'dox_pdf_meta_get',
  isLeaf: true,
)
external int doxPdfMetaGet(
  Pointer<Void> handle,
  Pointer<Uint8> key,
  int keyLength,
  Pointer<Int64> out,
);

@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Int64,
    Pointer<Uint8>,
    Int64,
    Int32,
  )
>(symbol: 'dox_pdf_meta_set', isLeaf: true)
external int doxPdfMetaSet(
  Pointer<Void> handle,
  Pointer<Uint8> key,
  int keyLength,
  Pointer<Uint8> value,
  int valueLength,
  int mode,
);
