import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:xml/xml.dart';

import 'svg_aspect.dart';
import 'svg_matrix.dart';
import 'svg_parser.dart';
import 'svg_values.dart';

/// Draws an SVG string on a PDF page, like `drawSvg` of pdfme's pdf-lib
/// fork (`api/svg.ts`), quirks included.
///
/// Each element is drawn as `q`, the clip of every `<svg>` around it, `cm`
/// with its matrix, the dox_pdf_lib draw call, and `Q`.
class SvgRenderer {
  const SvgRenderer();

  static final Expando<PDFFont> _helvetica = Expando<PDFFont>();

  /// Draws [svg] into the box [width] x [height] whose top left corner is
  /// [x], [y] (PDF points, y from the bottom; [y] is the TOP edge, like
  /// pdfme). [fonts] are the fonts `<text>` may use, by name. [mapColor]
  /// changes each parsed color, eg. to CMYK.
  Future<void> draw(
    PDFPage page,
    String svg, {
    required double x,
    required double y,
    required double width,
    required double height,
    Map<String, PDFFont>? fonts,
    SvgColorMapper? mapColor,
  }) async {
    if (svg.isEmpty) return;
    XmlElement root = XmlDocument.parse(svg).rootElement;
    Map<String, String> attributes = SvgParser.attributesOf(root);
    _sizeRoot(attributes, width, height);
    ({double width, double height}) size = page.getSize();
    SvgStyle style = SvgStyle(
      width: size.width,
      height: size.height,
      viewBox: SvgBox.parse(attributes['viewBox'] ?? '0 0 1 1'),
    );
    List<SvgShape> shapes = SvgParser(mapColor: mapColor).parseNode(
      root,
      attributes,
      style,
      SvgMatrix(1, 0, 0, 1, x, y),
      <SvgClipSpace>[],
    );
    _SvgPainter painter = _SvgPainter(page, fonts ?? <String, PDFFont>{});
    for (SvgShape shape in shapes) {
      await painter.paint(shape);
    }
  }

  /// pdfme's `drawSvg` set-up: a view box from the written size when there
  /// is none, then the box size as the root size.
  static void _sizeRoot(
    Map<String, String> attributes,
    double width,
    double height,
  ) {
    Map<String, String> css = SvgParser.parseStyle(attributes['style']);
    String widthRaw = _nonEmpty(css['width']) ?? attributes['width'] ?? '';
    String heightRaw = _nonEmpty(css['height']) ?? attributes['height'] ?? '';
    if (_nonEmpty(attributes['viewBox']) == null) {
      attributes['viewBox'] =
          '0 0 ${_or(widthRaw, width)} ${_or(heightRaw, height)}';
    }
    if (width == 0 && height == 0) return;
    css
      ..['width'] = '${_js(width)}px'
      ..['height'] = '${_js(height)}px';
    attributes['style'] = <String>[
      for (MapEntry<String, String> e in css.entries) '${e.key}:${e.value};',
    ].join();
    if (width != 0) attributes['width'] = _js(width);
    if (height != 0) attributes['height'] = _js(height);
  }

  static String? _nonEmpty(String? v) => v == null || v.isEmpty ? null : v;

  static String _or(String raw, double value) => raw.isEmpty ? _js(value) : raw;

  /// A number as JS writes it in a string (`24`, not `24.0`).
  static String _js(double v) =>
      v == v.truncateToDouble() && v.isFinite ? '${v.toInt()}' : '$v';

  /// Helvetica, one per document: pdf-lib's default page font.
  static PDFFont helveticaOf(PDFDocument doc) =>
      _helvetica[doc] ??= doc.embedStandardFont(StandardFonts.helvetica);
}

/// Draws [SvgShape]s, like pdfme's `runnersToPage`.
class _SvgPainter {
  _SvgPainter(this.page, this.fonts);

  final PDFPage page;
  final Map<String, PDFFont> fonts;

  static final RegExp _png = RegExp(
    r'\.png(\?|$)|^data:image/png;base64',
    caseSensitive: false,
    multiLine: true,
  );

  Future<void> paint(SvgShape s) async {
    switch (s.tag) {
      case 'path':
        _path(s);
      case 'rect':
        _rect(s);
      case 'circle' || 'ellipse':
        _ellipse(s);
      case 'line':
        _line(s);
      case 'text':
        _text(s);
      case 'image':
        await _image(s);
    }
  }

  /// `q`, the clips, `cm`; then [draw]; then `Q`.
  void _wrap(SvgShape s, SvgMatrix matrix, void Function() draw) {
    page.pushOperators(<PDFOperator>[
      pushGraphicsState(),
      for (SvgClipSpace space in s.clipSpaces) ..._clip(space),
      concatTransformationMatrix(
        matrix.a,
        matrix.b,
        matrix.c,
        matrix.d,
        matrix.e,
        matrix.f,
      ),
    ]);
    draw();
    page.pushOperators(<PDFOperator>[popGraphicsState()]);
  }

  static List<PDFOperator> _clip(SvgClipSpace space) => <PDFOperator>[
    moveTo(space[0].x, space[0].y),
    lineTo(space[1].x, space[1].y),
    lineTo(space[2].x, space[2].y),
    lineTo(space[3].x, space[3].y),
    closePath(),
    clip(),
    endPath(),
  ];

  /// pdfme paints nothing (`h`) when there is no fill and no stroke.
  static bool _unpainted(SvgShape s) =>
      s.style.fill == null && s.style.stroke == null;

