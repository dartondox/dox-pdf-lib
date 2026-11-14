import 'dart:typed_data';

/// The Data Matrix codewords like BWIPP (bwip-js 4.11.4), so a GS1 Data
/// Matrix is the same as in pdfme: the same ASCII, C40, Text, X12, EDIFACT
/// and Base 256 runs, and the same square size.
///
/// A port of the encodation of BWIPP's `datamatrix` (barcode.ps, version
/// 2026-05-28, MIT license, Copyright (c) 2004-2026 Terry Burton) with the
/// options bwip-js gets from pdfme's `gs1datamatrix`: square symbols, no
/// ECI, no macro, no C40 header. The `barcode` package then adds the error
/// correction and places the modules (that part has no choices).
class DataMatrixCodewords {
  DataMatrixCodewords._(this._msg);

  /// FNC1 in the message.
  static const int fnc1 = -1;

  static const int _a = 0, _c = 1, _t = 2, _x = 3, _e = 4, _b = 5;
  static const int _sft1 = -13, _unl = -10;

  /// The data codewords of [msg] (bytes and [fnc1]), padded to fill the
  /// smallest square symbol; null when it does not fit.
  static List<int>? codewords(List<int> msg) {
    if (msg.isEmpty) return null;
    try {
      return DataMatrixCodewords._(msg)._encode();
    } on StateError {
      return null;
    }
  }

  /// Data codewords of the square symbols, 10x10 to 144x144.
  static const List<int> _capacities = <int>[
    3, 5, 8, 12, 18, 22, 30, 36, 44, 62, 86, 114, 144, 174, 204, 280, //
    368, 456, 576, 696, 816, 1050, 1304, 1558,
  ];

  final List<int> _msg;
  late final int _len = _msg.length;
  final List<int> _cws = <int>[];
  int _mode = _a;
  int _i = 0;
  late final List<int> _numD = List<int>.filled(_len + 1, 0);
  late final List<int> _nextXterm = List<int>.filled(_len + 1, 9999);
  late final List<int> _nextNonX = List<int>.filled(_len + 1, 9999);

  /// The codewords left to the end of the smallest symbol that holds more
  /// than [used] codewords (BWIPP's `numremcws`).
  static int _remaining(int used) {
    for (int c in _capacities) {
      if (c > used) return c - used;
    }
    throw StateError('too much data');
  }

  static bool _isDigit(int c) => c >= 48 && c <= 57;

  /// The values of [c] in mode [mode], or null when it has none.
  static List<int>? _values(int mode, int c) {
    switch (mode) {
      case _a:
        if (c == fnc1) return <int>[232];
        if (c >= 128) return <int>[235, c - 127];
        return c >= 0 ? <int>[c + 1] : null;
      case _c:
      case _t:
        if (c >= 128) {
          List<int>? low = _values(mode, c - 128);
          return low == null ? null : <int>[1, 30, ...low];
        }
        if (c == fnc1) return <int>[1, 27];
        if (c == _sft1) return <int>[0];
        if (c == 32) return <int>[3];
        if (_isDigit(c)) return <int>[c - 44];
        if (mode == _c && c >= 65 && c <= 90) return <int>[c - 51];
        if (mode == _t && c >= 97 && c <= 122) return <int>[c - 83];
        if (c >= 0 && c <= 31) return <int>[0, c];
        if (c >= 33 && c <= 47) return <int>[1, c - 33];
        if (c >= 58 && c <= 64) return <int>[1, c - 43];
        if (c >= 91 && c <= 95) return <int>[1, c - 69];
        if (mode == _c) return c >= 96 && c <= 127 ? <int>[2, c - 96] : null;
        if (c == 96) return <int>[2, 0];
        if (c >= 65 && c <= 90) return <int>[2, c - 64];
        return c >= 123 && c <= 127 ? <int>[2, c - 96] : null;
      case _x:
        return switch (c) {
          13 => <int>[0],
          42 => <int>[1],
          62 => <int>[2],
          32 => <int>[3],
          _ when _isDigit(c) => <int>[c - 44],
          _ when c >= 65 && c <= 90 => <int>[c - 51],
          _ => null,
        };
      case _e:
        if (c == _unl) return <int>[31];
        if (c >= 64 && c <= 94) return <int>[c - 64];
        return c >= 32 && c <= 63 ? <int>[c] : null;
      default:
        return c >= 0 && c <= 255 ? <int>[c] : null;
    }
  }

