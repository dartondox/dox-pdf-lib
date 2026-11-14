import 'dart:math' as math;

import 'package:barcode/barcode.dart';

import 'barcode_symbol.dart';
import 'barcode_validator.dart';
import 'bwip_raster.dart';
import 'code128_encoder.dart';
import 'japan_post.dart';

/// A bar or a space of a linear barcode, in modules.
typedef ModuleRun = ({int start, int length, bool dark});

/// Builds linear (1D) barcodes with the geometry of bwip-js, as pdfme gets
/// them (`scale: 5`, `textxalign: 'center'`, `width` and `height` in mm).
///
/// The bars come from the `barcode` package (japanpost from
/// [JapanPostEncoder]) and are laid out like BWIPP `renlinear`; then
/// [BwipRaster] snaps them like bwip-js. The result is in bwip-js SVG
/// units, and pdfme stretches that SVG to the box in both directions.
class LinearSymbolBuilder {
  const LinearSymbolBuilder._();

  /// How far EAN and UPC guard bars go below the other bars, in points.
  static const double guardExtension = 5;

  /// The barcode of [type] for [value] in a box of [widthMm] x [heightMm],
  /// or null when [value] is empty or [type] is not linear. Throws a
  /// [BarcodeInputException] where bwip-js throws (pdfme's `generate`
  /// fails then too).
  static BarcodeSymbol? build(
    String type,
    String value, {
    required double widthMm,
    required double heightMm,
    required bool includeText,
  }) {
    if (value.isEmpty) return null;
    checkBwipText(value);
    _Layout l = _Layout(widthMm, heightMm / 25.4 * 72, includeText);
    try {
      return switch (type) {
        'ean13' => _ean(l, Barcode.ean13(), value, _ean13Guards),
        'ean8' => _ean(l, Barcode.ean8(), value, _ean8Guards),
        'upca' => _ean(l, Barcode.upcA(), value, _upcaGuards),
        'upce' => _upce(l, value),
        'code39' => _code39(l, value),
        'code128' => _code128(l, value),
        'nw7' => _nw7(l, value),
        'itf14' => _itf14(l, value),
        'japanpost' => _japanPost(l, value),
        _ => null,
      };
    } on BarcodeException {
      return null;
    }
  }

  // Module ranges of the guard bars (UPC-A: also the first and last digit).
  static const List<(int, int)> _ean13Guards = <(int, int)>[
    (0, 3),
    (45, 50),
    (92, 95),
  ];
  static const List<(int, int)> _ean8Guards = <(int, int)>[
    (0, 3),
    (31, 36),
    (64, 67),
  ];
  static const List<(int, int)> _upcaGuards = <(int, int)>[
    (0, 10),
    (45, 50),
    (85, 95),
  ];

  /// The bars and spaces of [barcode] for [data], from the `barcode`
  /// package. Spaces at both ends are dropped. With [wideToThree], wide
  /// elements (2 modules in the package) become 3 modules, like BWIPP.
  static List<ModuleRun> moduleRuns(
    Barcode barcode,
    String data, {
    bool wideToThree = false,
  }) {
    List<BarcodeBar> bars = <BarcodeBar>[
      for (BarcodeElement e in barcode.make(data, width: 10000, height: 1))
        if (e is BarcodeBar) e,
    ];
    while (bars.isNotEmpty && !bars.first.black) {
      bars.removeAt(0);
    }
    while (bars.isNotEmpty && !bars.last.black) {
      bars.removeLast();
    }
    if (bars.isEmpty) return const <ModuleRun>[];
    // every symbology here has a one module element
    double unit = bars.map((BarcodeBar b) => b.width).reduce(math.min);
    List<ModuleRun> runs = <ModuleRun>[];
    int start = 0;
    for (BarcodeBar b in bars) {
      int length = (b.width / unit).round();
      if (wideToThree && length == 2) length = 3;
      runs.add((start: start, length: length, dark: b.black));
      start += length;
    }
    return runs;
  }

  /// Code 128 with our port of the BWIPP encoder, so the code sets are the
  /// same as in bwip-js.
  static BarcodeSymbol? _code128(_Layout l, String value) {
    List<int> widths = Code128Encoder.widths(value);
    List<ModuleRun> runs = <ModuleRun>[];
    int start = 0;
    for (int i = 0; i < widths.length; i++) {
      runs.add((start: start, length: widths[i], dark: i.isEven));
      start += widths[i];
    }
    return l.runs(runs, _printable(value));
  }

