import 'dart:convert';

import 'barcode_symbol.dart';
import 'barcode_validator.dart';

/// QR code like BWIPP (bwip-js 4.11.4), so the symbol is the same as in
/// pdfme: the same segments (numeric, alphanumeric, byte), version, error
/// correction level and mask.
///
/// A port of BWIPP's `qrcode` encoder (barcode.ps, version 2026-05-28, MIT
/// license, Copyright (c) 2004-2026 Terry Burton) with the options bwip-js
/// gets from pdfme: full QR code, error correction level M raised to the
/// highest level that fits the same version, automatic mask, and no kanji
/// mode (bwip-js sets `suppresskanjimode`, as it sends UTF-8 bytes).
class QrEncoder {
  QrEncoder._(this._msg);

  /// The module grid of [value] (not empty). Throws a
  /// [BarcodeInputException] with the bwip-js message when it does not fit
  /// in a QR code.
  static ModuleGrid encode(String value) {
    // bwip-js sends text with non-ASCII letters as UTF-8 bytes
    List<int> msg = utf8.encode(value);
    if (msg.length > 7089) {
      throw const BarcodeInputException.bwipp(
        'qrcodeInputTooLong#27120',
        'The input data is too long',
      );
    }
    return QrEncoder._(msg)._symbol();
  }

  static const BarcodeInputException _noSymbol = BarcodeInputException.bwipp(
    'qrcodeNoValidSymbol#27542',
    'Maximum length exceeded or invalid content',
  );

  final List<int> _msg;

  static const int _n = 0, _a = 1, _b = 2;

  /// Mode indicators of N, A and B.
  static const List<String> _modeBits = <String>['0001', '0010', '0100'];

  /// Character count bits of N, A, B per version group (1-9, 10-26,
  /// 27-40).
  static const List<List<int>> _countBits = <List<int>>[
    <int>[10, 9, 8],
    <int>[12, 11, 16],
    <int>[14, 13, 16],
  ];

  static const String _alphanumeric =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ \$%*+-./:';

  // BWIPP's mode optimization tables (the three full QR version groups)
  static const List<int> _mode0NbeforeB = <int>[4, 4, 5];
  static const List<int> _modeBAbeforeB = <int>[11, 15, 16];
  static const List<int> _modeBAbeforeN = <int>[12, 13, 15];
  static const List<int> _modeBAbeforeE = <int>[6, 7, 8];
  static const List<int> _modeBNbeforeB = <int>[6, 8, 9];
  static const List<int> _modeBNbeforeA = <int>[6, 7, 8];
  static const List<int> _modeBNbeforeE = <int>[3, 4, 4];
  static const List<int> _modeANbeforeA = <int>[13, 15, 17];
  static const List<int> _modeANbeforeB = <int>[13, 17, 18];
  static const List<int> _modeANbeforeE = <int>[7, 8, 9];
  static const List<int> _one = <int>[1, 1, 1];