  /// The ASCII latch codewords to C40, Text, X12, EDIFACT and Base 256.
  static const List<int> _latch = <int>[0, 230, 239, 238, 240, 231];

  List<int> _encode() {
    for (int i = _len - 1; i >= 0; i--) {
      int c = _msg[i];
      if (_isDigit(c)) _numD[i] = _numD[i + 1] + 1;
      _nextXterm[i] = c == 13 || c == 42 || c == 62 ? 0 : _nextXterm[i + 1] + 1;
      _nextNonX[i] = _values(_x, c) == null ? 0 : _nextNonX[i + 1] + 1;
    }
    for (int i = 0; i <= _len; i++) {
      if (_nextXterm[i] > 10000) _nextXterm[i] = 10000;
      if (_nextNonX[i] > 10000) _nextNonX[i] = 10000;
    }
    if (_msg[0] == fnc1) {
      _cws.add(232);
      _i = 1;
    }
    while (_i < _len) {
      switch (_mode) {
        case _a:
          _encA();
        case _c:
        case _t:
        case _x:
          _encCTX();
        case _e:
          _encE();
        default:
          _encB();
      }
    }
    // pseudo-random padding to fill the symbol
    int datlen = _cws.length;
    int rem = _remaining(_cws.length - 1) - 1;
    if (rem > 0) {
      _cws.add(129);
      for (int i = datlen + 1; i < datlen + rem; i++) {
        int v = (i + 1) * 149 % 253 + 1 + 129;
        _cws.add(v > 254 ? v - 254 : v);
      }
    }
    return _cws;
  }

  /// The best mode for the message from [_i] on (BWIPP's look-ahead).
  int _lookup() {
    double ac = 1, cc = 2, tc = 2, xc = 2, ec = 2, bc = 2.25;
    if (_mode == _a) {
      ac = 0;
      cc = tc = xc = ec = 1;
      bc = 1.25;
    }
    if (_mode == _c) cc = 0;
    if (_mode == _t) tc = 0;
    if (_mode == _x) xc = 0;
    if (_mode == _e) ec = 0;
    if (_mode == _b) bc = 0;
    bool isFnc1 = _msg[_i] == fnc1;
    bool le(double v, List<double> others) =>
        others.every((double o) => v <= o);
    bool lt(double v, List<double> others) => others.every((double o) => v < o);
    for (int k = 0; ; k++) {
      if (_i + k == _len) {
        ac = ac.ceilToDouble();
        cc = cc.ceilToDouble();
        tc = tc.ceilToDouble();
        xc = xc.ceilToDouble();
        ec = ec.ceilToDouble();
        bc = bc.ceilToDouble();
        if (le(ac, <double>[cc, tc, xc, ec, bc])) return _a;
        if (lt(bc, <double>[ac, cc, tc, xc, ec])) return isFnc1 ? _a : _b;
        if (lt(ec, <double>[ac, cc, tc, xc, bc])) return _e;
        if (lt(tc, <double>[ac, cc, xc, ec, bc])) return _t;
        if (lt(xc, <double>[ac, cc, tc, ec, bc])) return _x;
        return _c;
      }
      int ch = _msg[_i + k];
      bool ea = ch > 127;
      // bwip-js keeps these sums in single precision, with the fractions
      // rounded to 7 digits, like PostScript reals
      ac = _isDigit(ch) ? _f(ac + 0.5) : ac.ceilToDouble() + (ea ? 2 : 1);
      cc = _f(cc + (_cn(ch, _c) ? 0.6666667 : (ea ? 2.6666667 : 1.3333334)));
      tc = _f(tc + (_cn(ch, _t) ? 0.6666667 : (ea ? 2.6666667 : 1.3333334)));
      xc = _f(
        xc +
            (_values(_x, ch) != null
                ? 0.6666667
                : (ea ? 4.3333334 : 3.3333334)),
      );
      ec = _f(ec + (ch >= 32 && ch <= 94 ? 0.75 : (ea ? 4.25 : 3.25)));
      bc += ch < 0 ? 4 : 1;
      if (k >= 4) {
        if (le(ac + 1, <double>[cc, tc, xc, ec, bc])) return _a;
        if (bc + 1 <= ac) return isFnc1 ? _a : _b;
        if (lt(bc + 1, <double>[cc, tc, xc, ec])) return isFnc1 ? _a : _b;
        if (lt(ec + 1, <double>[ac, cc, tc, xc, bc])) return _e;
        if (lt(tc + 1, <double>[ac, cc, xc, ec, bc])) return _t;
        if (lt(xc + 1, <double>[ac, cc, tc, ec, bc])) return _x;
        if (lt(cc + 1, <double>[ac, tc, ec, bc])) {
          if (cc < xc) return _c;
          if (cc == xc) {
            int p = _i + k + 1;
            return _nextXterm[p] < _nextNonX[p] ? _x : _c;
          }
        }
      }
    }
  }

