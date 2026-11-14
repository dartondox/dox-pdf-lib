// FFI calls of native/src/form.rs. Every form call is one `dox_pdf_form`
// call with an op code.
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

/// Save flag: update the field appearances (`SAVE_UPDATE_FIELD_APPEARANCES`
/// in document.rs).
const int saveUpdateFieldAppearances = 4;

/// Field kinds (`BUTTON`, ... in form.rs).
const int fieldButton = 0;
const int fieldCheckBox = 1;
const int fieldDropdown = 2;
const int fieldOptionList = 3;
const int fieldRadioGroup = 4;
const int fieldSignature = 5;
const int fieldTextField = 6;

/// Ops of [doxPdfForm] (`GET_FORM`, ... in form.rs).
const int opGetForm = 0;
const int opHasXfa = 1;
const int opDeleteXfa = 2;
const int opGetFields = 3;
const int opFindField = 4;
const int opCreateField = 5;
const int opRemoveField = 6;
const int opFlatten = 7;
const int opUpdateAppearances = 8;
const int opDefaultFont = 9;
const int opName = 10;
const int opFlags = 11;
const int opSetFlag = 12;
const int opNeedsUpdate = 13;
const int opMarkDirty = 14;
const int opMarkClean = 15;
const int opIsDirty = 16;
const int opUpdateField = 17;
const int opTextGet = 20;
const int opTextSet = 21;
const int opAlignmentGet = 22;
const int opAlignmentSet = 23;
const int opMaxLengthGet = 24;
const int opMaxLengthSet = 25;
const int opFontSizeSet = 26;
const int opCheck = 30;
const int opUncheck = 31;
const int opIsChecked = 32;
const int opRadioOptions = 33;
const int opRadioSelected = 34;
const int opRadioSelect = 35;
const int opRadioClear = 36;
const int opChoiceOptions = 40;
const int opChoiceSelected = 41;
const int opChoiceSetOptions = 42;
const int opChoiceAddOptions = 43;
const int opChoiceSelect = 44;
const int opChoiceClear = 45;
const int opAddToPage = 50;
const int opSetImage = 51;
const int opWidgets = 52;
const int opPageOfAnnot = 53;

/// One form call. `nums` and `bytes` (a string list, see [encodeStrings])
/// are the input. `out[0]` = a number, `out[1]` = a `Bytes` address of the
/// output records, or 0.
@Native<
  Int32 Function(
    Pointer<Void>,
    Int32,
    Int64,
    Pointer<Double>,
    Int64,
    Pointer<Uint8>,
    Int64,
    Pointer<Int64>,
  )
>(symbol: 'dox_pdf_form', isLeaf: true)
external int doxPdfForm(
  Pointer<Void> handle,
  int op,
  int field,
  Pointer<Double> nums,
  int numsLength,
  Pointer<Uint8> bytes,
  int bytesLength,
  Pointer<Int64> out,
);

/// Strings for Rust: u32 length (little endian) + UTF-8 each.
Uint8List encodeStrings(List<String> strings) {
  BytesBuilder out = BytesBuilder(copy: false);
  for (String s in strings) {
    Uint8List bytes = utf8.encode(s);
    out.add(
      (ByteData(
        4,
      )..setUint32(0, bytes.length, Endian.little)).buffer.asUint8List(),
    );
    out.add(bytes);
  }
  return out.takeBytes();
}

/// Reads the output records of form.rs (`Out`).
class FormReader {
  FormReader(Uint8List bytes)
    : _data = ByteData.sublistView(bytes),
      _bytes = bytes;

  final ByteData _data;
  final Uint8List _bytes;
  int _pos = 0;

  int int64() {
    int v = _data.getInt64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  double float64() {
    double v = _data.getFloat64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  String string() {
    int len = _data.getUint32(_pos, Endian.little);
    _pos += 4;
    String s = utf8.decode(Uint8List.sublistView(_bytes, _pos, _pos + len));
    _pos += len;
    return s;
  }

  String? optString() => _bytes[_pos++] == 0 ? null : string();

  List<String> strings() => <String>[
    for (int i = int64(); i > 0; i--) string(),
  ];
}
