import 'dart:convert';
import 'dart:math' as math;

import 'barcode_symbol.dart';
import 'pdf417_clusters.dart';

/// PDF417 like BWIPP (bwip-js 4.11.4), so the symbol is the same as in
/// pdfme: the same codewords, error correction level, columns and rows.
///
/// A port of BWIPP's `pdf417` encoder (src/pdf417.ps.src, version
/// 2026-05-28, MIT license, Copyright (c) 2004-2026 Terry Burton) with the
/// options bwip-js gets from pdfme: no `columns`, `rows` or `eclevel`, row
/// height 3 modules, no ECI.
class Pdf417Encoder {
  Pdf417Encoder._(this._msg);

  /// The module grid of [value], or null when BWIPP can not encode it (no
  /// data, or too much data).
  static Pdf417Symbol? encode(String value) {
    // bwip-js sends text with non-ASCII letters as UTF-8 bytes
    List<int> msg = utf8.encode(value);
    if (msg.isEmpty || msg.length > 2713) return null;
    return Pdf417Encoder._(msg)._symbol();
  }

  final List<int> _msg;

  // Modes, text submodes and the special values of the text tables
  static const int _modeText = 0, _modeNumeric = 1, _modeByte = 2;
  static const int _a = 0, _l = 1, _m = 2, _p = 3;
  static const int _tl = -1, _nl = -2, _bl = -3, _bl6 = -4, _bs = -5;
  static const int _al = -6, _ll = -7, _ml = -8, _pl = -9, _as = -10;
  static const int _ps = -11;

  /// "Empty": more than any real cost.
  static const int _e = 40000;

  static const Map<int, int> _latchCodewords = <int, int>{
    _tl: 900,
    _bl: 901,
    _bl6: 924,
    _nl: 902,
    _bs: 913,
  };

  /// The 30 values of each text submode (A, L, M, P), as BWIPP lists them.
  static final List<List<int>> _charmaps = _buildCharmaps();

  static List<List<int>> _buildCharmaps() {
    const String a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ ';
    const String l = 'abcdefghijklmnopqrstuvwxyz ';
    const String m = '0123456789&\r\t,:#-.\$/+%*=^';
    const String p = ';<>@[\\]_`~!\r\t,:\n-.\$/"|*()?{}\'';
    return <List<int>>[
      <int>[...a.codeUnits, _ll, _ml, _ps],
      <int>[...l.codeUnits, _as, _ml, _ps],
      <int>[...m.codeUnits, _pl, ' '.codeUnitAt(0), _ll, _al, _ps],
      <int>[...p.codeUnits, _al],
    ];
  }

  /// Character to value, per submode.
  static final List<Map<int, int>> _charvals = <Map<int, int>>[
    for (List<int> map in _charmaps)
      <int, int>{for (int i = 0; i < map.length; i++) map[i]: i},
  ];

  static final Set<int> _allText = <int>{
    for (List<int> map in _charmaps) ...map,
  };

  /// Cost of a latch from submode x (row) to y (column).
  static const List<List<int>> _latchLength = <List<int>>[
    <int>[0, 1, 1, 2],
    <int>[2, 0, 1, 2],
    <int>[1, 1, 0, 1],
    <int>[1, 2, 2, 0],
  ];

  static const List<List<List<int>>> _latchSequence = <List<List<int>>>[
    <List<int>>[
      <int>[],
      <int>[_ll],
      <int>[_ml],
      <int>[_ml, _pl],
    ],
    <List<int>>[
      <int>[_ml, _al],
      <int>[],
      <int>[_ml],
      <int>[_ml, _pl],
    ],
    <List<int>>[
      <int>[_al],
      <int>[_ll],
      <int>[],
      <int>[_pl],
    ],
    <List<int>>[
      <int>[_al],
      <int>[_al, _ll],
      <int>[_al, _ml],
      <int>[],
    ],
  ];

  /// Cost of a shift from submode x (row) to y (column).
  static const List<List<int>> _shiftLength = <List<int>>[
    <int>[_e, _e, _e, 1],
    <int>[1, _e, _e, 1],
    <int>[_e, _e, _e, 1],
    <int>[_e, _e, _e, _e],
  ];

  static final List<List<int>> _clusters = _readClusters();