  /// Versions 1 to 40: position of the second and third alignment pattern,
  /// modules for data and error correction, error correction codewords
  /// (L, M, Q, H) and blocks (L1, L2, M1, M2, Q1, Q2, H1, H2).
  static const List<(int, int, int, List<int>, List<int>)>
  _metrics = <(int, int, int, List<int>, List<int>)>[
    (98, 99, 208, <int>[7, 10, 13, 17], <int>[1, 0, 1, 0, 1, 0, 1, 0]), // 1
    (18, 99, 359, <int>[10, 16, 22, 28], <int>[1, 0, 1, 0, 1, 0, 1, 0]), // 2
    (22, 99, 567, <int>[15, 26, 36, 44], <int>[1, 0, 1, 0, 2, 0, 2, 0]), // 3
    (26, 99, 807, <int>[20, 36, 52, 64], <int>[1, 0, 2, 0, 2, 0, 4, 0]), // 4
    (30, 99, 1079, <int>[26, 48, 72, 88], <int>[1, 0, 2, 0, 2, 2, 2, 2]), // 5
    (34, 99, 1383, <int>[36, 64, 96, 112], <int>[2, 0, 4, 0, 4, 0, 4, 0]), // 6
    (22, 38, 1568, <int>[40, 72, 108, 130], <int>[2, 0, 4, 0, 2, 4, 4, 1]), // 7
    (24, 42, 1936, <int>[48, 88, 132, 156], <int>[2, 0, 2, 2, 4, 2, 4, 2]), // 8
    (
      26,
      46,
      2336,
      <int>[60, 110, 160, 192],
      <int>[2, 0, 3, 2, 4, 4, 4, 4],
    ), // 9
    (
      28,
      50,
      2768,
      <int>[72, 130, 192, 224],
      <int>[2, 2, 4, 1, 6, 2, 6, 2],
    ), // 10
    (
      30,
      54,
      3232,
      <int>[80, 150, 224, 264],
      <int>[4, 0, 1, 4, 4, 4, 3, 8],
    ), // 11
    (
      32,
      58,
      3728,
      <int>[96, 176, 260, 308],
      <int>[2, 2, 6, 2, 4, 6, 7, 4],
    ), // 12
    (
      34,
      62,
      4256,
      <int>[104, 198, 288, 352],
      <int>[4, 0, 8, 1, 8, 4, 12, 4],
    ), // 13
    (
      26,
      46,
      4651,
      <int>[120, 216, 320, 384],
      <int>[3, 1, 4, 5, 11, 5, 11, 5],
    ), // 14
    (
      26,
      48,
      5243,
      <int>[132, 240, 360, 432],
      <int>[5, 1, 5, 5, 5, 7, 11, 7],
    ), // 15
    (
      26,
      50,
      5867,
      <int>[144, 280, 408, 480],
      <int>[5, 1, 7, 3, 15, 2, 3, 13],
    ), // 16
    (
      30,
      54,
      6523,
      <int>[168, 308, 448, 532],
      <int>[1, 5, 10, 1, 1, 15, 2, 17],
    ), // 17
    (
      30,
      56,
      7211,
      <int>[180, 338, 504, 588],
      <int>[5, 1, 9, 4, 17, 1, 2, 19],
    ), // 18
    (
      30,
      58,
      7931,
      <int>[196, 364, 546, 650],
      <int>[3, 4, 3, 11, 17, 4, 9, 16],
    ), // 19
    (
      34,
      62,
      8683,
      <int>[224, 416, 600, 700],
      <int>[3, 5, 3, 13, 15, 5, 15, 10],
    ), // 20
    (
      28,
      50,
      9252,
      <int>[224, 442, 644, 750],
      <int>[4, 4, 17, 0, 17, 6, 19, 6],
    ), // 21
    (
      26,
      50,
      10068,
      <int>[252, 476, 690, 816],
      <int>[2, 7, 17, 0, 7, 16, 34, 0],
    ), // 22
    (
      30,
      54,
      10916,
      <int>[270, 504, 750, 900],
      <int>[4, 5, 4, 14, 11, 14, 16, 14],
    ), // 23
    (
      28,
      54,
      11796,
      <int>[300, 560, 810, 960],
      <int>[6, 4, 6, 14, 11, 16, 30, 2],
    ), // 24
    (
      32,
      58,
      12708,
      <int>[312, 588, 870, 1050],
      <int>[8, 4, 8, 13, 7, 22, 22, 13],
    ), // 25
    (
      30,
      58,
      13652,
      <int>[336, 644, 952, 1110],
      <int>[10, 2, 19, 4, 28, 6, 33, 4],
    ), // 26
    (
      34,
      62,
      14628,
      <int>[360, 700, 1020, 1200],
      <int>[8, 4, 22, 3, 8, 26, 12, 28],
    ), // 27
    (
      26,
      50,
      15371,
      <int>[390, 728, 1050, 1260],
      <int>[3, 10, 3, 23, 4, 31, 11, 31],
    ), // 28
    (
      30,
      54,
      16411,
      <int>[420, 784, 1140, 1350],
      <int>[7, 7, 21, 7, 1, 37, 19, 26],
    ), // 29
    (
      26,
      52,
      17483,
      <int>[450, 812, 1200, 1440],
      <int>[5, 10, 19, 10, 15, 25, 23, 25],
    ), // 30
    (
      30,
      56,
      18587,
      <int>[480, 868, 1290, 1530],
      <int>[13, 3, 2, 29, 42, 1, 23, 28],
    ), // 31
    (
      34,
      60,
      19723,
      <int>[510, 924, 1350, 1620],
      <int>[17, 0, 10, 23, 10, 35, 19, 35],
    ), // 32
    (
      30,
      58,
      20891,
      <int>[540, 980, 1440, 1710],
      <int>[17, 1, 14, 21, 29, 19, 11, 46],
    ), // 33
    (
      34,
      62,
      22091,
      <int>[570, 1036, 1530, 1800],
      <int>[13, 6, 14, 23, 44, 7, 59, 1],
    ), // 34
    (
      30,
      54,
      23008,
      <int>[570, 1064, 1590, 1890],
      <int>[12, 7, 12, 26, 39, 14, 22, 41],
    ), // 35
    (
      24,
      50,
      24272,
      <int>[600, 1120, 1680, 1980],
      <int>[6, 14, 6, 34, 46, 10, 2, 64],
    ), // 36
    (
      28,
      54,
      25568,
      <int>[630, 1204, 1770, 2100],
      <int>[17, 4, 29, 14, 49, 10, 24, 46],
    ), // 37
    (
      32,
      58,
      26896,
      <int>[660, 1260, 1860, 2220],
      <int>[4, 18, 13, 32, 48, 14, 42, 32],
    ), // 38
    (
      26,
      54,
      28256,
      <int>[720, 1316, 1950, 2310],
      <int>[20, 4, 40, 7, 43, 22, 10, 67],
    ), // 39
    (
      30,
      58,
      29648,
      <int>[750, 1372, 2040, 2430],
      <int>[19, 6, 18, 31, 34, 34, 20, 61],
    ), // 40
  ];

