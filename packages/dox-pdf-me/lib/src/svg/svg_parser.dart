import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:xml/xml.dart';

import 'svg_aspect.dart';
import 'svg_color.dart';
import 'svg_matrix.dart';
import 'svg_values.dart';

/// Changes a parsed SVG color before it is used, eg. RGB to CMYK.
typedef SvgColorMapper = Color Function(RGB color);

/// A clip area: four corners in PDF space.
typedef SvgClipSpace = List<({double x, double y})>;

/// The attributes an element passes down to its children, like pdfme's
/// `InheritedAttributes`.
class SvgStyle {
  const SvgStyle({
    required this.width,
    required this.height,
    required this.viewBox,
    this.fill,
    this.fillOpacity,
    this.stroke,
    this.strokeWidth,
    this.strokeOpacity,
    this.lineCap,
    this.dashArray,
    this.dashOffset,
    this.fontFamily,
    this.fontStyle,
    this.fontWeight,
    this.fontSize,
  });

  /// The size of the nearest element with a size (for percent values).
  final double width;
  final double height;

  /// The view box of the nearest `<svg>`.
  final SvgBox viewBox;

  final Color? fill;
  final double? fillOpacity;
  final Color? stroke;
  final double? strokeWidth;
  final double? strokeOpacity;

  /// Null for `butt`, like pdfme (its butt value is 0, so it is "unset").
  final LineCapStyle? lineCap;
  final List<DashLength>? dashArray;
  final DashLength? dashOffset;
  final String? fontFamily;
  final String? fontStyle;
  final String? fontWeight;
  final double? fontSize;

  SvgStyle withViewBox(SvgBox box) => SvgStyle(
    width: width,
    height: height,
    viewBox: box,
    fill: fill,
    fillOpacity: fillOpacity,
    stroke: stroke,
    strokeWidth: strokeWidth,
    strokeOpacity: strokeOpacity,
    lineCap: lineCap,
    dashArray: dashArray,
    dashOffset: dashOffset,
    fontFamily: fontFamily,
    fontStyle: fontStyle,
    fontWeight: fontWeight,
    fontSize: fontSize,
  );
}

/// One element to draw, with everything resolved.
class SvgShape {
  SvgShape({
    required this.tag,
    required this.style,
    required this.matrix,
    required this.clipSpaces,
    required this.width,
    required this.height,
    required this.dash,
  });

  final String tag;
  final SvgStyle style;

  /// The matrix of the element in PDF space. For an element with a `d`
  /// attribute it ends with `scale(1, -1)`, like pdfme.
  final SvgMatrix matrix;
  final List<SvgClipSpace> clipSpaces;

  /// The size of a `rect` or `image`.
  final double width;
  final double height;
  final DashPattern dash;

  double? cx;
  double? cy;
  double? rx;
  double? ry;
  double? x1;
  double? y1;
  double? x2;
  double? y2;
  String? d;
  String? src;
  String? textAnchor;
  String? dominantBaseline;
  String? preserveAspectRatio;
  String text = '';
}

/// A paint color and its alpha (null when opaque).
typedef _Paint = ({Color color, double? alpha});

/// What `parseAttributes` of pdfme gives for one element.
typedef _Parsed = ({SvgStyle style, SvgMatrix matrix, double? width});

/// Reads an SVG into a flat list of [SvgShape]s, like the parse step of
/// pdfme's SVG engine (`parseHTMLNode` and friends).
class SvgParser {
  SvgParser({this.mapColor});

  final SvgColorMapper? mapColor;

  static const List<String> _transformAttributes = <String>[
    'translate',
    'translateX',
    'translateY',
    'skewX',
    'skewY',
    'rotate',
    'scale',
    'scaleX',
    'scaleY',
    'matrix',
  ];

  static final RegExp _cssDeclaration = RegExp(r'([^:\s]+)\s*:\s*([^;]+)');

  static final Map<String, LineCapStyle> _lineCaps = <String, LineCapStyle>{
    'round': LineCapStyle.round,
    'square': LineCapStyle.projecting,
  };