  static List<List<int>> _readClusters() {
    List<int> all = <int>[
      for (String n in pdf417ClusterData.split(' ')) int.parse(n, radix: 36),
    ];
    return <List<int>>[
      for (int i = 0; i < 3; i++) all.sublist(i * 929, i * 929 + 929),
    ];
  }

  /// Reed-Solomon tables over GF(929).
  static final List<int> _rsAlog = _buildAlog();
  static final List<int> _rsLog = _buildLog();

  static List<int> _buildAlog() {
    List<int> out = <int>[1];
    for (int i = 0; i < 928; i++) {
      out.add(out.last * 3 % 929);
    }
    return out;
  }

  static List<int> _buildLog() {
    List<int> out = List<int>.filled(929, 0);
    for (int i = 1; i <= 928; i++) {
      out[_rsAlog[i]] = i;
    }
    return out;
  }

  int _submode = _a;

  Pdf417Symbol? _symbol() {
    List<int> data = _dataCodewords();
    int m = data.length;
    if (m > 926) return null;
    int eclevel = m <= 40
        ? 2
        : m <= 160
        ? 3
        : m <= 320
        ? 4
        : 5;
    int maxLevel = (math.log(928 - 1 - m) / math.ln2).truncate() - 1;
    if (eclevel > maxLevel) eclevel = maxLevel;
    int k = 1 << (eclevel + 1);
    int columns = math.sqrt((m + k) / 3).round();
    int c = math.max(columns, 1);
    int r = ((m + k + 1) / columns).ceil();
    if (r < 3) r = 3;
    if (r > 90) return null;
    // a higher level when the matrix has room for it
    maxLevel = math.min((math.log(c * r - 1 - m) / math.ln2).truncate() - 1, 8);
    if (maxLevel > eclevel) {
      eclevel = maxLevel;
      k = 1 << (eclevel + 1);
    }
    int n = c * r - k;
    if (n > 928) return null;
    List<int> cws = <int>[
      n,
      ...data,
      for (int i = 0; i < n - m - 1; i++) 900,
      ..._errorCodewords(<int>[n, ...data], n, k),
    ];
    return Pdf417Symbol(cws, c, r, eclevel);
  }

  /// BWIPP `rsecprime`: [k] error codewords of the first [n] codewords
  /// (the rest is padding 900).
  static List<int> _errorCodewords(List<int> head, int n, int k) {
    List<int> coeffs = _coefficients(k);
    List<int> lfsr = List<int>.filled(k, 0);
    for (int i = 0; i < n; i++) {
      int d = i < head.length ? head[i] : 900;
      int fb = (d - lfsr[0] + 929) % 929;
      for (int j = 0; j < k - 1; j++) {
        lfsr[j] = (lfsr[j + 1] + coeffs[k - 1 - j] * fb % 929) % 929;
      }
      lfsr[k - 1] = coeffs[0] * fb % 929;
    }
    return lfsr;
  }

  static int _product(int a, int b) =>
      a != 0 && b != 0 ? _rsAlog[(_rsLog[a] + _rsLog[b]) % 928] : 0;

  /// BWIPP `gencoeffs`.
  static List<int> _coefficients(int k) {
    List<int> coeffs = <int>[1, for (int i = 0; i < k; i++) 0];
    for (int i = 1; i <= k; i++) {
      coeffs[i] = coeffs[i - 1];
      int ai = _rsAlog[i];
      for (int j = i - 1; j >= 1; j--) {
        coeffs[j] = (_product(coeffs[j], ai) + coeffs[j - 1]) % 929;
      }
      coeffs[0] = _product(coeffs[0], ai);
    }
    coeffs = coeffs.sublist(0, k);
    for (int j = k - 1; j >= 0; j -= 2) {
      coeffs[j] = 929 - coeffs[j];
    }
    return coeffs;
  }