  /// The format information ids of the levels L, M, Q, H.
  static const List<int> _levelIds = <int>[1, 0, 3, 2];

  // counts of the characters of each kind from each position
  late final int _len = _msg.length;
  late final List<int> _numNs = List<int>.filled(_len + 1, 0);
  late final List<int> _numAs = List<int>.filled(_len + 1, 0);
  late final List<int> _numAorNs = List<int>.filled(_len + 1, 0);
  late final List<int> _numBs = List<int>.filled(_len + 1, 0);
  late final List<int> _nextNs = <int>[...List<int>.filled(_len, 0), 9999];
  late final List<int> _nextBs = <int>[...List<int>.filled(_len, 0), 9999];
  late final List<int> _nextAs = <int>[...List<int>.filled(_len, 0), 9999];

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  /// Alphanumeric but not a digit (BWIPP's `Aexcl`).
  static bool _isAlpha(int c) =>
      !_isDigit(c) && _alphanumeric.contains(String.fromCharCode(c));

  void _count() {
    for (int i = _len - 1; i >= 0; i--) {
      int c = _msg[i];
      if (_isDigit(c)) {
        _nextNs[i] = 0;
        _numNs[i] = _numNs[i + 1] + 1;
        _numAorNs[i] = _numAorNs[i + 1] + 1;
      } else {
        _nextNs[i] = _nextNs[i + 1] + 1;
      }
      if (_isAlpha(c)) {
        _nextAs[i] = 0;
        _numAs[i] = _numAs[i + 1] + 1;
        _numAorNs[i] = _numAorNs[i + 1] + 1;
      } else {
        _nextAs[i] = _nextAs[i + 1] + 1;
      }
    }
    for (int i = _len - 1; i >= 0; i--) {
      if (_numNs[i] + _numAs[i] == 0) {
        _nextBs[i] = 0;
        _numBs[i] = _numBs[i + 1] + 1;
      } else {
        _nextBs[i] = _nextBs[i + 1] + 1;
      }
    }
  }