  /// The attributes of [element] by their written name (eg. `xlink:href`).
  static Map<String, String> attributesOf(XmlElement element) =>
      <String, String>{
        for (XmlAttribute a in element.attributes) a.name.qualified: a.value,
      };

  /// pdfme's `parseStyles`: the declarations of a `style` attribute.
  static Map<String, String> parseStyle(String? style) => <String, String>{
    if (style != null)
      for (RegExpMatch m in _cssDeclaration.allMatches(style)) m[1]!: m[2]!,
  };

  /// The shapes of [element] and its children.
  List<SvgShape> parseNode(
    XmlElement element,
    Map<String, String> attributes,
    SvgStyle inherited,
    SvgMatrix matrix,
    List<SvgClipSpace> clipSpaces,
  ) => switch (element.name.local) {
    'g' => _group(element, attributes, inherited, matrix, clipSpaces),
    'svg' => _svg(element, attributes, inherited, matrix, clipSpaces),
    _ => _leaf(element, attributes, inherited, matrix, clipSpaces),
  };

  List<SvgShape> _children(
    XmlElement element,
    SvgStyle inherited,
    SvgMatrix matrix,
    List<SvgClipSpace> clipSpaces,
  ) => <SvgShape>[
    for (XmlElement child in element.childElements)
      ...parseNode(child, attributesOf(child), inherited, matrix, clipSpaces),
  ];

  List<SvgShape> _group(
    XmlElement element,
    Map<String, String> attributes,
    SvgStyle inherited,
    SvgMatrix matrix,
    List<SvgClipSpace> clipSpaces,
  ) {
    _Parsed p = _parse('g', attributes, inherited, matrix);
    return _children(element, p.style, p.matrix, clipSpaces);
  }

  /// pdfme's `parseSvgNode`: a new viewport with its own view box and clip.
  /// The `transform` of an `<svg>` is not used, like pdfme.
  List<SvgShape> _svg(
    XmlElement element,
    Map<String, String> attributes,
    SvgStyle inherited,
    SvgMatrix matrix,
    List<SvgClipSpace> clipSpaces,
  ) {
    // no size: the size of the drawing space
    if (_get(attributes, 'width') == null) {
      attributes['width'] = '${inherited.viewBox.width}';
    }
    if (_get(attributes, 'height') == null) {
      attributes['height'] = '${inherited.viewBox.height}';
    }
    _Parsed p = _parse('svg', attributes, inherited, matrix);
    String? viewBoxRaw = _get(attributes, 'viewBox');
    SvgBox viewBox = SvgBox.parse(
      viewBoxRaw ?? '0 0 ${attributes['width']} ${attributes['height']}',
    );
    double x = _orZero(jsParseFloat(attributes['x'] ?? ''));
    double y = _orZero(jsParseFloat(attributes['y'] ?? ''));
    ({SvgMatrix clipBox, SvgMatrix content}) aspect = SvgAspectRatio.transform(
      matrix.then('translate', <double>[x, y]),
      viewBox.width,
      viewBox.height,
      jsParseFloat(attributes['width']!),
      jsParseFloat(attributes['height']!),
      _get(attributes, 'preserveAspectRatio') ?? 'xMidYMid',
    );
    SvgMatrix box = aspect.clipBox;
    SvgClipSpace clip = <({double x, double y})>[
      box.apply(0, 0),
      box.apply(viewBox.width, 0),
      box.apply(viewBox.width, -viewBox.height),
      box.apply(0, -viewBox.height),
    ];
    return _children(
      element,
      p.style.withViewBox(viewBox),
      aspect.content.then('translate', <double>[-viewBox.x, -viewBox.y]),
      <SvgClipSpace>[...clipSpaces, clip],
    );
  }