  /// The data codewords: the input split into numeric, text and byte runs
  /// like BWIPP, each run compacted in its mode.
  List<int> _dataCodewords() {
    List<Object> seq = _sequence();
    List<int> out = <int>[];
    int state = _modeText;
    _submode = _a;
    for (int i = 0; i < seq.length; i++) {
      Object item = seq[i];
      if (item is List<int>) {
        out.addAll(switch (state) {
          _modeText => _text(item),
          _modeNumeric => _numeric(item),
          _ => _bytes(item),
        });
        continue;
      }
      int latch = item as int;
      out.add(_latchCodewords[latch]!);
      if (latch == _tl) {
        state = _modeText;
        _submode = _a;
      } else if (latch == _nl) {
        state = _modeNumeric;
      } else if (latch == _bl || latch == _bl6) {
        state = _modeByte;
      } else if (latch == _bs) {
        i++;
        out.addAll(_bytes(seq[i] as List<int>));
      }
    }
    return out;
  }

  /// The runs and latches of the input (BWIPP's first pass).
  List<Object> _sequence() {
    int len = _msg.length;
    List<int> digits = List<int>.filled(len + 1, 0);
    List<int> texts = List<int>.filled(len + 1, 0);
    List<int> bytes = List<int>.filled(len + 1, 0);
    for (int i = len - 1; i >= 0; i--) {
      int ch = _msg[i];
      if (ch >= 48 && ch <= 57) digits[i] = digits[i + 1] + 1;
      if (_allText.contains(ch) && digits[i] < 13) texts[i] = texts[i + 1] + 1;
      if (texts[i] < 5 && digits[i] < 13) bytes[i] = bytes[i + 1] + 1;
    }
    List<Object> seq = <Object>[];
    int state = _modeText;
    int p = 0;
    while (p < len) {
      int n = digits[p];
      if (n >= 13 || (n == len && n >= 8)) {
        seq
          ..add(_nl)
          ..add(_msg.sublist(p, p + n));
        state = _modeNumeric;
        p += n;
        continue;
      }
      int t = texts[p];
      if (t >= 5) {
        if (state != _modeText) seq.add(_tl);
        seq.add(_msg.sublist(p, p + t));
        state = _modeText;
        p += t;
        continue;
      }
      int b = bytes[p];
      if (b == 1 && state == _modeText) {
        seq
          ..add(_bs)
          ..add(<int>[_msg[p]]);
        p += 1;
        continue;
      }
      seq
        ..add(b % 6 != 0 ? _bl : _bl6)
        ..add(_msg.sublist(p, p + b));
      state = _modeByte;
      p += b;
    }
    return seq;
  }

  /// Text compaction: the shortest mix of submodes, latches and shifts
  /// (BWIPP `enct`).
  List<int> _text(List<int> input) {
    List<int> curLen = <int>[_e, _e, _e, _e];
    curLen[_submode] = 0;
    List<List<int>> curSeq = <List<int>>[<int>[], <int>[], <int>[], <int>[]];
    for (int char in input) {
      _improveByLatches(curLen, curSeq);
      List<int> nxtLen = <int>[_e, _e, _e, _e];
      List<List<int>> nxtSeq = <List<int>>[<int>[], <int>[], <int>[], <int>[]];
      for (int x = 0; x < 4; x++) {
        if (!_charvals[x].containsKey(char)) continue;
        int cost = curLen[x] + 1;
        if (cost < nxtLen[x]) {
          nxtLen[x] = cost;
          nxtSeq[x] = <int>[...curSeq[x], char];
        }
        for (int y = 0; y < 4; y++) {
          if (x == y) continue;
          int shift = curLen[y] + _shiftLength[y][x] + 1;
          if (shift < nxtLen[y]) {
            nxtLen[y] = shift;
            nxtSeq[y] = <int>[...curSeq[y], x == _a ? _as : _ps, char];
          }
        }
      }
      curLen = nxtLen;
      curSeq = nxtSeq;
    }
    int min = _e;
    List<int> best = <int>[];
    for (int k = 0; k < 4; k++) {
      if (curLen[k] < min) {
        min = curLen[k];
        best = curSeq[k];
      }
    }
    return _packText(_textValues(best));
  }

  /// Latches that make a cheaper start for another submode.
  static void _improveByLatches(List<int> len, List<List<int>> seq) {
    bool improved = true;
    while (improved) {
      improved = false;
      for (int x = 0; x < 4; x++) {
        for (int y = 0; y < 4; y++) {
          int cost = len[x] + _latchLength[x][y];
          if (cost < len[y]) {
            len[y] = cost;
            seq[y] = <int>[...seq[x], ..._latchSequence[x][y]];
            improved = true;
          }
        }
      }
    }
  }

