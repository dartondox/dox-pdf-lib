import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import '../constants.dart';
import '../fonts/font_metrics.dart';
import 'wrap.dart';

/// Measures text like pdfme: the advance widths of the shaped glyphs (no
/// kerning), plus the character spacing between the UTF-16 code units.
class TextMeasure {
  TextMeasure(this.font, this.metrics);

  final PDFFont font;
  final FontMetrics metrics;

  // ponytail: one map per text box, no size limit. pdfme keeps 5000.
  final Map<String, double> _widths = <String, double>{};

  /// pdfme's `widthOfTextAtSize`. For `''` it gives `-characterSpacing`,
  /// like pdfme.
  double width(String text, double size, double characterSpacing) {
    double base = _widths['$size\u0000$text'] ??= font.widthOfTextAtSize(
      text,
      size,
    );
    return base + (text.length - 1) * characterSpacing;
  }

  /// The width used for wrapping: 0 for an empty text.
  double measureForWrap(String text, double size, double characterSpacing) =>
      text.isEmpty ? 0 : width(text, size, characterSpacing);

  /// The lines of [value] in a box [maxWidth] points wide.
  List<WrapLine> wrap(
    String value,
    double size,
    double characterSpacing,
    double maxWidth,
  ) => wrapText(
    value,
    (String t) => measureForWrap(t, size, characterSpacing),
    maxWidth,
  );

  /// pdfme's `getLineBoxHeightPt`: the first line is the ascent, the other
  /// lines are the font size.
  double lineBoxHeight(double size, {required bool firstLine}) =>
      firstLine ? metrics.heightAtSize(size) : size;
}

/// The `dynamicFontSize` setting of a text schema.
class DynamicFontSize {
  const DynamicFontSize({
    required this.min,
    required this.max,
    this.fit = 'vertical',
  });

  /// Null when [json] is not a map (pdfme: no dynamic size).
  static DynamicFontSize? fromJson(Object? json) {
    if (json is! Map) return null;
    double read(String key) {
      Object? v = json[key];
      return v is num ? v.toDouble() : double.nan;
    }

    Object? fit = json['fit'];
    return DynamicFontSize(
      min: read('min'),
      max: read('max'),
      fit: fit is String ? fit : 'vertical',
    );
  }

  final double min;
  final double max;

  /// `vertical` (default) or `horizontal`.
  final String fit;

  static const double step = 0.25;

  /// pdfme's `calculateDynamicFontSize` + `fitDynamicFontSize`. Box sizes
  /// are in millimetres.
  double resolveSize({
    required TextMeasure measure,
    required String value,
    required double startSize,
    required double boxWidth,
    required double boxHeight,
    required double characterSpacing,
    required double lineHeight,
  }) {
    if (max < min) return startSize;
    List<String> paragraphs = splitParagraphs(value);
    ({double width, double height}) constraints(double size) {
      double totalWidth = 0;
      double totalHeight = 0;
      List<WrapLine> lines = measure.wrap(
        value,
        size,
        characterSpacing,
        mm2pt(boxWidth),
      );
      for (int i = 0; i < lines.length; i++) {
        if (fit == 'vertical') {
          double w = pt2mm(
            measure.width(lines[i].text, size, characterSpacing),
          );
          if (w > totalWidth) totalWidth = w;
        }
        totalHeight += pt2mm(
          measure.lineBoxHeight(size, firstLine: i == 0) * lineHeight,
        );
      }
      if (fit == 'horizontal') {
        for (String p in paragraphs) {
          double w = pt2mm(measure.width(p, size, characterSpacing));
          if (w > totalWidth) totalWidth = w;
        }
      }
      return (width: totalWidth, height: totalHeight);
    }

    double size = startSize;
    if (size < min) {
      size = min;
    } else if (size > max) {
      size = max;
    }
    ({double width, double height}) c = constraints(size);
    bool grow() =>
        size < max &&
        (fit == 'horizontal' ? c.width < boxWidth : c.height < boxHeight);
    while (grow()) {
      size += step;
      ({double width, double height}) next = constraints(size);
      if (next.height < boxHeight) {
        c = next;
      } else {
        size -= step;
        break;
      }
    }
    while (size > min &&
        size > 0 &&
        (c.width > boxWidth || c.height > boxHeight)) {
      size -= step;
      c = constraints(size);
    }
    return size;
  }
}