  static final Float32List _single = Float32List(1);

  /// [v] rounded to single precision (bwip-js `\$f`); whole numbers stay.
  static double _f(double v) {
    if (v == v.truncateToDouble() && v.abs() < 2147483648) return v;
    _single[0] = v;
    return _single[0];
  }

  /// A "basic" C40 or Text character: one value (space, digit, letter).
  static bool _cn(int ch, int mode) =>
      ch == 32 ||
      _isDigit(ch) ||
      (mode == _c ? ch >= 65 && ch <= 90 : ch >= 97 && ch <= 122);

  /// One or two digits, or one character, in ASCII.
  void _asciiStep() {
    if (_numD[_i] >= 2) {
      _cws.add((_msg[_i] - 48) * 10 + _msg[_i + 1] - 48 + 130);
      _i += 2;
    } else {
      _cws.addAll(_values(_a, _msg[_i])!);
      _i++;
    }
  }

  void _encA() {
    if (_numD[_i] >= 2) {
      _asciiStep();
      return;
    }
    int next = _lookup();
    if (next != _mode) {
      _cws.add(_latch[next]);
      _mode = next;
      return;
    }
    _cws.addAll(_values(_a, _msg[_i])!);
    _i++;
  }

  static List<int> _ctxCodewords(List<int> v) => <int>[
    for (int k = 0; k < v.length; k += 3) ...<int>[
      (v[k] * 1600 + v[k + 1] * 40 + v[k + 2] + 1) ~/ 256,
      (v[k] * 1600 + v[k + 1] * 40 + v[k + 2] + 1) % 256,
    ],
  ];

