/// The four bar kinds of the Japan Post 4-state code.
enum JapanPostBar {
  /// From the top to the bottom.
  full,

  /// From the top, 5/8 of the height.
  ascender,

  /// From 3/8 of the height to the bottom.
  descender,

  /// The middle 2/8 of the height.
  tracker,

  /// No bar (a gap in BWIPP when the check character is 19).
  none,
}

/// The Japan Post customer barcode, ported from BWIPP `japanpost` (the
/// `barcode` package has no such type).
///
/// A symbol is always 67 bars: start (2), 20 characters of 3 bars, a check
/// character (3) and stop (2).
class JapanPostEncoder {
  const JapanPostEncoder._();

  static const String _chars = '0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ';

  // BWIPP `japanpost_encs`: 0 tracker, 1 descender, 2 ascender, 3 full.
  static const List<String> _encodings = <String>[
    '300', '330', '312', '132', '321', '303', '123', '231', '213', '033', //
    '030', '120', '102', '210', '012', '201', '021', '003', '333', '31', //
    '13',
  ];

  static const int _pad = 14;
  static const int _start = 19;
  static const int _stop = 20;

  /// Width of one bar and the distance from bar to bar, in points
  /// (BWIPP: bars 1.44, spaces 1.872).
  static const double barWidth = 1.44;
  static const double pitch = 1.44 + 1.872;

  /// The 67 bars of [input], or null when BWIPP would fail (a character
  /// that is not allowed, or more than 20 characters after encoding).
  static List<JapanPostBar>? encode(String input) {
    List<int>? digits = _digits(input);
    if (digits == null) return null;
    int sum = digits.fold(0, (int a, int b) => a + b);
    int check = 19 - sum % 19;
    StringBuffer pattern = StringBuffer(_encodings[_start]);
    for (int d in digits) {
      pattern.write(_encodings[d]);
    }
    // BWIPP writes "31" when the check is 19: the third bar stays empty
    pattern
      ..write(_encodings[check].padRight(3))
      ..write(_encodings[_stop]);
    return <JapanPostBar>[for (int c in pattern.toString().codeUnits) _bar(c)];
  }

  /// The 20 code values: a digit or a dash is one value, a letter two
  /// (control code + digit). The rest is padded with code 14.
  static List<int>? _digits(String input) {
    List<int> out = <int>[];
    for (int i = 0; i < input.length; i++) {
      int index = _chars.indexOf(input[i]);
      if (index < 0) return null;
      if (index >= 11) {
        if (out.length > 18) return null;
        out
          ..add((index - 1) ~/ 10 + 10)
          ..add((index - 1) % 10);
      } else {
        if (out.length > 19) return null;
        out.add(index);
      }
    }
    while (out.length < 20) {
      out.add(_pad);
    }
    return out;
  }

  static JapanPostBar _bar(int c) => switch (c) {
    0x30 => JapanPostBar.tracker,
    0x31 => JapanPostBar.descender,
    0x32 => JapanPostBar.ascender,
    0x33 => JapanPostBar.full,
    _ => JapanPostBar.none,
  };
}
