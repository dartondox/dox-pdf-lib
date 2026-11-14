// Text wrapping, ported from pdfme (packages/schemas/src/text/wrap.ts,
// git sha 60d73ae). Only the single-style path is ported.
//
// Break points come from UAX #14 (see line_break.dart), plus the word ends
// inside Thai, Lao, Khmer and Myanmar text from the ICU word dictionaries
// (`dictionaryWordBreaks` of dox_pdf_lib). A word that fits on
// a full line stays whole. A word wider than the box fills the rest of the
// current line, then splits between graphemes.

import 'package:characters/characters.dart';
import 'package:dox_pdf_lib/dox_pdf_lib.dart' show dictionaryWordBreaks;

import 'line_break.dart';

/// One visual line.
///
/// [hardBreak] is true for the last line of a paragraph (also a blank one).
/// Lines made by wrapping have [hardBreak] false.
class WrapLine {
  const WrapLine(this.text, {required this.hardBreak});

  final String text;
  final bool hardBreak;

  @override
  bool operator ==(Object other) =>
      other is WrapLine && other.text == text && other.hardBreak == hardBreak;

  @override
  int get hashCode => Object.hash(text, hardBreak);

  @override
  String toString() =>
      'WrapLine(${text.isEmpty ? "''" : text}, '
      'hardBreak: $hardBreak)';
}

/// Width of a text. It must return 0 for the empty string.
typedef MeasureText = double Function(String text);

/// Where a line starts and how much space is added between graphemes.
class LineAlignment {
  const LineAlignment({
    required this.x,
    required this.extraCharacterSpacing,
    required this.usedWidth,
  });

  /// Offset of the line from the left edge of the box.
  final double x;

  /// Extra space after each grapheme (justify only).
  final double extraCharacterSpacing;

  /// The width the line takes, after justify.
  final double usedWidth;
}

final RegExp _paragraphSplit = RegExp(r'\r\n|\r|\n|\f|\v');

/// Splits on line ends. `\r\n` is one break.
List<String> splitParagraphs(String value) => value.split(_paragraphSplit);

/// Extended grapheme clusters of [text].
List<String> splitGraphemes(String text) =>
    text.characters.map((String c) => c).toList();

int countGraphemes(String text) => text.characters.length;

/// The same set as JavaScript `\s`: white space, line ends and U+FEFF.
/// Dart's `trim` also removes U+0085, JavaScript does not.
bool _isSpace(int unit) {
  if (unit >= 0x09 && unit <= 0x0d) return true;
  switch (unit) {
    case 0x20:
    case 0xa0:
    case 0x1680:
    case 0x2028:
    case 0x2029:
    case 0x202f:
    case 0x205f:
    case 0x3000:
    case 0xfeff:
      return true;
  }
  return unit >= 0x2000 && unit <= 0x200a;
}

/// JavaScript `trimEnd()`.
String _trimEnd(String text) {
  int end = text.length;
  while (end > 0 && _isSpace(text.codeUnitAt(end - 1))) {
    end -= 1;
  }
  return text.substring(0, end);
}

class _Atom {
  const _Atom(this.length, {required this.required});

  final int length;
  final bool required;
}

/// The UAX #14 breaks and the SA word breaks, sorted. A UAX #14 break keeps
/// its `required` flag at the same position (pdfme `mergeBreaks`).
List<_Atom> _getAtoms(String text) {
  Map<int, bool> requiredAt = <int, bool>{
    for (LineBreakOpportunity item in collectUax14Breaks(text))
      item.position: item.required,
  };
  // pdfme collectSaDictionaryBreaks: Intl.Segmenter on each run of SA
  // letters. dictionaryWordBreaks gives the same breaks for all runs at once.
  for (int position in dictionaryWordBreaks(text)) {
    requiredAt.putIfAbsent(position, () => false);
  }
  List<int> positions = requiredAt.keys.toList()..sort();
  List<_Atom> atoms = <_Atom>[];
  int previous = 0;
  for (int position in positions) {
    if (position <= previous) continue;
    atoms.add(_Atom(position - previous, required: requiredAt[position]!));
    previous = position;
  }
  if (previous < text.length) {
    atoms.add(_Atom(text.length - previous, required: true));
  }
  return atoms;
}

class _Range {
  const _Range(this.start, this.end, {this.hardBreak = false});

  final int start;
  final int end;
  final bool hardBreak;
}

/// Wraps one paragraph (already split, trailing space trimmed).
class _ParagraphWrapper {
  _ParagraphWrapper(this.source, this.measureText, this.maxWidth);

  final String source;
  final MeasureText measureText;
  final double maxWidth;

  final List<_Range> _lines = <_Range>[];
  int _currentStart = 0;
  int _currentEnd = 0;
  bool _hasCurrent = false;

  int _trimEndIndex(int start, int end) {
    int index = end;
    while (index > start && _isSpace(source.codeUnitAt(index - 1))) {
      index -= 1;
    }
    return index;
  }

  int _skipLeadingSpace(int start, int end) {
    int index = start;
    while (index < end && _isSpace(source.codeUnitAt(index))) {
      index += 1;
    }
    return index;
  }

  bool _isSpaceOnly(int start, int end) => _trimEndIndex(start, end) <= start;

  /// Width of the slice without trailing spaces.
  double _measure(int start, int end) {
    int trimmed = _trimEndIndex(start, end);
    if (trimmed <= start) return 0;
    return measureText(source.substring(start, trimmed));
  }

