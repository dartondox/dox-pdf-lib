import 'package:dox_pdf_me/src/text/wrap.dart';
import 'package:test/test.dart';

/// Like pdfme's mock font: 500/1000 em at size 10, so 5 per code point.
double _measure(String text) => text.isEmpty ? 0 : text.runes.length * 5.0;

List<WrapLine> _wrap(String value, double width) =>
    wrapText(value, _measure, width);

List<String> _texts(List<WrapLine> lines) =>
    lines.map((WrapLine l) => l.text).toList();

void main() {
  group('wrapText (pdfme wrap.test.ts)', () {
    test('keeps König: together instead of orphaning the colon', () {
      List<String> lines = _texts(_wrap('Party-König: oder die', 55));
      expect(lines.any((String t) => t.startsWith(':')), isFalse);
      expect(lines.any((String t) => t.contains('König:')), isTrue);
    });

    test('keeps a curly opening quote with the next word', () {
      List<String> lines = _texts(_wrap('die ‘Party kommt', 35));
      expect(lines.any((String t) => t == '‘' || t.endsWith('‘')), isFalse);
      expect(lines.any((String t) => t.startsWith('‘Party')), isTrue);
    });

    test('does not split a possessive apostrophe onto the next line', () {
      List<String> lines = _texts(_wrap("companies' obligations", 50));
      expect(lines.any((String t) => t.startsWith("'")), isFalse);
      expect(lines.join(' '), contains("companies'"));
    });

    test('small kana do not start a line', () {
      List<String> lines = _texts(_wrap('これはきょーです', 15));
      expect(lines.any((String t) => t.startsWith('ょ')), isFalse);
    });

    test('a Japanese closer does not start a line', () {
      List<String> lines = _texts(_wrap('これは。文章です', 15));
      expect(lines.any((String t) => t.startsWith('。')), isFalse);
    });

    test('splits an unbreakable run between graphemes', () {
      List<WrapLine> lines = _wrap('abcdef', 25);
      expect(_texts(lines), <String>['abcde', 'f']);
      expect(lines[0].hardBreak, isFalse);
      expect(lines[1].hardBreak, isTrue);
    });

    test('no blank line from a space-only atom', () {
      List<WrapLine> lines = _wrap('aaa    bbb', 20);
      expect(_texts(lines), <String>['aaa', 'bbb']);
    });

    test('keeps paragraph indentation, drops wrap-leading spaces', () {
      expect(_wrap('hello\n  world', 100), const <WrapLine>[
        WrapLine('hello', hardBreak: true),
        WrapLine('  world', hardBreak: true),
      ]);
    });

    test('no empty line from leftover space after an overflow split', () {
      List<WrapLine> lines = _wrap('abcdef xyz', 15);
      expect(_texts(lines), <String>['abc', 'def', 'xyz']);
      expect(lines.map((WrapLine l) => l.hardBreak), <bool>[
        false,
        false,
        true,
      ]);
    });

    test('only the last line of a paragraph is a hard break', () {
      List<WrapLine> lines = _wrap('aaa bbb ccc', 15);
      expect(lines.length, greaterThan(1));
      expect(
        lines.sublist(0, lines.length - 1).every((WrapLine l) => !l.hardBreak),
        isTrue,
      );
      expect(lines.last.hardBreak, isTrue);
    });

    test('CRLF is one paragraph break, like LF', () {
      List<WrapLine> crlf = _wrap('hello\r\nworld', 100);
      expect(_texts(crlf), <String>['hello', 'world']);
      expect(_texts(crlf), _texts(_wrap('hello\nworld', 100)));
      expect(crlf, hasLength(2));
    });

    test('blank paragraphs are empty hard lines', () {
      expect(_wrap('hello\n\nworld', 100), const <WrapLine>[
        WrapLine('hello', hardBreak: true),
        WrapLine('', hardBreak: true),
        WrapLine('world', hardBreak: true),
      ]);
    });

    test('fills the current line before splitting a too wide word', () {
      List<WrapLine> lines = _wrap('xx abcdefgh', 20);
      expect(_texts(lines), <String>['xx a', 'bcde', 'fgh']);
      expect(lines.map((WrapLine l) => l.hardBreak), <bool>[
        false,
        false,
        true,
      ]);
    });

    test('does not split a grapheme cluster when overflowing', () {
      String text = 'aaaé́bbb';
      List<String> lines = _texts(_wrap(text, 15));
      expect(lines.join(), text);
      expect(
        lines.any((String t) => t.contains('́') && !t.contains('e')),
        isFalse,
      );
    });
  });

  group('wrapText (more cases)', () {
    test('empty value is one empty hard line', () {
      expect(_wrap('', 100), const <WrapLine>[WrapLine('', hardBreak: true)]);
    });

    test('every line end kind is a paragraph break', () {
      expect(_texts(_wrap('a\r\nb\rc\nd\fe\vf', 100)), <String>[
        'a',
        'b',
        'c',
        'd',
        'e',
        'f',
      ]);
    });

    test('breaks after a space', () {
      expect(_texts(_wrap('aaa bbb', 20)), <String>['aaa', 'bbb']);
    });

    test('breaks after a hyphen', () {
      expect(_texts(_wrap('aaa-bbb', 20)), <String>['aaa-', 'bbb']);
    });

    test('breaks between CJK ideographs', () {
      expect(_texts(_wrap('中文字符', 10)), <String>['中文', '字符']);
    });

    test('keeps 1.5 together', () {
      expect(_texts(_wrap('ab 1.5', 15)), <String>['ab', '1.5']);
    });

    test('an emoji ZWJ sequence is one grapheme', () {
      String family = '\u{1F468}‍\u{1F469}‍\u{1F467}';
      expect(splitGraphemes(family), <String>[family]);
      expect(countGraphemes(family), 1);
      // Width 5 fits one code point only, so each piece is one grapheme.
      List<String> lines = _texts(_wrap('$family$family', 5));
      expect(lines, <String>[family, family]);
    });

    test('trailing spaces are not measured', () {
      // "ab" is 10 wide. The 3 spaces would make 25 if they counted.
      List<WrapLine> lines = _wrap('ab   cd', 10);
      expect(_texts(lines), <String>['ab', 'cd']);
      expect(_wrap('ab   ', 10), const <WrapLine>[
        WrapLine('ab', hardBreak: true),
      ]);
    });

    test('leading spaces of the first line are kept', () {
      expect(_texts(_wrap('  ab', 100)), <String>['  ab']);
    });

    test('a line may be exactly as wide as the box', () {
      expect(_texts(_wrap('abc def', 15)), <String>['abc', 'def']);
      expect(_texts(_wrap('abc def', 35)), <String>['abc def']);
    });

    test('U+0085 is not trimmed (JavaScript does not trim it)', () {
      expect(_texts(_wrap('a\u0085', 100)), <String>['a\u0085']);
    });

    test('U+FEFF and NBSP are trimmed at the end', () {
      expect(_texts(_wrap('a ﻿', 100)), <String>['a']);
    });
  });

  group('helpers', () {
    test('splitParagraphs', () {
      expect(splitParagraphs('a\r\nb\rc\nd'), <String>['a', 'b', 'c', 'd']);
      expect(splitParagraphs('a\n'), <String>['a', '']);
    });

    test('splitGraphemes and countGraphemes', () {
      expect(splitGraphemes('éa'), <String>['é', 'a']);
      expect(countGraphemes('éa'), 2);
      expect(countGraphemes(''), 0);
    });
  });

  group('getLineAlignment', () {
    LineAlignment align(String alignment, {bool hard = false}) =>
        getLineAlignment(
          text: 'abcd',
          width: 40,
          hardBreak: hard,
          containerWidth: 100,
          alignment: alignment,
        );

    test('left', () {
      LineAlignment a = align('left');
      expect(a.x, 0);
      expect(a.extraCharacterSpacing, 0);
      expect(a.usedWidth, 40);
    });

    test('center and right use the used width', () {
      expect(align('center').x, 30);
      expect(align('right').x, 60);
    });

    test('justify spreads the space over the graphemes', () {
      LineAlignment a = align('justify');
      expect(a.extraCharacterSpacing, 15);
      expect(a.usedWidth, 100);
      expect(a.x, 0);
    });

    test('justify skips a hard break line', () {
      LineAlignment a = align('justify', hard: true);
      expect(a.extraCharacterSpacing, 0);
      expect(a.usedWidth, 40);
    });

    test('justify skips an empty line', () {
      LineAlignment a = getLineAlignment(
        text: '',
        width: 0,
        hardBreak: false,
        containerWidth: 100,
        alignment: 'justify',
      );
      expect(a.extraCharacterSpacing, 0);
      expect(a.usedWidth, 0);
    });
  });
}