  /// The segments (mode, bytes) of the message for version group [ver],
  /// like BWIPP picks them.
  List<(int, List<int>)> _segments(int ver) {
    List<(int, List<int>)> seq = <(int, List<int>)>[];
    int mode = -1;
    int i = 0;
    while (i < _len) {
      int numB = _numBs[i];
      int numA = _numAs[i];
      int numN = _numNs[i];
      int numAorN = _numAorNs[i];
      bool aBefore(List<int> t, List<int> next) =>
          numA >= t[ver] && next[numA + i] == 0;
      bool aBeforeEnd(List<int> t) => numA >= t[ver] && numA + i == _len;
      bool nBefore(List<int> t, List<int> next) =>
          numN >= t[ver] && next[numN + i] == 0;
      bool nBeforeEnd(List<int> t) => numN >= t[ver] && numN + i == _len;
      bool aorNBeforeB(List<int> t) =>
          numAorN >= t[ver] && _nextBs[numAorN + i] == 0;
      bool aorNBeforeEnd(List<int> t) =>
          numAorN >= t[ver] && numAorN + i == _len;
      bool nextNsLess(List<int> t) =>
          _nextNs[i] >= _len || _numNs[_nextNs[i] + i] < t[ver];
      int next;
      if (mode == -1) {
        if (nBefore(_mode0NbeforeB, _nextBs)) {
          next = _n;
        } else if (nBefore(_one, _nextBs)) {
          next = _b;
        } else if (nBefore(_modeANbeforeE, _nextAs) || nBeforeEnd(_one)) {
          next = _n;
        } else if (aorNBeforeB(_modeBAbeforeE) || aorNBeforeEnd(_one)) {
          next = _a;
        } else {
          next = _b;
        }
      } else if (mode == _b) {
        if (aBefore(_modeBAbeforeB, _nextBs) ||
            aBefore(_modeBAbeforeN, _nextNs) ||
            aBeforeEnd(_modeBAbeforeE)) {
          next = _a;
        } else if (nBefore(_modeBNbeforeB, _nextBs) ||
            nBefore(_modeBNbeforeA, _nextAs) ||
            nBeforeEnd(_modeBNbeforeE)) {
          next = _n;
        } else if (aorNBeforeEnd(_modeBAbeforeE) &&
            numAorN <= _modeBAbeforeN[ver] &&
            nextNsLess(_modeBNbeforeA)) {
          next = _a;
        } else {
          next = _b;
        }
      } else if (mode == _a) {
        if (numB >= 1) {
          next = _b;
        } else if (nBefore(_modeANbeforeA, _nextAs) ||
            nBefore(_modeANbeforeB, _nextBs) ||
            nBeforeEnd(_modeANbeforeE)) {
          next = _n;
        } else if (numA >= 1 || numN >= 1) {
          next = _a;
        } else {
          next = _b;
        }
      } else {
        next = numB >= 1
            ? _b
            : numA >= 1
            ? _a
            : numN >= 1
            ? _n
            : _b;
      }
      List<int> dat;
      if (next == mode) {
        dat = _msg.sublist(i, i + 1);
        seq.last.$2.addAll(dat);
      } else {
        mode = next;
        int count = switch (mode) {
          _b => numB,
          _a => numA,
          _ => numN,
        };
        dat = _msg.sublist(i, i + count);
        seq.add((mode, List<int>.of(dat)));
      }
      i += dat.length;
    }
    return seq;
  }

  static String _bin(int value, int width) =>
      value.toRadixString(2).padLeft(width, '0');

  /// The bits of the segments for version group [ver], or null when a
  /// segment is too long for its character count. More than 23648 bits
  /// throw, like BWIPP's `addtobits`.
  static String? _bits(List<(int, List<int>)> seq, int ver) {
    StringBuffer out = StringBuffer();
    void add(String bits) {
      if (out.length + bits.length > 23648) {
        throw const BarcodeInputException.bwipp(
          'qrcodeNoValidSymbol#27236',
          'Maximum length exceeded or invalid content',
        );
      }
      out.write(bits);
    }

    for ((int, List<int>) s in seq) {
      int mode = s.$1;
      List<int> chars = s.$2;
      int countBits = _countBits[ver][mode];
      add(_modeBits[mode]);
      if (chars.length >= 1 << countBits) return null;
      add(_bin(chars.length, countBits));
      StringBuffer data = StringBuffer();
      switch (mode) {
        case _n:
          for (int k = 0; k < chars.length; k += 3) {
            int end = k + 3 > chars.length ? chars.length : k + 3;
            String digits = String.fromCharCodes(chars.sublist(k, end));
            data.write(_bin(int.parse(digits), <int>[0, 4, 7, 10][end - k]));
          }
        case _a:
          for (int k = 0; k < chars.length; k += 2) {
            int v = _alphanumeric.indexOf(String.fromCharCode(chars[k]));
            if (k + 1 < chars.length) {
              v =
                  v * 45 +
                  _alphanumeric.indexOf(String.fromCharCode(chars[k + 1]));
              data.write(_bin(v, 11));
            } else {
              data.write(_bin(v, 6));
            }
          }
        default:
          for (int c in chars) {
            data.write(_bin(c, 8));
          }
      }
      add(data.toString());
    }
    return out.toString();
  }

