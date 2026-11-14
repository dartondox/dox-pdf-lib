import 'dart:convert';

/// Code 128 like BWIPP (bwip-js 4.11.4), so the bars are the same as in
/// pdfme: the same start code, code set switches, shifts and FNC4.
///
/// A port of the default (legacy) encoder of BWIPP's `code128`
/// (barcode.ps, version 2026-05-28, MIT license, Copyright (c) 2004-2026
/// Terry Burton) with the options bwip-js gets from pdfme: no `parse`, no
/// `parsefnc`.
class Code128Encoder {
  Code128Encoder._();

  static const int _swa = -4, _swb = -5, _swc = -6, _fn4 = -10, _sft = -11;
  static const int _sta = 103, _stb = 104, _stc = 105, _stp = 106;

  /// The widths of the bars and spaces (bar first, stop included), or null
  /// when BWIPP can not encode [value] (empty or more than 500 bytes).
  static List<int>? widths(String value) {
    // bwip-js sends text with non-ASCII letters as UTF-8 bytes
    List<int> bytes = utf8.encode(value);
    if (bytes.isEmpty || bytes.length > 500) return null;
    List<int> cws = _codewords(_withFnc4(bytes));
    int sum = cws[0];
    for (int i = 1; i < cws.length; i++) {
      sum += cws[i] * i;
    }
    cws
      ..add(sum % 103)
      ..add(_stp);
    return <int>[
      for (int cw in cws) ..._patterns[cw].codeUnits.map((int c) => c - 48),
    ];
  }

  /// FNC4 shifts and latches for bytes of 128 and more; then the low 7
  /// bits of each byte.
  static List<int> _withFnc4(List<int> msg) {
    int n = msg.length;
    List<int> numSA = List<int>.filled(n + 1, 0);
    List<int> numEA = List<int>.filled(n + 1, 0);
    for (int i = n - 1; i >= 0; i--) {
      if (msg[i] >= 128) {
        numEA[i] = numEA[i + 1] + 1;
      } else {
        numSA[i] = numSA[i + 1] + 1;
      }
    }
    List<int> out = <int>[];
    bool ea = false;
    for (int i = 0; i < n; i++) {
      int c = msg[i];
      if (ea == (c < 128)) {
        int run = ea ? numSA[i] : numEA[i];
        if (run < (i + run == n ? 3 : 5)) {
          out.add(_fn4);
        } else {
          out.addAll(<int>[_fn4, _fn4]);
          ea = !ea;
        }
      }
      out.add(c & 127);
    }
    return out;
  }

  /// The codeword of [c] in code set A (`setA`) or B.
  static int _code(int c, bool setA) => switch (c) {
    _sft => 98,
    _swc => 99,
    _swb => 100,
    _swa => 101,
    _fn4 => setA ? 101 : 100,
    _ when setA => c < 32 ? c + 64 : c - 32,
    _ => c - 32,
  };

  static List<int> _codewords(List<int> msg) {
    int n = msg.length;
    bool isDigit(int c) => c >= 48 && c <= 57;
    List<int> digits = List<int>.filled(n + 1, 0);
    for (int i = n - 1; i >= 0; i--) {
      digits[i] = isDigit(msg[i]) ? digits[i + 1] + 1 : 0;
    }
    bool aNotB(int c) => c >= 0 && c < 32;
    bool bNotA(int c) => c >= 96;
    List<int> nextA = List<int>.filled(n + 1, 9999);
    List<int> nextB = List<int>.filled(n + 1, 9999);
    for (int i = n - 1; i >= 0; i--) {
      nextA[i] = aNotB(msg[i]) ? 0 : nextA[i + 1] + 1;
      nextB[i] = bNotA(msg[i]) ? 0 : nextB[i + 1] + 1;
    }
    bool aBeforeB(int i) => nextA[i] < nextB[i];
    bool bBeforeA(int i) => nextB[i] < nextA[i];

    const int a = 0, b = 1, c = 2;
    List<int> cws = <int>[];
    int cset;
    int nums = digits[0];
    if ((n == 2 && nums == 2) || nums >= 4) {
      cws.add(_stc);
      cset = c;
    } else if (aBeforeB(0)) {
      cws.add(_sta);
      cset = a;
    } else {
      cws.add(_stb);
      cset = b;
    }
    int i = 0;
    while (i < n) {
      nums = digits[i];
      if (cset != c && nums >= 4) {
        if (nums.isEven) {
          cws.add(_code(_swc, cset == a));
          cset = c;
          continue;
        }
        cws.add(_code(msg[i], cset == a));
        i++;
        if (digits[i] >= 4) {
          cws.add(_code(_swc, cset == a));
          cset = c;
          continue;
        }
      }
      if (cset == b && aNotB(msg[i])) {
        if (i < n - 1 && bBeforeA(i + 1)) {
          cws
            ..add(_code(_sft, false))
            ..add(_code(msg[i], true));
          i++;
        } else {
          cws.add(_code(_swa, false));
          cset = a;
        }
        continue;
      }
      if (cset == a && bNotA(msg[i])) {
        if (i < n - 1 && aBeforeB(i + 1)) {
          cws
            ..add(_code(_sft, true))
            ..add(_code(msg[i], false));
          i++;
        } else {
          cws.add(_code(_swb, true));
          cset = b;
        }
        continue;
      }
      if (cset == c && nums < 2) {
        // a letter or FNC4 ends code set C
        bool toA = aBeforeB(i);
        cws.add(toA ? 101 : 100);
        cset = toA ? a : b;
        continue;
      }
      if (cset == c) {
        cws.add((msg[i] - 48) * 10 + msg[i + 1] - 48);
        i += 2;
      } else {
        cws.add(_code(msg[i], cset == a));
        i++;
      }
    }
    return cws;
  }

  /// The bar and space widths of each codeword (106 is the stop).
  static const List<String> _patterns = <String>[
    '212222', '222122', '222221', '121223', '121322', '131222', '122213', //
    '122312', '132212', '221213', '221312', '231212', '112232', '122132',
    '122231', '113222', '123122', '123221', '223211', '221132', '221231',
    '213212', '223112', '312131', '311222', '321122', '321221', '312212',
    '322112', '322211', '212123', '212321', '232121', '111323', '131123',
    '131321', '112313', '132113', '132311', '211313', '231113', '231311',
    '112133', '112331', '132131', '113123', '113321', '133121', '313121',
    '211331', '231131', '213113', '213311', '213131', '311123', '311321',
    '331121', '312113', '312311', '332111', '314111', '221411', '431111',
    '111224', '111422', '121124', '121421', '141122', '141221', '112214',
    '112412', '122114', '122411', '142112', '142211', '241211', '221114',
    '413111', '241112', '134111', '111242', '121142', '121241', '114212',
    '124112', '124211', '411212', '421112', '421211', '212141', '214121',
    '412121', '111143', '111341', '131141', '114113', '114311', '411113',
    '411311', '113141', '114131', '311141', '411131', '211412', '211214',
    '211232', '2331112',
  ];
}
