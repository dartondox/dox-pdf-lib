import 'dart:math' as math;

import 'package:barcode/barcode.dart';

import 'barcode_symbol.dart';
import 'barcode_validator.dart';
import 'bwip_raster.dart';
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
  /// or null when the value can not be encoded (pdfme would get an error
  /// from bwip-js; we draw nothing).
  static BarcodeSymbol? build(
    String type,
    String value, {
    required double widthMm,
    required double heightMm,
    required bool includeText,
  }) {
    _Layout l = _Layout(widthMm, heightMm / 25.4 * 72, includeText);
    try {
      return switch (type) {
        'ean13' => _ean(l, Barcode.ean13(), value, _ean13Guards),
        'ean8' => _ean(l, Barcode.ean8(), value, _ean8Guards),
        'upca' => _ean(l, Barcode.upcA(), value, _upcaGuards),
        'upce' => _ean(l, Barcode.upcE(), value, _upceGuards),
        'code39' => l.runs(
          moduleRuns(Barcode.code39(), value, wideToThree: true),
          '*$value*',
        ),
        'code128' => l.runs(
          moduleRuns(Barcode.code128(), value),
          _printable(value),
        ),
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
  static const List<(int, int)> _upceGuards = <(int, int)>[(0, 3), (45, 51)];

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

  static BarcodeSymbol? _nw7(_Layout l, String value) {
    // BWIPP takes only capital start and stop letters
    if (value != value.toUpperCase()) return null;
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
    List<JapanPostBar>? bars = JapanPostEncoder.encode(value);
    if (bars == null) return null;
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