  void _path(SvgShape s) {
    String? d = s.d;
    if (d == null || _unpainted(s)) return;
    // dox_pdf_lib flips the path itself, so undo pdfme's flip.
    SvgMatrix m = s.matrix.then('scale', <double>[1, -1]);
    // ponytail: fill-rule evenodd fills as nonzero (no f* in dox_pdf_lib).
    _wrap(
      s,
      m,
      () => page.drawSvgPath(
        d,
        x: 0,
        y: 0,
        borderColor: s.style.stroke,
        borderWidth: s.style.strokeWidth,
        borderOpacity: s.style.strokeOpacity,
        borderLineCap: s.style.lineCap,
        borderDashArray: s.dash.array,
        borderDashPhase: s.dash.offset,
        color: s.style.fill,
        opacity: s.style.fillOpacity,
      ),
    );
  }

  /// `rx` and `ry` are not used: square corners, like pdfme.
  void _rect(SvgShape s) {
    if (_unpainted(s)) return;
    _wrap(
      s,
      s.matrix,
      () => page.drawRectangle(
        x: 0,
        y: 0,
        width: s.width,
        height: -s.height,
        borderColor: s.style.stroke,
        borderWidth: s.style.strokeWidth,
        borderOpacity: s.style.strokeOpacity,
        borderLineCap: s.style.lineCap,
        borderDashArray: s.dash.array,
        borderDashPhase: s.dash.offset,
        color: s.style.fill,
        opacity: s.style.fillOpacity,
      ),
    );
  }

  /// No radius gives pdf-lib's default 100, like pdfme.
  void _ellipse(SvgShape s) {
    if (_unpainted(s)) return;
    _wrap(
      s,
      s.matrix,
      () => page.drawEllipse(
        x: s.cx ?? 0,
        y: -(s.cy ?? 0),
        xScale: s.rx,
        yScale: s.ry,
        borderColor: s.style.stroke,
        borderWidth: s.style.strokeWidth,
        borderOpacity: s.style.strokeOpacity,
        borderLineCap: s.style.lineCap,
        borderDashArray: s.dash.array,
        borderDashPhase: s.dash.offset,
        color: s.style.fill,
        opacity: s.style.fillOpacity,
      ),
    );
  }

  /// With no stroke, the PDF default (black) strokes it, like pdfme.
  void _line(SvgShape s) {
    double y1 = s.y1 ?? 0;
    double y2 = s.y2 ?? 0;
    _wrap(
      s,
      s.matrix,
      () => page.drawLine(
        start: (x: s.x1 ?? 0, y: y1 == 0 ? 0 : -y1),
        end: (x: s.x2 ?? 0, y: y2 == 0 ? 0 : -y2),
        thickness: s.style.strokeWidth,
        color: s.style.stroke,
        opacity: s.style.strokeOpacity,
        lineCap: s.style.lineCap,
        dashArray: s.dash.array,
        dashPhase: s.dash.offset,
      ),
    );
  }

  /// One line of text. The font size is not scaled, only the matrix is.
  void _text(SvgShape s) {
    double size = s.style.fontSize == null || s.style.fontSize == 0
        ? 12
        : s.style.fontSize!;
    PDFFont font =
        bestFont(s.style, fonts) ?? SvgRenderer.helveticaOf(page.doc);
    double width = font.widthOfTextAtSize(s.text, size);
    double height = font.heightAtSize(size);
    double offsetX = switch (s.textAnchor) {
      'middle' => width / 2,
      'end' => width,
      _ => 0,
    };
    double offsetY = switch (s.dominantBaseline) {
      'text-before-edge' => height,
      'text-after-edge' => -height,
      'middle' => height / 2,
      _ => 0,
    };
    _wrap(
      s,
      s.matrix,
      () => page.drawText(
        s.text,
        x: -offsetX,
        y: -offsetY,
        font: font,
        size: size,
        color: s.style.fill,
        opacity: s.style.fillOpacity,
      ),
    );
  }

  /// A `data:` URL (or base64) PNG or JPEG.
  Future<void> _image(SvgShape s) async {
    String? src = s.src;
    if (src == null) return;
    PDFImage img = _png.hasMatch(src)
        ? await page.doc.embedPng(src)
        : await page.doc.embedJpg(src);
    SvgRect r = SvgAspectRatio.fit(
      img.width.toDouble(),
      img.height.toDouble(),
      s.width == 0 ? img.width.toDouble() : s.width,
      s.height == 0 ? img.height.toDouble() : s.height,
      s.preserveAspectRatio,
    );
    _wrap(
      s,
      s.matrix,
      () => page.drawImage(
        img,
        x: r.x,
        y: -r.y - r.height,
        width: r.width,
        height: r.height,
        opacity: s.style.fillOpacity,
      ),
    );
  }

  /// pdfme's `getBestFont`: `family_bold_italic`, `family_bold`,
  /// `family_italic`, `family`, then the first font whose name starts with
  /// the family. Null: the default font.
  static PDFFont? bestFont(SvgStyle style, Map<String, PDFFont> fonts) {
    String? family = style.fontFamily;
    if (family == null) return null;
    String? weight = style.fontWeight;
    bool bold = weight == 'bold' || (num.tryParse(weight ?? '') ?? 0) >= 700;
    bool italic = style.fontStyle == 'italic';
    for (String name in <String>[
      '$family${bold ? '_bold' : ''}${italic ? '_italic' : ''}',
      '$family${bold ? '_bold' : ''}',
      '$family${italic ? '_italic' : ''}',
      family,
    ]) {
      PDFFont? f = fonts[name];
      if (f != null) return f;
    }
    for (MapEntry<String, PDFFont> e in fonts.entries) {
      if (e.key.startsWith(family)) return e.value;
    }
    return null;
  }
}