  ModuleGrid _symbol() {
    _count();
    List<String?> groupBits = <String?>[
      for (int ver = 0; ver < 3; ver++) _bits(_segments(ver), ver),
    ];
    // the smallest version that holds the bits at level M
    for (int v = 1; v <= 40; v++) {
      (int, int, int, List<int>, List<int>) m = _metrics[v - 1];
      String? bits = groupBits[v <= 9 ? 0 : (v <= 26 ? 1 : 2)];
      int ncws = m.$3 ~/ 8;
      if (bits == null || bits.length > (ncws - m.$4[1]) * 8) continue;
      // raise the level while the bits still fit
      int level = 1;
      for (int l = 2; l <= 3; l++) {
        if (bits.length <= (ncws - m.$4[l]) * 8) level = l;
      }
      return _matrix(v, level, _codewords(bits, m, level));
    }
    throw _noSymbol;
  }

  /// The data and error correction codewords, interleaved.
  static List<int> _codewords(
    String bits,
    (int, int, int, List<int>, List<int>) m,
    int level,
  ) {
    int ncws = m.$3 ~/ 8;
    int ecws = m.$4[level];
    int dcws = ncws - ecws;
    int dmod = dcws * 8;
    StringBuffer padded = StringBuffer(bits);
    int term = dmod - bits.length < 4 ? dmod - bits.length : 4;
    padded.write('0' * term);
    while (padded.length % 8 != 0) {
      padded.write('0');
    }
    for (int p = 0; padded.length < dmod; p++) {
      padded.write(p.isEven ? '11101100' : '00010001');
    }
    String all = padded.toString();
    List<int> data = <int>[
      for (int c = 0; c < dcws; c++)
        int.parse(all.substring(c * 8, c * 8 + 8), radix: 2),
    ];
    int ecb1 = m.$5[level * 2];
    int ecb2 = m.$5[level * 2 + 1];
    int dcpb = dcws ~/ (ecb1 + ecb2);
    int ecpb = ncws ~/ (ecb1 + ecb2) - dcpb;
    List<int> gen = _generator(ecpb);
    List<List<int>> dataBlocks = <List<int>>[];
    for (int b = 0; b < ecb1 + ecb2; b++) {
      int start = b < ecb1 ? b * dcpb : ecb1 * dcpb + (b - ecb1) * (dcpb + 1);
      dataBlocks.add(data.sublist(start, start + (b < ecb1 ? dcpb : dcpb + 1)));
    }
    List<List<int>> ecBlocks = <List<int>>[
      for (List<int> d in dataBlocks) _remainder(d, gen),
    ];
    List<int> out = <int>[];
    for (int i = 0; i <= dcpb; i++) {
      for (List<int> d in dataBlocks) {
        if (i < d.length) out.add(d[i]);
      }
    }
    for (int i = 0; i < ecpb; i++) {
      for (List<int> e in ecBlocks) {
        out.add(e[i]);
      }
    }
    if (m.$3 % 8 > 0) out.add(0);
    return out;
  }

  static final List<int> _exp = _buildExp();
  static final List<int> _log = _buildLog();

  static List<int> _buildExp() {
    List<int> exp = <int>[1];
    for (int i = 1; i < 256; i++) {
      int v = exp.last * 2;
      exp.add(v >= 256 ? v ^ 285 : v);
    }
    return exp;
  }

  static List<int> _buildLog() {
    List<int> log = List<int>.filled(256, 0);
    for (int i = 1; i < 256; i++) {
      log[_exp[i]] = i;
    }
    return log;
  }

  static int _mul(int a, int b) =>
      a == 0 || b == 0 ? 0 : _exp[(_log[a] + _log[b]) % 255];

  /// The generator polynomial of [n] error correction codewords, lowest
  /// power first (without the leading 1).
  static List<int> _generator(int n) {
    List<int> c = List<int>.filled(n + 1, 0);
    c[0] = 1;
    for (int i = 0; i < n; i++) {
      int a = _exp[i];
      c[i + 1] = c[i];
      for (int j = i; j >= 1; j--) {
        c[j] = _mul(c[j], a) ^ c[j - 1];
      }
      c[0] = _mul(c[0], a);
    }
    return c.sublist(0, n);
  }