  List<SvgShape> _leaf(
    XmlElement element,
    Map<String, String> attributes,
    SvgStyle inherited,
    SvgMatrix matrix,
    List<SvgClipSpace> clipSpaces,
  ) {
    String tag = element.name.local;
    if (tag == 'polygon') {
      String? points = attributes.remove('points');
      // ponytail: pdfme draws "MundefinedZ" here; we draw nothing.
      if (points == null) return <SvgShape>[];
      tag = 'path';
      attributes['d'] = 'M${points}Z';
    }
    _Parsed p = _parse(tag, attributes, inherited, matrix);
    SvgStyle s = p.style;
    bool sized = _has(attributes, 'width') || _has(attributes, 'height');
    double? height = parseFloatValue(
      _styleOr(attributes, 'height'),
      inherited.height,
    );
    SvgShape shape = SvgShape(
      tag: tag,
      style: s,
      matrix: p.matrix,
      clipSpaces: clipSpaces,
      // pdfme: `width ?? inherited` with a size attribute, else the
      // inherited `width || parent width`
      width: sized ? (p.width ?? inherited.width) : s.width,
      height: sized ? (height ?? inherited.height) : s.height,
      dash: SvgDash.resolve(s.dashArray, s.dashOffset, s.viewBox),
    );
    _readGeometry(shape, attributes, inherited);
    shape
      ..d = _get(attributes, 'd')
      ..src = _get(attributes, 'src') ?? _get(attributes, 'xlink:href')
      ..textAnchor = attributes['text-anchor']
      ..dominantBaseline = attributes['dominant-baseline']
      ..preserveAspectRatio = attributes['preserveAspectRatio']
      ..text = element.innerText.trim().replaceAll(RegExp(r'\s'), ' ');
    return <SvgShape>[shape];
  }

  /// cx, cy, r, rx, ry, x1, y1, x2, y2. Each pair is set only when one of
  /// its attributes is there, like pdfme.
  void _readGeometry(
    SvgShape shape,
    Map<String, String> a,
    SvgStyle inherited,
  ) {
    double? num(String? v, double ref) => parseFloatValue(v, ref);
    double w = inherited.width;
    double h = inherited.height;
    if (_has(a, 'cx') || _has(a, 'cy')) {
      shape
        ..cx = num(a['cx'], w)
        ..cy = num(a['cy'], h);
    }
    if (_has(a, 'rx') || _has(a, 'ry') || _has(a, 'r')) {
      shape
        ..rx = num(_get(a, 'rx') ?? a['r'], w)
        ..ry = num(_get(a, 'ry') ?? a['r'], h);
    }
    if (_has(a, 'x1') || _has(a, 'y1')) {
      shape
        ..x1 = num(a['x1'], w)
        ..y1 = num(a['y1'], h);
    }
    if (_has(a, 'x2') || _has(a, 'y2')) {
      shape
        ..x2 = num(a['x2'], w)
        ..y2 = num(a['y2'], h);
    }
  }

  /// pdfme's `parseAttributes`: the style for the children and the matrix
  /// of the element.
  _Parsed _parse(
    String tag,
    Map<String, String> attributes,
    SvgStyle inherited,
    SvgMatrix matrix,
  ) {
    Map<String, String> css = parseStyle(attributes['style']);
    String? read(String name) => _get(css, name) ?? _get(attributes, name);

    double? width = parseFloatValue(read('width'), inherited.width);
    double? height = parseFloatValue(read('height'), inherited.height);
    double? x = parseFloatValue(attributes['x'], inherited.width);
    double? y = parseFloatValue(attributes['y'], inherited.height);

    _Paint? fill = _color(read('fill'), inherited.fill, inherited.fillOpacity);
    _Paint? stroke = _color(
      read('stroke'),
      inherited.stroke,
      inherited.strokeOpacity,
    );
    String? opacity = read('opacity');
    String? fontFamily = read('font-family') ?? inherited.fontFamily;

    SvgStyle style = SvgStyle(
      width: _truthy(width) ? width! : inherited.width,
      height: _truthy(height) ? height! : inherited.height,
      viewBox: tag == 'svg' && _has(attributes, 'viewBox')
          ? SvgBox.parse(attributes['viewBox']!)
          : inherited.viewBox,
      fill: fill?.color ?? inherited.fill,
      fillOpacity:
          _opacity(read('fill-opacity') ?? opacity, fill?.alpha) ??
          inherited.fillOpacity,
      stroke: stroke?.color ?? inherited.stroke,
      strokeWidth:
          parseFloatValue(read('stroke-width')) ?? inherited.strokeWidth,
      strokeOpacity:
          _opacity(read('stroke-opacity') ?? opacity, stroke?.alpha) ??
          inherited.strokeOpacity,
      lineCap: _lineCaps[read('stroke-linecap')] ?? inherited.lineCap,
      dashArray:
          SvgDash.parseArray(read('stroke-dasharray')) ?? inherited.dashArray,
      dashOffset:
          SvgDash.parseOffset(read('stroke-dashoffset')) ??
          inherited.dashOffset,
      fontFamily: fontFamily == null ? null : firstFontFamily(fontFamily),
      fontStyle: read('font-style') ?? inherited.fontStyle,
      fontWeight: read('font-weight') ?? inherited.fontWeight,
      fontSize: parseFloatValue(read('font-size')) ?? inherited.fontSize,
    );

    // transforms written as attributes go first, then `transform`
    String list = attributes['transform'] ?? '';
    for (String name in _transformAttributes) {
      String? v = _get(attributes, name);
      if (v != null) list = '$v $list';
    }
    SvgMatrix m = matrix.thenList(list);
    // x and y work like a translate
    if (_truthy(x) || _truthy(y)) {
      m = m.then('translate', <double>[
        _truthy(x) ? x! : 0,
        _truthy(y) ? y! : 0,
      ]);
    }
    // a path's y axis points down
    if (_has(attributes, 'd')) m = m.then('scale', <double>[1, -1]);
    return (style: style, matrix: m, width: width);
  }

