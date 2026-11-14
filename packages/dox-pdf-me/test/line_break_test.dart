import 'package:dox_pdf_me/src/text/line_break.dart';
import 'package:dox_pdf_me/src/text/line_break_classes.dart';
import 'package:test/test.dart';

int _classOf(String char) => getRawLineBreakClass(char.runes.first);

/// Break positions that are not the end of the text.
List<int> _inner(String text) =>
    collectUax14Breaks(text)
        .where((LineBreakOpportunity b) => b.position < text.length)
        .map((LineBreakOpportunity b) => b.position)
        .toList();

void main() {
  group('class table', () {
    test('has the pinned size and version', () {
      expect(lineBreakUnicodeVersion, '18.0.0');
      expect(lineBreakRangeData.length, lineBreakRangeCount * 3);
    });

    test('classifies punctuation and scripts', () {
      expect(_classOf(':'), isClass);
      expect(_classOf("'"), qu);
      expect(_classOf('‘'), qu);
      expect(_classOf('’'), qu);
      expect(_classOf('ぁ'), cj);
      expect(_classOf('ก'), sa);
      expect(_classOf('ກ'), sa);
      expect(_classOf('ក'), sa);
      expect(_classOf(' '), sp);
      expect(_classOf('-'), hy);
      expect(_classOf('。'), cl);
      expect(_classOf('中'), id);
      expect(_classOf('\n'), lf);
    });

    test('unknown code points are XX', () {
      expect(getRawLineBreakClass(0x10ffff), xx);
    });
  });

  group('collectUax14Breaks', () {
    test('empty text has one required break at 0', () {
      List<LineBreakOpportunity> breaks = collectUax14Breaks('');
      expect(breaks, hasLength(1));
      expect(breaks.single.position, 0);
      expect(breaks.single.required, isTrue);
    });

    test('the last break is required and at the text end', () {
      List<LineBreakOpportunity> breaks = collectUax14Breaks('ab cd');
      expect(breaks.last.position, 5);
      expect(breaks.last.required, isTrue);
    });

    test('breaks after a space', () {
      expect(_inner('ab cd'), <int>[3]);
    });

    test('breaks after a hyphen', () {
      expect(_inner('ab-cd'), <int>[3]);
    });

    test('no break between a hyphen and a digit', () {
      expect(_inner('a-1'), isEmpty);
    });

    test('no break before 。 or 、 or a closing bracket', () {
      expect(_inner('あ。'), isEmpty);
      expect(_inner('あ、'), isEmpty);
      expect(_inner('a)'), isEmpty);
      expect(_inner('a」'), isEmpty);
    });

    test('breaks between CJK ideographs', () {
      expect(_inner('中文字'), <int>[1, 2]);
    });

    test('no break inside a number with a dot', () {
      expect(_inner('1.5'), isEmpty);
      expect(_inner('2,000.50'), isEmpty);
    });

    test('small kana do not start a line (CJ becomes NS)', () {
      expect(_inner('きょ'), isEmpty);
    });

    test('line ends are required breaks', () {
      List<LineBreakOpportunity> breaks = collectUax14Breaks('a\nb');
      expect(breaks.map((LineBreakOpportunity b) => b.position), <int>[2, 3]);
      expect(breaks.first.required, isTrue);
    });

    test('CRLF is one required break', () {
      List<LineBreakOpportunity> breaks = collectUax14Breaks('a\r\nb');
      expect(breaks.map((LineBreakOpportunity b) => b.position), <int>[3, 4]);
      expect(breaks.first.required, isTrue);
    });

    test('a lone CR is a required break', () {
      List<LineBreakOpportunity> breaks = collectUax14Breaks('a\rb');
      expect(breaks.map((LineBreakOpportunity b) => b.position), <int>[2, 3]);
      expect(breaks.first.required, isTrue);
    });

    test('positions are UTF-16 indexes', () {
      // U+1F600 takes two UTF-16 units. Emoji are ID, so a break follows.
      expect(_inner('\u{1F600}\u{1F600}'), <int>[2]);
    });

    test('an emoji ZWJ sequence has no break inside', () {
      expect(_inner('\u{1F468}‍\u{1F469}‍\u{1F467}'), isEmpty);
    });

    test('flags break between pairs of regional indicators', () {
      String flag = '\u{1F1F9}\u{1F1ED}';
      expect(_inner('$flag$flag'), <int>[4]);
    });

    test('SA text gets no extra breaks (no word dictionary)', () {
      expect(_inner('ประเทศไทย'), isEmpty);
    });

    test('non-breaking space does not break', () {
      expect(_inner('a b'), isEmpty);
    });
  });
}