  /// The error correction codewords of [data] (BWIPP's `rsecbinary`).
  static List<int> _remainder(List<int> data, List<int> gen) {
    int nc = gen.length;
    List<int> s = List<int>.filled(nc, 0);
    for (int d in data) {
      int fb = d ^ s[0];
      for (int j = 0; j < nc - 1; j++) {
        s[j] = s[j + 1] ^ _mul(gen[nc - 1 - j], fb);
      }
      s[nc - 1] = _mul(gen[0], fb);
    }
    return s;
  }

  static int _bch(int gen, int shift, int data) {
    int v = data << shift;
    int genDegree = gen.bitLength - 1;
    while (v != 0 && v.bitLength - 1 >= genDegree) {
      v ^= gen << (v.bitLength - 1 - genDegree);
    }
    return (data << shift) | v;
  }

  static bool _mask(int m, int x, int y) => switch (m) {
    0 => (x + y) % 2 == 0,
    1 => y % 2 == 0,
    2 => x % 3 == 0,
    3 => (x + y) % 3 == 0,
    4 => (y ~/ 2 + x ~/ 3) % 2 == 0,
    5 => (x * y) % 2 + (x * y) % 3 == 0,
    6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
    _ => ((x * y) % 3 + (x + y) % 2) % 2 == 0,
  };