  /// The submode values of a text sequence, padded to an even count.
  List<int> _textValues(List<int> seq) {
    List<int> text = <int>[];
    for (int k = 0; k < seq.length; k++) {
      int char = seq[k];
      text.add(_charvals[_submode][char]!);
      if (char == _as || char == _ps) {
        k++;
        text.add(_charvals[char == _as ? _a : _p][seq[k]]!);
      }
      if (char == _al) _submode = _a;
      if (char == _ll) _submode = _l;
      if (char == _ml) _submode = _m;
      if (char == _pl) _submode = _p;
    }
    if (text.length.isOdd) {
      if (_submode == _p) {
        text.add(_charvals[_p][_al]!);
        _submode = _a;
      } else {
        text.add(_charvals[_submode][_ps]!);
      }
    }
    return text;
  }

  static List<int> _packText(List<int> text) => <int>[
    for (int k = 0; k < text.length; k += 2) text[k] * 30 + text[k + 1],
  ];

  /// Numeric compaction: groups of 44 digits, each `1` + digits in base
  /// 900.
  static List<int> _numeric(List<int> input) {
    List<int> out = <int>[];
    for (int k = 0; k < input.length; k += 44) {
      String digits = String.fromCharCodes(
        input.sublist(k, math.min(k + 44, input.length)),
      );
      BigInt value = BigInt.parse('1$digits');
      List<int> group = <int>[];
      BigInt base = BigInt.from(900);
      while (value > BigInt.zero) {
        group.insert(0, (value % base).toInt());
        value = value ~/ base;
      }
      out.addAll(group);
    }
    return out;
  }

  /// Byte compaction: 6 bytes to 5 codewords, the rest as they are.
  static List<int> _bytes(List<int> input) {
    List<int> out = <int>[];
    int full = input.length ~/ 6 * 6;
    for (int k = 0; k < full; k += 6) {
      int value = 0;
      for (int i = 0; i < 6; i++) {
        value = value * 256 + input[k + i];
      }
      List<int> group = List<int>.filled(5, 0);
      for (int i = 4; i >= 0; i--) {
        group[i] = value % 900;
        value ~/= 900;
      }
      out.addAll(group);
    }
    out.addAll(input.sublist(full));
    return out;
  }

  /// The 17 modules of codeword [cw] in [cluster].
  static List<bool> codewordBits(int cw, int cluster) {
    int v = _clusters[cluster][cw];
    return <bool>[for (int i = 16; i >= 0; i--) (v >> i) & 1 == 1];
  }
}

/// A PDF417 symbol: all codewords, columns, rows and error level.
class Pdf417Symbol {
  const Pdf417Symbol(this.codewords, this.columns, this.rows, this.eclevel);

  final List<int> codewords;
  final int columns;
  final int rows;
  final int eclevel;

  static const List<int> _start = <int>[
    1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0, 0, 0, //
  ];
  static const List<int> _stop = <int>[
    1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 1, //
  ];

  /// The modules: `17 * columns + 69` wide, one grid row per symbol row.
  ModuleGrid grid() {
    int c = columns;
    int r = rows;
    ModuleGrid grid = ModuleGrid(17 * c + 69, r);
    for (int i = 0; i < r; i++) {
      int base = i ~/ 3 * 30;
      int cluster = i % 3;
      int top = (r - 1) ~/ 3;
      int level = eclevel * 3 + (r - 1) % 3;
      int left = switch (cluster) {
        0 => base + top,
        1 => base + level,
        _ => base + c - 1,
      };
      int right = switch (cluster) {
        0 => base + c - 1,
        1 => base + top,
        _ => base + level,
      };
      List<bool> bits = <bool>[
        for (int b in _start) b == 1,
        ...Pdf417Encoder.codewordBits(left, cluster),
        for (int j = 0; j < c; j++)
          ...Pdf417Encoder.codewordBits(codewords[c * i + j], cluster),
        ...Pdf417Encoder.codewordBits(right, cluster),
        for (int b in _stop) b == 1,
      ];
      for (int x = 0; x < bits.length; x++) {
        if (bits[x]) grid.setDark(x, i);
      }
    }
    return grid;
  }
}