  void _encCTX() {
    List<int> ctx = <int>[];
    while (_i < _len) {
      List<int>? vals = _values(_mode, _msg[_i]);
      if (vals == null) break;
      if (ctx.length % 3 == 0) {
        if (ctx.isNotEmpty) {
          int next = _lookup();
          if (next != _mode) {
            _cws
              ..addAll(_ctxCodewords(ctx))
              ..add(254);
            if (next != _a) _cws.add(_latch[next]);
            _mode = next;
            return;
          }
        }
        if (_len - _i <= 3) {
          int rem = _remaining(_cws.length + ctx.length ~/ 3 * 2);
          List<int> remVals = <int>[
            for (int c in _msg.sublist(_i))
              ...(_values(_mode, c) ?? <int>[-1, -1, -1, -1]),
          ];
          if (rem == 2 && remVals.length == 3) {
            _cws.addAll(_ctxCodewords(<int>[...ctx, ...remVals]));
            _endOfData();
            return;
          }
          if (rem == 2 && remVals.length == 2 && _mode != _x) {
            _cws.addAll(_ctxCodewords(<int>[...ctx, ...remVals, 0]));
            _endOfData();
            return;
          }
          if (rem == 2 && remVals.length == 1) {
            _cws
              ..addAll(_ctxCodewords(ctx))
              ..add(254)
              ..addAll(_values(_a, _msg[_i])!);
            _endOfData();
            return;
          }
          if (rem == 1 && remVals.length == 1) {
            _cws
              ..addAll(_ctxCodewords(ctx))
              ..addAll(_values(_a, _msg[_i])!);
            _endOfData();
            return;
          }
        }
      }
      ctx.addAll(vals);
      _i++;
    }
    // back to a boundary of 3 values, then ASCII
    while (ctx.length % 3 != 0) {
      _i--;
      ctx.length -= _values(_mode, _msg[_i])!.length;
    }
    _cws
      ..addAll(_ctxCodewords(ctx))
      ..add(254);
    _mode = _a;
    if (_i != _len) _asciiStep();
  }

  void _endOfData() {
    _mode = _a;
    _i = _len;
  }

  static List<int> _edifactCodewords(List<int> v) {
    int outLen = (v.length / 4 * 3).ceil();
    List<int> padded = <int>[...v, 0, 0, 0];
    List<int> out = <int>[];
    for (int k = 0; k < v.length; k += 4) {
      int n =
          padded[k] << 18 |
          padded[k + 1] << 12 |
          padded[k + 2] << 6 |
          padded[k + 3];
      out.addAll(<int>[n >> 16 & 255, n >> 8 & 255, n & 255]);
    }
    return out.sublist(0, outLen);
  }

  void _encE() {
    List<int> ed = <int>[];
    while (_i < _len) {
      List<int>? vals = _values(_e, _msg[_i]);
      if (vals == null) break;
      if (ed.length % 4 == 0) {
        if (_len - _i <= 2) {
          int rem = _remaining(_cws.length + ed.length ~/ 4 * 3);
          List<int> remVals = <int>[
            for (int c in _msg.sublist(_i)) ..._values(_a, c)!,
          ];
          if ((rem == 1 || rem == 2) && remVals.length <= rem) {
            _cws
              ..addAll(_edifactCodewords(ed))
              ..addAll(remVals);
            _endOfData();
            return;
          }
        }
        if (_lookup() != _mode) break;
      }
      ed.addAll(vals);
      _i++;
    }
    int rem = _remaining(_cws.length + ed.length ~/ 4 * 3 - 1) - 1;
    if (ed.length % 4 != 0 || _i != _len || rem >= 3) ed.add(31);
    _cws.addAll(_edifactCodewords(ed));
    _mode = _a;
    if (_i != _len) _asciiStep();
  }

  void _encB() {
    List<int> bytes = <int>[];
    while (_i < _len && _lookup() == _mode) {
      bytes.add(_msg[_i]);
      _i++;
    }
    int p = bytes.length;
    int rem = _remaining(_cws.length + p) - 1;
    List<int> vals = <int>[
      if (rem == 0 && _i == _len)
        0
      else if (p < 250)
        p
      else ...<int>[p ~/ 250 + 249, p % 250],
      ...bytes,
    ];
    int j = _cws.length;
    for (int k = 0; k < vals.length; k++) {
      int v = (j + k + 1) * 149 % 255 + 1 + vals[k];
      _cws.add(v >= 256 ? v - 256 : v);
    }
    _mode = _a;
  }
}
