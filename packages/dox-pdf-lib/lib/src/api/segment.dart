import 'dart:ffi';
import 'dart:typed_data';

import '../ffi/ffi_util.dart';
import '../ffi/segment_bindings.dart';

/// The word breaks inside the Thai, Lao, Khmer and Myanmar text of [text],
/// as sorted UTF-16 offsets (the indexes of a Dart `String`).
///
/// This is not part of pdf-lib. These scripts have no spaces between words,
/// so a line breaker needs the word ends to break lines between words.
/// They come from the ICU word dictionaries and the ICU break engines, the
/// same as JavaScript `Intl.Segmenter` with `granularity: 'word'` in Node.js
/// and browsers.
///
/// Each run of letters of one of these scripts is cut into words. The start
/// and the end of a run are not in the list, and other text gives no
/// breaks. For a run alone, the list is the `Intl.Segmenter` boundaries
/// without the first and the last one.
///
/// ```dart
/// dictionaryWordBreaks('ทุกสองสัปดาห์'); // [3, 6]
/// ```
List<int> dictionaryWordBreaks(String text) {
  if (text.isEmpty) return const <int>[];
  Uint16List units = Uint16List.fromList(text.codeUnits);
  Int32List out = Int32List(units.length);
  Int64List count = Int64List(1);
  check(
    doxPdfWordBreaks(units.address, units.length, out.address, count.address),
  );
  return Int32List.sublistView(out, 0, count[0]);
}