  /// EAN and UPC: with text, the guard bars go 5 pt lower.
  static BarcodeSymbol _ean(
    _Layout l,
    Barcode barcode,
    String value,
    List<(int, int)> guards,
  ) {
    bool isGuard(int module) {
      for ((int, int) g in guards) {
        if (module >= g.$1 && module < g.$2) return true;
      }
      return false;
    }

    return l.runs(
      moduleRuns(barcode, value),
      (barcode as BarcodeEan).normalize(value),
      longer: l.includeText ? isGuard : null,
    );
  }

  /// Code 39. pdfme lets any white space through; BWIPP takes only spaces.
  static BarcodeSymbol _code39(_Layout l, String value) {
    if (!_code39Chars.hasMatch(value)) {
      throw const BarcodeInputException.bwipp(
        'code39badCharacter#10257',
        'Code 39 must contain only digits, capital letters, spaces and the '
            r'symbols -.$/+%',
      );
    }
    return l.runs(
      moduleRuns(Barcode.code39(), value, wideToThree: true),
      '*$value*',
    );
  }

  static final RegExp _code39Chars = RegExp(r'^[0-9A-Z \-.$/+%]*$');

  /// UPC-E like BWIPP: the check digit comes from the UPC-A the code
  /// stands for. (The `barcode` package got it wrong for some codes, like
  /// 0481683.)
  static BarcodeSymbol _upce(_Layout l, String value) {
    (List<int>, int) upce = upceWidths(value);
    List<ModuleRun> runs = <ModuleRun>[];
    int start = 0;
    // bars and spaces take turns, starting with the bar of the start guard
    for (int i = 0; i < upce.$1.length; i++) {
      runs.add((start: start, length: upce.$1[i], dark: i.isEven));
      start += upce.$1[i];
    }
    return l.runs(
      runs,
      '${value.substring(0, 7)}${upce.$2}',
      longer: l.includeText ? (int m) => m < 3 || m >= 45 : null,
    );
  }

  /// The bar and space widths of the UPC-E [value] (7 or 8 digits, number
  /// system 0) and its check digit. A wrong check digit throws, like
  /// bwip-js.
  static (List<int>, int) upceWidths(String value) {
    List<int> d = value.codeUnits.map((int c) => c - 48).toList();
    // the UPC-A of the 6 digits after the number system
    List<int> upca = switch (d[6]) {
      <= 2 => <int>[...d.sublist(0, 3), d[6], 0, 0, 0, 0, ...d.sublist(3, 6)],
      3 => <int>[...d.sublist(0, 4), 0, 0, 0, 0, 0, d[4], d[5]],
      4 => <int>[...d.sublist(0, 5), 0, 0, 0, 0, 0, d[5]],
      _ => <int>[...d.sublist(0, 6), 0, 0, 0, 0, d[6]],
    };
    int sum = 0;
    for (int i = 0; i < 11; i++) {
      sum += upca[i] * (i.isOdd ? 1 : 3);
    }
    int check = (10 - sum % 10) % 10;
    if (d.length == 8 && d[7] != check) {
      throw const BarcodeInputException.bwipp(
        'upcEbadCheckDigit#7845',
        'Incorrect UPC check digit provided',
      );
    }
    String mirror = _upceMirrors[check];
    List<int> widths = <int>[1, 1, 1];
    for (int i = 1; i <= 6; i++) {
      List<int> enc = _upceEncs[d[i]].codeUnits.map((int c) => c - 48).toList();
      // a 1 in the map (inverted for number system 0): reversed digit
      if ((mirror[i - 1] == '1') != (d[0] == 0)) enc = enc.reversed.toList();
      widths.addAll(enc);
    }
    widths.addAll(<int>[1, 1, 1, 1, 1, 1]);
    return (widths, check);
  }

  static const List<String> _upceEncs = <String>[
    '3211', '2221', '2122', '1411', '1132', //
    '1231', '1114', '1312', '1213', '3112',
  ];
  static const List<String> _upceMirrors = <String>[
    '000111', '001011', '001101', '001110', '010011', //
    '011001', '011100', '010101', '010110', '011010',
  ];

  static BarcodeSymbol? _nw7(_Layout l, String value) {
    // BWIPP takes only capital start and stop letters
    if (value != value.toUpperCase()) {
      throw const BarcodeInputException.bwipp(
        'rationalizedCodabarBadStartStop#15508',
        'Codabar start and stop characters must be one of A B C or D',
      );
    }
    return l.runs(
      moduleRuns(
        Barcode.codabar(explicitStartStop: true),
        value,
        wideToThree: true,
      ),
      value,
    );
  }

