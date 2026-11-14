// UAX #14 line breaking, ported from pdfme
// (packages/schemas/src/text/lineBreak.ts, git sha 60d73ae).
// The pair table and the LB8a / LB21a / LB30a rules follow the foliojs
// linebreak algorithm (MIT). Classes come from the UCD range table.
//
// LB1 remaps used here:
//   AI, SA, SG, XX -> AL
//   CJ -> NS (strict Japanese rules for small kana)
//
// Thai, Lao, Khmer and Myanmar (class SA): pdfme adds extra break points
// from the Intl.Segmenter word dictionary. Dart has no such segmenter. So
// this port adds NO extra breaks inside SA text. This is the behavior pdfme
// documents for platforms without a segmenter.

import 'line_break_classes.dart';

const int op = 0;
const int cl = 1;
const int cp = 2;
const int qu = 3;
const int gl = 4;
const int ns = 5;
const int ex = 6;
const int sy = 7;
const int isClass = 8;
const int pr = 9;
const int po = 10;
const int nu = 11;
const int al = 12;
const int hl = 13;
const int id = 14;
const int inClass = 15;
const int hy = 16;
const int ba = 17;
const int bb = 18;
const int b2 = 19;
const int zw = 20;
const int cm = 21;
const int wj = 22;
const int h2 = 23;
const int h3 = 24;
const int jl = 25;
const int jv = 26;
const int jt = 27;
const int ri = 28;
const int eb = 29;
const int em = 30;
const int zwj = 31;
const int cb = 32;
const int ai = 33;
const int bk = 34;
const int cj = 35;
const int cr = 36;
const int lf = 37;
const int nl = 38;
const int sa = 39;
const int sg = 40;
const int sp = 41;
const int xx = 42;

// Pair table results.
const int _diBrk = 0; // direct break
const int _inBrk = 1; // indirect break (only after spaces)
const int _ciBrk = 2; // combining mark indirect break
const int _cpBrk = 3; // combining mark prohibited break
const int _prBrk = 4; // prohibited break

const int _pairSize = 33;

// foliojs/linebreak pair table, 33 x 33. Row = current class, column = next
// class. Values: 0 direct, 1 indirect, 2 combining indirect,
// 3 combining prohibited, 4 prohibited.
const String _pairRows =
    '444444444444444444444344444444444'
    '044114444110000111004240000000010'
    '044114444111110111004240000000010'
    '444111444111111111114241111111111'
    '144111444111111111114241111111111'
    '044111444000000111004240000000010'
    '044111444000000111004240000000010'
    '044111444001010111004240000000010'
    '044111444001110111004240000000010'
    '144111444001111111004241111101110'
    '144111444001110111004240000000010'
    '144111444111110111004240000000010'
    '144111444111110111004240000000010'
    '144111444111110111004240000000010'
    '044111444010000111004240000000010'
    '044111444000000111004240000000010'
    '044101444001000111004240000000010'
    '044101444000000111004240000000010'
    '144111444111111111114241111111110'
    '044111444000000111044240000000010'
    '000000000000000000004000000000000'
    '144111444111110111004240000000010'
    '144111444111111111114241111111111'
    '044111444010000111004240001100010'
    '044111444010000111004240000100010'
    '044111444010000111004241111000010'
    '044111444010000111004240001100010'
    '044111444010000111004240000100010'
    '044111444000000111004240000010010'
    '044111444010000111004240000001110'
    '044111444010000111004240000000010'
    '144111444111110111004240000000010'
    '044110444000000000004240000000010';

/// The pair table as one list of numbers. Row = current class.
final List<int> _pairTable = _pairRows.split('').map(int.parse).toList();

/// A place where a line may (or must) break.
class LineBreakOpportunity {
  const LineBreakOpportunity(this.position, {required this.required});

  /// UTF-16 index of the start of the next unit.
  final int position;

  /// True for a forced break (new line characters and the text end).
  final bool required;
}

/// The raw UCD line break class of [codePoint]. Unknown code points give [xx].
int getRawLineBreakClass(int codePoint) {
  int low = 0;
  int high = lineBreakRangeCount - 1;
  while (low <= high) {
    int mid = (low + high) >> 1;
    int offset = mid * 3;
    if (codePoint < lineBreakRangeData[offset]) {
      high = mid - 1;
    } else if (codePoint > lineBreakRangeData[offset + 1]) {
      low = mid + 1;
    } else {
      return lineBreakRangeData[offset + 2];
    }
  }
  return xx;
}