  /// The symbol of version [version] at level [level] with codewords [cws].
  static ModuleGrid _matrix(int version, int level, List<int> cws) {
    (int, int, int, List<int>, List<int>) m = _metrics[version - 1];
    int n = version * 4 + 17;
    // -1 is a data module; 0 and 1 are fixed light and dark
    List<int> pixs = List<int>.filled(n * n, -1);
    void put(int x, int y, int v) => pixs[y * n + x] = v;
    for (int i = 8; i <= n - 9; i++) {
      put(i, 6, (i + 1) % 2);
      put(6, i, (i + 1) % 2);
    }
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        put(x, y, _finder(x, y));
        put(n - x - 1, y, _finder(x, y));
        put(x, n - y - 1, _finder(x, y));
      }
    }
    void alignment(int px, int py) {
      for (int b = 0; b < 5; b++) {
        for (int a = 0; a < 5; a++) {
          bool edge = a == 0 || a == 4 || b == 0 || b == 4;
          put(px + a, py + b, edge || (a == 2 && b == 2) ? 1 : 0);
        }
      }
    }

    int asp2 = m.$1;
    int step = m.$2 - asp2;
    for (int i = asp2 - 2; i <= n - 13; i += step) {
      alignment(i, 4);
      alignment(4, i);
    }
    for (int x = asp2 - 2; x <= n - 9; x += step) {
      for (int y = asp2 - 2; y <= n - 9; y += step) {
        alignment(x, y);
      }
    }
    List<List<(int, int)>> formatMap = <List<(int, int)>>[
      for (int i = 0; i < 15; i++)
        <(int, int)>[
          i < 6
              ? (i, 8)
              : (i == 6
                    ? (7, 8)
                    : (i == 7 ? (8, 8) : (8, i == 8 ? 7 : 14 - i))),
          i < 7 ? (8, n - 1 - i) : (n - 15 + i, 8),
        ],
    ];
    for (List<(int, int)> f in formatMap) {
      for ((int, int) p in f) {
        put(p.$1, p.$2, 1);
      }
    }
    List<List<(int, int)>> versionMap = n < 45
        ? const <List<(int, int)>>[]
        : <List<(int, int)>>[
            for (int i = 0; i < 18; i++)
              <(int, int)>[
                (n - 9 - i % 3, 5 - i ~/ 3),
                (5 - i ~/ 3, n - 9 - i % 3),
              ],
          ];
    for (List<(int, int)> f in versionMap) {
      for ((int, int) p in f) {
        put(p.$1, p.$2, 0);
      }
    }
    put(8, n - 8, 0);
    // the data bits, before masking
    List<int> data = List<int>.filled(n * n, -1);
    int posx = n - 1, posy = n - 1, dir = -1, col = 1, num = 0;
    while (posx >= 0) {
      int pos = posy * n + posx;
      if (pixs[pos] == -1) {
        data[pos] = (cws[num ~/ 8] >> (7 - num % 8)) & 1;
        num++;
      }
      if (col == 1) {
        col = 0;
        posx--;
      } else {
        col = 1;
        posx++;
        posy += dir;
        if (posy < 0 || posy >= n) {
          dir = -dir;
          posy += dir;
          posx -= 2;
          if (posx == 6) posx--;
        }
      }
    }
    List<int>? best;
    int bestMask = 0;
    int bestScore = 1 << 62;
    for (int mask = 0; mask < 8; mask++) {
      List<int> sym = <int>[
        for (int pos = 0; pos < n * n; pos++)
          pixs[pos] != -1
              ? pixs[pos]
              : data[pos] ^ (_mask(mask, pos % n, pos ~/ n) ? 1 : 0),
      ];
      int score = _score(sym, n);
      if (score < bestScore) {
        best = sym;
        bestMask = mask;
        bestScore = score;
      }
    }
    List<int> sym = best!;
    sym[(n - 8) * n + 8] = 1;
    int format = _bch(0x537, 10, _levelIds[level] << 3 | bestMask) ^ 0x5412;
    for (int i = 0; i < 15; i++) {
      for ((int, int) p in formatMap[i]) {
        sym[p.$2 * n + p.$1] = (format >> (14 - i)) & 1;
      }
    }
    if (versionMap.isNotEmpty) {
      int info = _bch(0x1f25, 12, version);
      for (int i = 0; i < 18; i++) {
        for ((int, int) p in versionMap[i]) {
          sym[p.$2 * n + p.$1] = (info >> (17 - i)) & 1;
        }
      }
    }
    ModuleGrid grid = ModuleGrid(n, n);
    for (int pos = 0; pos < n * n; pos++) {
      if (sym[pos] == 1) grid.setDark(pos % n, pos ~/ n);
    }
    return grid;
  }

  /// The finder pattern with its light separator, at [x], [y] (0 to 7).
  static int _finder(int x, int y) {
    if (x == 7 || y == 7) return 0;
    int ring = (x - 3).abs() > (y - 3).abs() ? (x - 3).abs() : (y - 3).abs();
    return ring == 2 ? 0 : 1;
  }

  /// BWIPP's penalty score of a full QR symbol [sym] of [n] x [n] modules.
  static int _score(List<int> sym, int n) {
    int n1 = 0, n2 = 0, n3 = 0;
    List<int> lastPairs = List<int>.filled(n, 0);
    List<int> thisPairs = List<int>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      for (bool column in <bool>[true, false]) {
        // run lengths, starting with a light run (maybe empty)
        List<int> rle = <int>[0];
        int last = 0;
        for (int k = 0; k < n; k++) {
          int v = column ? sym[k * n + i] : sym[i * n + k];
          if (v == last) {
            rle[rle.length - 1]++;
          } else {
            rle.add(1);
            last = v;
          }
        }
        for (int r in rle) {
          if (r >= 5) n1 += r - 2;
        }
        for (int j = 3; j <= rle.length - 3; j += 2) {
          if (rle[j] % 3 != 0) continue;
          int f = rle[j] ~/ 3;
          if (rle[j - 2] != f ||
              rle[j - 1] != f ||
              rle[j + 1] != f ||
              rle[j + 2] != f) {
            continue;
          }
          if (j == 3 ||
              j + 4 >= rle.length ||
              rle[j - 3] >= 4 ||
              rle[j + 3] >= 4) {
            n3 += 40;
          }
        }
      }
      List<int> swap = thisPairs;
      thisPairs = lastPairs;
      lastPairs = swap;
      thisPairs[0] = 1;
      for (int x = 1; x < n; x++) {
        thisPairs[x] = sym[i * n + x - 1] + sym[i * n + x];
      }
      if (i > 0) {
        for (int x = 0; x < n; x++) {
          if ((lastPairs[x] + thisPairs[x]) & 3 == 0) n2 += 3;
        }
      }
    }
    int dark = sym.fold(0, (int a, int b) => a + b);
    int n4 = ((dark * 100 / (n * n) - 50).abs() / 5).truncate() * 10;
    return n1 + n2 + n3 + n4;
  }
}
