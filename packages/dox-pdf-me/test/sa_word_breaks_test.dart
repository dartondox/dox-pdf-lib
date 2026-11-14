// The Thai, Lao, Khmer and Myanmar word breaks must be the same as pdfme's
// (Intl.Segmenter of Node.js on each run of SA letters). The fixture comes
// from tool/crosscheck/word_breaks.mjs.
import 'dart:convert';
import 'dart:io';

import 'package:dox_pdf_me/dox_pdf_me.dart';
import 'package:test/test.dart';

void main() {
  Map<String, dynamic> fixture = jsonDecode(
    File('test/fixtures/sa_word_breaks.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  List<Map<String, dynamic>> cases = <Map<String, dynamic>>[
    for (Object? c in fixture['cases'] as List<dynamic>)
      c! as Map<String, dynamic>,
  ];

  test('the fixture has every language', () {
    expect(<String>{
      for (Map<String, dynamic> c in cases) c['language'] as String,
    }, containsAll(<String>['thai', 'lao', 'khmer', 'myanmar']));
  });

  for (Map<String, dynamic> c in cases) {
    String text = c['text'] as String;
    test('${c['language']}: $text', () {
      expect(dictionaryWordBreaks(text), c['breaks']);
    });
  }
}
