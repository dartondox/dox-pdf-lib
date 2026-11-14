// FFI calls of native/src/conformance.rs.
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:ffi';

/// `texts` = output condition identifier, output condition, registry name
/// and info (UTF-8, joined). `lengths` = their 4 lengths.
@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Int64,
    Int32,
    Pointer<Uint8>,
    Int64,
    Pointer<Int64>,
  )
>(symbol: 'dox_pdf_conf_add_intent', isLeaf: true)
external int doxPdfConfAddIntent(
  Pointer<Void> handle,
  Pointer<Uint8> icc,
  int iccLength,
  int subtype,
  Pointer<Uint8> texts,
  int textsLength,
  Pointer<Int64> lengths,
);

/// `texts` and `lengths` as in [doxPdfConfAddIntent].
@Native<
  Int32 Function(
    Pointer<Void>,
    Int32,
    Pointer<Uint8>,
    Int64,
    Pointer<Uint8>,
    Int64,
    Pointer<Int64>,
  )
>(symbol: 'dox_pdf_conf_set', isLeaf: true)
external int doxPdfConfSet(
  Pointer<Void> handle,
  int standard,
  Pointer<Uint8> icc,
  int iccLength,
  Pointer<Uint8> texts,
  int textsLength,
  Pointer<Int64> lengths,
);

/// Returns `statusNotFound` when there is no XMP.
@Native<Int32 Function(Pointer<Void>, Pointer<Int64>)>(
  symbol: 'dox_pdf_conf_get_xmp',
  isLeaf: true,
)
external int doxPdfConfGetXmp(Pointer<Void> handle, Pointer<Int64> out);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int64)>(
  symbol: 'dox_pdf_conf_set_xmp',
  isLeaf: true,
)
external int doxPdfConfSetXmp(
  Pointer<Void> handle,
  Pointer<Uint8> xml,
  int xmlLength,
);

/// `standard` -1 = XMP with no identification schema.
@Native<Int32 Function(Pointer<Void>, Int32, Pointer<Int64>)>(
  symbol: 'dox_pdf_conf_make_xmp',
  isLeaf: true,
)
external int doxPdfConfMakeXmp(
  Pointer<Void> handle,
  int standard,
  Pointer<Int64> out,
);

/// `out[0]` = per issue `kind \t page \t message \n` (page -1 = document).
@Native<Int32 Function(Pointer<Void>, Int32, Pointer<Int64>)>(
  symbol: 'dox_pdf_conf_check',
  isLeaf: true,
)
external int doxPdfConfCheck(
  Pointer<Void> handle,
  int standard,
  Pointer<Int64> out,
);