  /// pdfme's `parseColor`. Null for no value, `none` and `transparent`.
  _Paint? _color(String? value, Color? inherited, double? opacity) {
    if (value == null || value == 'none' || value == 'transparent') {
      return null;
    }
    if (value == 'currentColor') {
      // pdfme: the inherited paint of the same kind, else black
      if (inherited != null) return (color: inherited, alpha: opacity);
      return _color('#000000', null, null);
    }
    CssColorValue parsed = CssColor.parse(value);
    SvgColorMapper? map = mapColor;
    return (
      color: map == null ? parsed.rgb : map(parsed.rgb),
      alpha: parsed.alpha,
    );
  }

  /// An opacity attribute wins over the alpha of the color.
  static double? _opacity(String? raw, double? alpha) =>
      raw != null ? parseFloatValue(raw) : alpha;

  /// pdfme's `normalizeFontFamily`: the first family of a list like
  /// `"Linux Libertine O", serif`.
  static String firstFontFamily(String fontFamily) =>
      fontFamilies(fontFamily).firstOrNull ?? fontFamily.trim();

  /// pdfme's `splitFontFamilies`: the families of a `font-family` list,
  /// without quotes and `!important`.
  static List<String> fontFamilies(String fontFamily) {
    List<String> families = <String>[];
    StringBuffer current = StringBuffer();
    String? quote;
    void push() {
      String v = _stripImportant(current.toString().trim());
      if (v.isNotEmpty) families.add(v);
      current.clear();
    }

    for (String char in fontFamily.split('')) {
      if ((char == '"' || char == "'") && (quote == null || quote == char)) {
        quote = quote == null ? char : null;
      } else if (char == ',' && quote == null) {
        push();
      } else {
        current.write(char);
      }
    }
    push();
    return families;
  }

  static String _stripImportant(String value) {
    String t = value.trim();
    return t.toLowerCase().endsWith('!important')
        ? t.substring(0, t.length - '!important'.length).trimRight()
        : t;
  }

  String? _styleOr(Map<String, String> attributes, String name) =>
      _get(parseStyle(attributes['style']), name) ?? _get(attributes, name);

  /// A JS truthy attribute: there and not empty.
  static String? _get(Map<String, String> map, String key) {
    String? v = map[key];
    return v == null || v.isEmpty ? null : v;
  }

  static bool _has(Map<String, String> map, String key) =>
      _get(map, key) != null;

  static bool _truthy(double? v) => v != null && v != 0 && !v.isNaN;

  static double _orZero(double v) => v.isNaN ? 0 : v;
}
