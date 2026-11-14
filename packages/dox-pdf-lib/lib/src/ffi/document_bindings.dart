// FFI calls of native/src/document.rs.
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:ffi';

import 'ffi_util.dart';

/// Flags of create and load.
const int loadIgnoreEncryption = 1;
const int loadUpdateMetadata = 2;

/// Flags of save.
const int saveObjectStreams = 1;
const int saveAddDefaultPage = 2;

@Native<Int32 Function(Int32, Pointer<Uint8>, Int64, Pointer<Int64>)>(
  symbol: 'dox_pdf_create',
  isLeaf: true,
)
external int doxPdfCreate(
  int flags,
  Pointer<Uint8> now,
  int nowLength,
  Pointer<Int64> out,
);

// Leaf calls: they take typed data, and a big input does not run here (Rust
// copies it and returns PENDING at once).
@Native<
  Int32 Function(
    Pointer<Uint8>,
    Int64,
    Int32,
    Pointer<Uint8>,
    Int64,
    Pointer<Int64>,
    Pointer<NativeFunction<DoneNative>>,
    Int64,
  )
>(symbol: 'dox_pdf_load', isLeaf: true)
external int doxPdfLoad(
  Pointer<Uint8> bytes,
  int length,
  int flags,
  Pointer<Uint8> now,
  int nowLength,
  Pointer<Int64> out,
  Pointer<NativeFunction<DoneNative>> done,
  int id,
);

@Native<
  Int32 Function(
    Pointer<Void>,
    Int32,
    Pointer<Int64>,
    Pointer<NativeFunction<DoneNative>>,
    Int64,
  )
>(symbol: 'dox_pdf_save', isLeaf: true)
external int doxPdfSave(
  Pointer<Void> handle,
  int flags,
  Pointer<Int64> out,
  Pointer<NativeFunction<DoneNative>> done,
  int id,
);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'dox_pdf_is_encrypted',
  isLeaf: true,
)
external int doxPdfIsEncrypted(Pointer<Void> handle);

@Native<Int32 Function(Pointer<Void>, Pointer<Int64>, Int64, Pointer<Int64>)>(
  symbol: 'dox_pdf_get_pages',
  isLeaf: true,
)
external int doxPdfGetPages(
  Pointer<Void> handle,
  Pointer<Int64> out,
  int capacity,
  Pointer<Int64> count,
);

@Native<
  Int32 Function(Pointer<Void>, Int64, Int64, Double, Double, Pointer<Int64>)
>(symbol: 'dox_pdf_insert_page', isLeaf: true)
external int doxPdfInsertPage(
  Pointer<Void> handle,
  int index,
  int page,
  double width,
  double height,
  Pointer<Int64> out,
);

@Native<Int32 Function(Pointer<Void>, Int64)>(
  symbol: 'dox_pdf_remove_page',
  isLeaf: true,
)
external int doxPdfRemovePage(Pointer<Void> handle, int index);

@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Int64>,
    Int64,
    Pointer<Int64>,
  )
>(symbol: 'dox_pdf_copy_pages', isLeaf: true)
external int doxPdfCopyPages(
  Pointer<Void> dst,
  Pointer<Void> src,
  Pointer<Int64> indices,
  int length,
  Pointer<Int64> out,
);