  void _markLastHard() {
    if (_lines.isEmpty) {
      _lines.add(const _Range(0, 0, hardBreak: true));
      return;
    }
    _Range last = _lines.last;
    _lines[_lines.length - 1] = _Range(last.start, last.end, hardBreak: true);
  }

  void _emit(int start, int end, bool hardBreak) {
    int trimmed = _trimEndIndex(start, end);
    if (trimmed <= start) {
      if (hardBreak) _markLastHard();
      return;
    }
    _lines.add(_Range(start, trimmed, hardBreak: hardBreak));
  }

  void _flush(bool hardBreak) {
    if (!_hasCurrent) {
      if (hardBreak) _markLastHard();
      return;
    }
    _emit(_currentStart, _currentEnd, hardBreak);
    _hasCurrent = false;
  }

  /// Cuts [start, end) into pieces that fit, between graphemes. A piece has
  /// at least one grapheme.
  List<_Range> _splitOverflow(int start, int end) {
    List<String> graphemes = splitGraphemes(source.substring(start, end));
    if (graphemes.isEmpty) return <_Range>[_Range(start, end)];

    List<_Range> pieces = <_Range>[];
    int pieceStart = start;
    int position = start;
    for (String grapheme in graphemes) {
      int next = position + grapheme.length;
      if (position != pieceStart && _measure(pieceStart, next) > maxWidth) {
        pieces.add(_Range(pieceStart, position));
        pieceStart = position;
      }
      position = next;
    }
    if (position > pieceStart || pieces.isEmpty) {
      pieces.add(_Range(pieceStart, position));
    }
    return pieces;
  }

  void _appendOverflow(int start, int end) {
    int position = start;
    if (_hasCurrent) {
      int takenEnd = start;
      for (String grapheme in splitGraphemes(source.substring(start, end))) {
        int next = takenEnd + grapheme.length;
        if (_measure(_currentStart, next) > maxWidth) break;
        takenEnd = next;
      }
      if (takenEnd > start) {
        _currentEnd = takenEnd;
        _flush(false);
        position = takenEnd;
      } else {
        _flush(false);
      }
    }

    if (position >= end) return;

    List<_Range> pieces = _splitOverflow(position, end);
    for (int index = 0; index < pieces.length - 1; index += 1) {
      _Range piece = pieces[index];
      int trimmed = _trimEndIndex(piece.start, piece.end);
      if (trimmed <= piece.start) continue;
      _lines.add(_Range(piece.start, trimmed));
    }
    _Range remainder = pieces.last;
    if (_isSpaceOnly(remainder.start, remainder.end)) {
      _hasCurrent = false;
      return;
    }
    _currentStart = remainder.start;
    _currentEnd = remainder.end;
    _hasCurrent = true;
  }

  void _startLine(int start, int end) {
    if (start >= end) {
      _hasCurrent = false;
      return;
    }
    if (_measure(start, end) <= maxWidth) {
      _currentStart = start;
      _currentEnd = end;
      _hasCurrent = true;
    } else {
      _hasCurrent = false;
      _appendOverflow(start, end);
    }
  }

  List<_Range> run() {
    if (source.isEmpty) {
      return const <_Range>[_Range(0, 0, hardBreak: true)];
    }

    int cursor = 0;
    for (_Atom atom in _getAtoms(source)) {
      int atomStart = cursor;
      int atomEnd = cursor + atom.length;
      cursor = atomEnd;

      if (!_hasCurrent) {
        _startLine(atomStart, atomEnd);
      } else if (_measure(_currentStart, atomEnd) <= maxWidth) {
        _currentEnd = atomEnd;
      } else if (_measure(atomStart, atomEnd) <= maxWidth) {
        _flush(false);
        _startLine(_skipLeadingSpace(atomStart, atomEnd), atomEnd);
      } else {
        _appendOverflow(atomStart, atomEnd);
      }

      if (atom.required) {
        _flush(true);
      }
    }

    if (_hasCurrent) {
      _flush(true);
    } else {
      _markLastHard();
    }
    return _lines;
  }
}

/// Splits [value] into lines that fit [maxWidth]. [measure] gives the width
/// of a text (0 for the empty string).
List<WrapLine> wrapText(String value, MeasureText measure, double maxWidth) {
  List<WrapLine> lines = <WrapLine>[];
  for (String paragraph in splitParagraphs(value)) {
    String source = _trimEnd(paragraph);
    for (_Range range in _ParagraphWrapper(source, measure, maxWidth).run()) {
      lines.add(
        WrapLine(
          source.substring(range.start, range.end),
          hardBreak: range.hardBreak,
        ),
      );
    }
  }
  return lines.isEmpty
      ? const <WrapLine>[WrapLine('', hardBreak: true)]
      : lines;
}

/// Where a line starts, and the extra space for justify. Only lines that are
/// not a hard break are justified.
LineAlignment getLineAlignment({
  required String text,
  required double width,
  required bool hardBreak,
  required double containerWidth,
  required String alignment,
}) {
  double extraCharacterSpacing = 0;
  double usedWidth = width;
  if (alignment == 'justify' && !hardBreak) {
    int graphemes = countGraphemes(text);
    if (graphemes > 0) {
      extraCharacterSpacing = (containerWidth - width) / graphemes;
      usedWidth = containerWidth;
    }
  }
  double x = 0;
  if (alignment == 'center') {
    x = (containerWidth - usedWidth) / 2;
  } else if (alignment == 'right') {
    x = containerWidth - usedWidth;
  }
  return LineAlignment(
    x: x,
    extraCharacterSpacing: extraCharacterSpacing,
    usedWidth: usedWidth,
  );
}
