import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

void main() {
  test('words of Thai, Lao, Khmer and Myanmar', () {
    // the same as Intl.Segmenter of Node.js 24 (ICU 78)
    expect(dictionaryWordBreaks('ทุกสองสัปดาห์'), <int>[3, 6]);
    expect(dictionaryWordBreaks('ดีมาก'), <int>[2]);
    expect(dictionaryWordBreaks('เด็กๆ'), isEmpty);
    expect(dictionaryWordBreaks('ພາສາລາວ'), <int>[4]);
    expect(dictionaryWordBreaks('មើលភាសាខ្មែរ'), <int>[3]);
    expect(dictionaryWordBreaks('ကျွန်တော်ကျောင်းသွားတယ်'), <int>[9, 16, 20]);
  });

  test('only inside runs of these scripts', () {
    expect(dictionaryWordBreaks('Hello, world!'), isEmpty);
    expect(dictionaryWordBreaks('Hello ภาษาไทย!'), <int>[10]);
    // two scripts in one run: no break where they meet
    expect(dictionaryWordBreaks('ภาษาไทยພາສາລາວ'), <int>[4, 11]);
  });

  test('empty and odd text', () {
    expect(dictionaryWordBreaks(''), isEmpty);
    for (String text in <String>[
      '\ud800',
      '\udc00กกกกก',
      '่้่้่',
      'ฯๆฯๆฯๆ',
      '😀ภาษาไทย😀',
    ]) {
      List<int> b = dictionaryWordBreaks(text);
      expect(b.every((int x) => x > 0 && x < text.length), isTrue);
    }
  });
}