/// UAX #14 break opportunities with the foliojs pair table engine.
/// Positions are UTF-16 indexes at the start of the next unit.
List<LineBreakOpportunity> collectUax14Breaks(String text) {
  return _Uax14(text).run();
}

class _Uax14 {
  _Uax14(this.text);

  final String text;
  int _index = 0;
  int? _curClass;
  int _nextClass = 0;
  bool _lb8a = false;
  bool _lb21a = false;
  int _lb30a = 0;

  static int _mapClass(int lineBreakClass) {
    switch (lineBreakClass) {
      case ai:
      case sa:
      case sg:
      case xx:
        return al;
      case cj:
        return ns;
      default:
        return lineBreakClass;
    }
  }

  static int _mapFirst(int lineBreakClass) {
    switch (lineBreakClass) {
      case lf:
      case nl:
        return bk;
      case sp:
        return wj;
      default:
        return lineBreakClass;
    }
  }

  int _nextCodePoint() {
    int code = text.codeUnitAt(_index++);
    if (code >= 0xd800 && code <= 0xdbff && _index < text.length) {
      int next = text.codeUnitAt(_index);
      if (next >= 0xdc00 && next <= 0xdfff) {
        _index += 1;
        return (code - 0xd800) * 0x400 + (next - 0xdc00) + 0x10000;
      }
    }
    return code;
  }

  int _nextCharClass() => _mapClass(getRawLineBreakClass(_nextCodePoint()));

  bool? _getSimpleBreak() {
    switch (_nextClass) {
      case sp:
        return false;
      case bk:
      case lf:
      case nl:
        _curClass = bk;
        return false;
      case cr:
        _curClass = cr;
        return false;
      default:
        return null;
    }
  }

  bool _getPairTableBreak(int lastClass) {
    int? current = _curClass;
    if (current == null) {
      return false;
    }
    // Classes outside the table (BK, CR, ...) have no row: the source gets
    // undefined there and falls to its default, which is a break.
    int pair = current < _pairSize && _nextClass < _pairSize
        ? _pairTable[current * _pairSize + _nextClass]
        : -1;
    bool shouldBreak = false;

    switch (pair) {
      case _diBrk:
        shouldBreak = true;
      case _inBrk:
        shouldBreak = lastClass == sp;
      case _ciBrk:
        shouldBreak = lastClass == sp;
        if (!shouldBreak) {
          return false;
        }
      case _cpBrk:
        if (lastClass != sp) {
          return false;
        }
      case _prBrk:
        break;
      default:
        shouldBreak = true;
    }

    if (_lb8a) {
      shouldBreak = false;
    }

    if (_lb21a && (current == hy || current == ba)) {
      shouldBreak = false;
      _lb21a = false;
    } else {
      _lb21a = current == hl;
    }

    if (current == ri) {
      _lb30a += 1;
      if (_lb30a == 2 && _nextClass == ri) {
        shouldBreak = true;
        _lb30a = 0;
      }
    } else {
      _lb30a = 0;
    }

    _curClass = _nextClass;
    return shouldBreak;
  }

  List<LineBreakOpportunity> run() {
    if (text.isEmpty) {
      return const <LineBreakOpportunity>[
        LineBreakOpportunity(0, required: true),
      ];
    }
    List<LineBreakOpportunity> breaks = <LineBreakOpportunity>[];

    int firstClass = _nextCharClass();
    _curClass = _mapFirst(firstClass);
    _nextClass = firstClass;
    _lb8a = firstClass == zwj;

    while (_index < text.length) {
      int lastPos = _index;
      int lastClass = _nextClass;
      _nextClass = _nextCharClass();

      if (_curClass == bk || (_curClass == cr && _nextClass != lf)) {
        _curClass = _mapFirst(_mapClass(_nextClass));
        breaks.add(LineBreakOpportunity(lastPos, required: true));
        continue;
      }

      bool? shouldBreak = _getSimpleBreak();
      shouldBreak ??= _getPairTableBreak(lastClass);

      _lb8a = _nextClass == zwj;

      if (shouldBreak) {
        breaks.add(LineBreakOpportunity(lastPos, required: false));
      }
    }

    breaks.add(LineBreakOpportunity(text.length, required: true));
    return breaks;
  }
}