  /// ITF-14 with its bearer box (BWIPP: border width 4, 10 modules of
  /// quiet zone left and right, -0.55 top and bottom).
  static BarcodeSymbol _itf14(_Layout l, String value) {
    String digits = value.length == 13 ? value + gtinCheckDigit(value) : value;
    return l.runs(
      moduleRuns(Barcode.itf14(drawBorder: false), digits),
      digits,
      border: const BwippBorder(
        left: 10,
        right: 10,
        top: -0.55,
        bottom: -0.55,
        lineWidth: 4,
      ),
    );
  }

  /// Japan Post: bars 1.44 wide, 1.872 apart, in four heights.
  static BarcodeSymbol? _japanPost(_Layout l, String value) {
    // the characters are checked before (validateBarcodeInput), so no bars
    // means more than 20 characters after encoding
    List<JapanPostBar> bars =
        JapanPostEncoder.encode(value) ??
        (throw const BarcodeInputException.bwipp(
          'japanpostTooLong#17271',
          'The input is too long',
        ));
    double eighth = l.heightPt / 8;
    const double w = JapanPostEncoder.barWidth;
    return l.render(
      <BwippBar>[
        // BWIPP draws the empty bar (check character 19) with no height;
        // bwip-js still shows it as a 1 unit mark at the bottom
        for (int i = 0; i < bars.length; i++)
          BwippBar(
            i * JapanPostEncoder.pitch + w / 2,
            w,
            switch (bars[i]) {
              JapanPostBar.ascender || JapanPostBar.tracker => 3 * eighth,
              _ => 0,
            },
            switch (bars[i]) {
              JapanPostBar.full => 8 * eighth,
              JapanPostBar.ascender || JapanPostBar.descender => 5 * eighth,
              JapanPostBar.none => 0,
              _ => 2 * eighth,
            },
          ),
      ],
      (bars.length - 1) * JapanPostEncoder.pitch + w,
      value,
    );
  }

  /// [text] without the characters OCR-B (and Helvetica) can not show,
  /// like control characters. bwip-js skips them too.
  static String _printable(String text) => String.fromCharCodes(
    text.codeUnits.where(
      (int c) => (c >= 0x20 && c < 0x7f) || (c >= 0xa0 && c <= 0xff),
    ),
  );

  /// How much lower than digits the OCR-B glyphs of [text] go, in SVG
  /// units (measured in bwip-js).
  static int textDescent(String text) {
    int extra = 0;
    for (int c in text.codeUnits) {
      extra = math.max(extra, _descent[String.fromCharCode(c)] ?? 0);
    }
    return extra;
  }

  static const Map<String, int> _descent = <String, int>{
    '!': 2,
    '?': 2,
    ',': 7,
    ';': 7,
    'j': 7,
    'p': 7,
    'q': 7,
    'y': 7,
    'g': 8,
    '|': 6,
    '_': 10,
  };

  /// The OCR-B advance widths of [text], in font units (1000 per em).
  static List<int> ocrBAdvances(String text) => <int>[
    for (int c in text.codeUnits)
      _wide.contains(c) ? 723 : (_medium.contains(c) ? 713 : 703),
  ];

  static final Set<int> _wide = r''' !"#&'()*+,-./:;<=>?@[\]^_`{|}~'''.codeUnits
      .toSet();
  static final Set<int> _medium = '1ijl'.codeUnits.toSet();
}

/// The size and options of one linear barcode.
class _Layout {
  _Layout(this.widthMm, this.heightPt, this.includeText);

  final double widthMm;

  /// The bar height (BWIPP `height`), in points.
  final double heightPt;

  final bool includeText;

  /// Bars from module [runs]. [longer] bars go
  /// [LinearSymbolBuilder.guardExtension] lower.
  BarcodeSymbol runs(
    List<ModuleRun> runs,
    String text, {
    bool Function(int module)? longer,
    BwippBorder? border,
  }) {
    double ext = LinearSymbolBuilder.guardExtension;
    List<BwippBar> bars = <BwippBar>[
      for (ModuleRun r in runs)
        if (r.dark)
          longer != null && longer(r.start)
              ? BwippBar(_center(r), r.length * 1.0, -ext, heightPt + ext)
              : BwippBar(_center(r), r.length * 1.0, 0, heightPt),
    ];
    double width = runs.isEmpty ? 0 : _center(runs.last) + runs.last.length / 2;
    return render(bars, width, text, border: border);
  }

  static double _center(ModuleRun r) => r.start + r.length / 2;

  BarcodeSymbol render(
    List<BwippBar> bars,
    double symbolWidth,
    String text, {
    BwippBorder? border,
  }) => BwipRaster(widthMm: widthMm, symbolWidth: symbolWidth).render(
    bars,
    border: border,
    text: includeText ? text : null,
    textAdvances: LinearSymbolBuilder.ocrBAdvances(text),
    textDescent: LinearSymbolBuilder.textDescent(text),
  );
}
