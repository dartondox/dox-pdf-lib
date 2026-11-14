import 'dart:convert';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:xml/xml.dart';

import '../color.dart';
import '../layout.dart';
import '../plugin.dart';
import 'svg_parser.dart';
import 'svg_renderer.dart';

/// The `svg` schema type, like pdfme's svg plugin: draws the SVG of the
/// value into the box. `opacity` is not used, like pdfme.
class SvgPlugin extends SchemaPlugin {
  const SvgPlugin();

  @override
  String get type => 'svg';

  @override
  Future<void> pdf(RenderProps props) async {
    String value = props.value;
    if (!isValidSvg(value)) return;
    PDFPage page = props.page;
    PdfLayout box = PdfLayout.of(
      props.schema,
      page.getHeight(),
      applyRotateTranslate: false,
    );
    Map<String, PDFFont>? fonts = await _fonts(props, value);
    SvgColorMapper? mapColor = props.options.colorType?.toLowerCase() == 'cmyk'
        ? rgbToCmyk
        : null;
    double rotate = box.rotate;
    if (rotate != 0) {
      double cx = box.x + box.width / 2;
      double cy = box.y + box.height / 2;
      page.pushOperators(<PDFOperator>[
        pushGraphicsState(),
        translate(cx, cy),
        rotateDegrees(rotate),
        translate(-cx, -cy),
      ]);
    }
    try {
      await const SvgRenderer().draw(
        page,
        value,
        x: box.x,
        y: box.y + box.height,
        width: box.width,
        height: box.height,
        fonts: fonts,
        mapColor: mapColor,
      );
    } finally {
      if (rotate != 0) page.pushOperators(<PDFOperator>[popGraphicsState()]);
    }
  }

  /// pdfme's `isValidSVG` (the Node.js part): it has `<svg` and `</svg>`.
  static bool isValidSvg(String value) =>
      value.contains('<svg') && value.contains('</svg>');

  /// The embedded fonts the `<text>` elements ask for. Like pdfme, only
  /// when the options have fonts; else text uses Helvetica.
  static Future<Map<String, PDFFont>?> _fonts(
    RenderProps props,
    String value,
  ) async {
    if (props.options.font == null || props.options.font!.isEmpty) return null;
    Set<String> names = selectFontNames(value, props.fonts.sources.keys);
    if (names.isEmpty) return null;
    return <String, PDFFont>{
      for (String name in names) name: await props.fonts.embed(name),
    };
  }

  /// pdfme's `selectSvgFontNames`: for each `<text>`, the first family of
  /// its `font-family` list that matches a font (`family_bold_italic`,
  /// `family_bold`, `family_italic`, `family`, or a name that starts with
  /// the family).
  static Set<String> selectFontNames(String svg, Iterable<String> fontNames) {
    Set<String> out = <String>{};
    XmlElement root = XmlDocument.parse(svg).rootElement;
    _selectFonts(root, const _FontStyle(), fontNames.toList(), out);
    return out;
  }

  static void _selectFonts(
    XmlElement element,
    _FontStyle base,
    List<String> fontNames,
    Set<String> out,
  ) {
    _FontStyle style = base.merge(element);
    if (element.name.local.toLowerCase() == 'text') {
      for (String family in SvgParser.fontFamilies(style.family ?? '')) {
        String? name = style
            .candidates(family)
            .where(fontNames.contains)
            .firstOrNull;
        name ??= fontNames
            .where((String n) => n.startsWith(family))
            .firstOrNull;
        if (name != null) {
          out.add(name);
          break;
        }
      }
    }
    for (XmlElement child in element.childElements) {
      _selectFonts(child, style, fontNames, out);
    }
  }
}

/// The font attributes pdfme's font selection passes down.
class _FontStyle {
  const _FontStyle({this.family, this.style, this.weight});

  final String? family;
  final String? style;
  final String? weight;

  /// The style of [element]: its `style` attribute, then its attributes,
  /// then this style.
  _FontStyle merge(XmlElement element) {
    Map<String, String> css = <String, String>{};
    for (String declaration in (element.getAttribute('style') ?? '').split(
      ';',
    )) {
      List<String> parts = declaration.split(':');
      String value = parts.skip(1).join(':').trim();
      if (parts.first.isNotEmpty && value.isNotEmpty) {
        css[parts.first.trim()] = value;
      }
    }
    String? read(String name, String? fallback) {
      String? v = css[name] ?? element.getAttribute(name);
      return v == null || v.isEmpty ? fallback : v;
    }

    return _FontStyle(
      family: read('font-family', family),
      style: read('font-style', style),
      weight: read('font-weight', weight),
    );
  }

  /// The font names to try for [family], best first.
  List<String> candidates(String family) {
    bool bold = weight == 'bold' || (num.tryParse(weight ?? '') ?? 0) >= 700;
    bool italic = style == 'italic';
    return <String>{
      '$family${bold ? '_bold' : ''}${italic ? '_italic' : ''}',
      '$family${bold ? '_bold' : ''}',
      '$family${italic ? '_italic' : ''}',
      family,
    }.toList();
  }
}

/// A lucide icon in pdfme's `createSvgStr` form: 24 x 24, no fill, stroke
/// 2, round caps and joins. With no [stroke], the stroke is
/// `currentColor` (black), like pdfme's default.
String lucideIconSvg(String children, String? stroke) {
  String strokeAttribute =
      ' stroke="${const HtmlEscape(HtmlEscapeMode.attribute).convert(stroke ?? 'currentColor')}"';
  return '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
      'viewBox="0 0 24 24" fill="none"$strokeAttribute stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">$children</svg>';
}

/// The `checkbox` schema type, like pdfme: a lucide square, with a check
/// mark when the value is exactly `'true'`. It is always drawn.
class CheckboxPlugin extends SchemaPlugin {
  const CheckboxPlugin();

  static const String _square =
      '<rect width="18" height="18" x="3" y="3" rx="2"/>';
  static const String _check = '<path d="m16 9-5.5 5.5L8 12"/>';

  @override
  String get type => 'checkbox';

  /// The SVG for [checked] in [color] (the schema `color`).
  static String icon(bool checked, String? color) =>
      lucideIconSvg(checked ? '$_square$_check' : _square, color);

  @override
  Future<void> pdf(RenderProps props) => const SvgPlugin().pdf(
    props.copyWith(
      value: icon(props.value == 'true', props.schema.string('color')),
    ),
  );
}

/// The `radioGroup` schema type, like pdfme: a lucide circle, with a dot
/// when the value is exactly `'true'`. It is always drawn.
class RadioGroupPlugin extends SchemaPlugin {
  const RadioGroupPlugin();

  static const String _circle = '<circle cx="12" cy="12" r="10"/>';
  static const String _dot = '<circle cx="12" cy="12" r="1"/>';

  @override
  String get type => 'radioGroup';

  /// The SVG for [checked] in [color] (the schema `color`).
  static String icon(bool checked, String? color) =>
      lucideIconSvg(checked ? '$_dot$_circle' : _circle, color);

  @override
  Future<void> pdf(RenderProps props) => const SvgPlugin().pdf(
    props.copyWith(
      value: icon(props.value == 'true', props.schema.string('color')),
    ),
  );
}
