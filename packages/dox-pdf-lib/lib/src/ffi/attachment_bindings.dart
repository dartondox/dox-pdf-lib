// FFI calls of native/src/attachment.rs.
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:ffi';

import 'ffi_util.dart';

/// `texts` = name, mime type, description, creation date, modification
/// date and AF relationship (UTF-8, joined). `lengths` = their 6 lengths,
/// -1 for a missing value. Big data is compressed on a Rust thread: the
/// call returns `statusPending` and `done` reports the end.
@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Int64,
    Pointer<Uint8>,
    Pointer<Int64>,
    Pointer<NativeFunction<DoneNative>>,
    Int64,
  )
>(symbol: 'dox_pdf_attach', isLeaf: true)
external int doxPdfAttach(
  Pointer<Void> handle,
  Pointer<Uint8> data,
  int dataLength,
  Pointer<Uint8> texts,
  Pointer<Int64> lengths,
  Pointer<NativeFunction<DoneNative>> done,
  int id,
);

/// `out[0]` = a `Bytes` address with all attachments (see attachment.rs
/// `encode`).
@Native<Int32 Function(Pointer<Void>, Pointer<Int64>)>(
  symbol: 'dox_pdf_get_attachments',
  isLeaf: true,
)
external int doxPdfGetAttachments(Pointer<Void> handle, Pointer<Int64> out);
