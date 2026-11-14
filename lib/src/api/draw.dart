part of 'document.dart';

/// Blend modes of pdf-lib's `BlendMode`. The order is the one of
/// native/src/draw.rs.
enum BlendMode {
  normal,
  multiply,
  screen,
  overlay,
  darken,
  lighten,
  colorDodge,
  colorBurn,
  hardLight,
  softLight,
  difference,
  exclusion,
}

/// A point, as `start` and `end` of [PDFPageDrawing.drawLine].
typedef PDFPoint = ({double x, double y});

/// Text state of a page, like the private fields of pdf-lib's `PDFPage`.
class _TextState {
  PDFFont? font;
  double fontSize = 24;
  Color fontColor = const RGB(0, 0, 0);
  double lineHeight = 24;
  double x = 0;
  double y = 0;
}

final Expando<_TextState> _textStates = Expando<_TextState>();
final Expando<PDFFont> _defaultFonts = Expando<PDFFont>();
final Expando<List<String>> _wordBreaks = Expando<List<String>>();

/// pdf-lib's `PDFDocument.defaultWordBreaks`.
extension PDFDocumentWordBreaks on PDFDocument {
  /// Where `drawText` with `maxWidth` may break a line. Default: `[' ']`.
  List<String> get defaultWordBreaks =>
      _wordBreaks[this] ?? const <String>[' '];

  set defaultWordBreaks(List<String> breaks) => _wordBreaks[this] = breaks;
}

const int _noBlend = -1;

void _checkOpacity(double? value, String name) {
  if (value != null && !(value >= 0 && value <= 1)) {
    throw RangeError(
      '`$name` must be at least 0 and at most 1, but was actually $value',
    );
  }
}

/// `[type, parts...]` of a color: type 0 is "no color".
List<double> _color(Color? c) => switch (c) {
  null => const <double>[0, 0, 0, 0, 0],
  Grayscale g => <double>[1, g.gray, 0, 0, 0],
  RGB r => <double>[2, r.red, r.green, r.blue, 0],
  CMYK k => <double>[3, k.cyan, k.magenta, k.yellow, k.key],
};

double _radians(Rotation? r) => r == null ? 0 : toRadians(r);

/// Drawing, like pdf-lib's `PDFPage` draw methods. Names, options and
/// defaults are pdf-lib's.
extension PDFPageDrawing on PDFPage {
  _TextState get _state => _textStates[this] ??= _TextState();

  void _draw(int kind, List<double> nums, [Uint8List? bytes]) {
    Float64List input = Float64List.fromList(nums);
    Uint8List data = bytes ?? Uint8List(0);
    check(
      doxPdfDraw(
        doc._handle,
        ref,
        kind,
        input.address,
        input.length,
        data.address,
        data.length,
      ),
    );
  }

  /// The numbers every draw call starts with.
  List<double> _head({
    double? opacity,
    double? borderOpacity,
    BlendMode? blendMode,
    Color? color,
    Color? borderColor,
  }) {
    _checkOpacity(opacity, 'opacity');
    _checkOpacity(borderOpacity, 'borderOpacity');
    return <double>[
      opacity ?? double.nan,
      borderOpacity ?? double.nan,
      (blendMode?.index ?? _noBlend).toDouble(),
      ..._color(color),
      ..._color(borderColor),
    ];
  }

  void _change(int kind, double x, double y) =>
      check(doxPdfPageChange(doc._handle, ref, kind, x, y));

  /// Moves all content drawn so far by [x], [y].
  void translateContent(double x, double y) =>
      _change(changeTranslateContent, x, y);

  /// Scales the page size, its content and its annotations.
  void scale(double x, double y) => _change(changeScale, x, y);

  /// Scales the content drawn so far.
  void scaleContent(double x, double y) => _change(changeScaleContent, x, y);

  /// Scales the positions of the annotations of the page.
  void scaleAnnotations(double x, double y) =>
      _change(changeScaleAnnotations, x, y);

  /// Moves the position back to 0, 0. New drawing goes into a new content
  /// stream, like pdf-lib.
  void resetPosition() {
    _change(changeResetPosition, 0, 0);
    _state
      ..x = 0
      ..y = 0;
  }

  void setFont(PDFFont font) => _state.font = font;

  void setFontSize(double fontSize) => _state.fontSize = fontSize;

  void setFontColor(Color fontColor) => _state.fontColor = fontColor;

  void setLineHeight(double lineHeight) => _state.lineHeight = lineHeight;

  ({double x, double y}) getPosition() => (x: _state.x, y: _state.y);

  double getX() => _state.x;

  double getY() => _state.y;

  void moveTo(double x, double y) => _state
    ..x = x
    ..y = y;

  void moveDown(double yDecrease) => _state.y -= yDecrease;

  void moveUp(double yIncrease) => _state.y += yIncrease;

  void moveLeft(double xDecrease) => _state.x -= xDecrease;

  void moveRight(double xIncrease) => _state.x += xIncrease;

  /// Adds raw operators to the content stream of the page.
  void pushOperators(List<PDFOperator> operators) {
    StringBuffer out = StringBuffer();
    for (PDFOperator op in operators) {
      out
        ..write(op)
        ..write('\n');
    }
    _draw(kindOperators, const <double>[], latin1.encode(out.toString()));
  }

  /// The page font, or Helvetica (one per document) when none is set.
  PDFFont _font() {
    _TextState s = _state;
    return s.font ??= _defaultFonts[doc] ??= doc.embedStandardFont(
      StandardFonts.helvetica,
    );
  }

  /// Draws [text]. A newline starts a new line. With [maxWidth], long lines
  /// break at [wordBreaks] (default: the document's `defaultWordBreaks`).
  void drawText(
    String text, {
    Color? color,
    double? opacity,
    BlendMode? blendMode,
    PDFFont? font,
    double? size,
    Rotation? rotate,
    Rotation? xSkew,
    Rotation? ySkew,
    double? x,
    double? y,
    double? lineHeight,
    double? maxWidth,
    List<String>? wordBreaks,
  }) {
    _TextState s = _state;
    PDFFont f = font ?? _font();
    // pdf-lib: `options.size || this.fontSize`
    double fontSize = (size == null || size == 0 || size.isNaN)
        ? s.fontSize
        : size;
    BytesBuilder bytes = BytesBuilder(copy: false);
    Uint8List textBytes = utf8.encode(text);
    bytes.add(textBytes);
    if (maxWidth != null) {
      for (String b in wordBreaks ?? doc.defaultWordBreaks) {
        if (b.length == 1 && '\n\f\r\u000B'.contains(b)) {
          throw ArgumentError(r'`wordBreak` must not include \n|\f|\r|\u000B');
        }
        bytes
          ..add(utf8.encode(b))
          ..addByte(0);
      }
    }
    _draw(kindText, <double>[
      ..._head(
        opacity: opacity,
        blendMode: blendMode,
        color: color ?? s.fontColor,
      ),
      f.ref.toDouble(),
      fontSize,
      _radians(rotate),
      _radians(xSkew),
      _radians(ySkew),
      x ?? s.x,
      y ?? s.y,
      lineHeight ?? s.lineHeight,
      maxWidth ?? double.nan,
      textBytes.length.toDouble(),
    ], bytes.takeBytes());
  }

  /// Draws [image]. The default size is the image size in pixels.
  void drawImage(
    PDFImage image, {
    double? x,
    double? y,
    double? width,
    double? height,
    Rotation? rotate,
    Rotation? xSkew,
    Rotation? ySkew,
    double? opacity,
    BlendMode? blendMode,
  }) {
    _draw(kindImage, <double>[
      ..._head(opacity: opacity, blendMode: blendMode),
      image.ref.toDouble(),
      x ?? _state.x,
      y ?? _state.y,
      width ?? image.width.toDouble(),
      height ?? image.height.toDouble(),
      _radians(rotate),
      _radians(xSkew),
      _radians(ySkew),
    ]);
  }

  /// Draws an SVG path (`d` attribute). Its y axis points down, as in SVG.
  /// With no [color] and no [borderColor], the border is black.
  void drawSvgPath(
    String path, {
    double? x,
    double? y,
    double? scale,
    Rotation? rotate,
    double? borderWidth,
    Color? color,
    double? opacity,
    Color? borderColor,
    double? borderOpacity,
    List<double>? borderDashArray,
    double? borderDashPhase,
    LineCapStyle? borderLineCap,
    BlendMode? blendMode,
  }) {
    if (color == null && borderColor == null) {
      borderColor = const RGB(0, 0, 0);
    }
    List<double> dashes = borderDashArray ?? const <double>[];
    _draw(kindSvg, <double>[
      ..._head(
        opacity: opacity,
        borderOpacity: borderOpacity,
        blendMode: blendMode,
        color: color,
        borderColor: borderColor,
      ),
      x ?? _state.x,
      y ?? _state.y,
      scale ?? double.nan,
      _radians(rotate),
      borderWidth ?? 0,
      (borderLineCap?.index ?? 0).toDouble(),
      borderDashPhase ?? 0,
      dashes.length.toDouble(),
      ...dashes,
    ], utf8.encode(path));
  }

  /// Draws a line from [start] to [end].
  void drawLine({
    required PDFPoint start,
    required PDFPoint end,
    double? thickness,
    Color? color = const RGB(0, 0, 0),
    double? opacity,
    LineCapStyle? lineCap,
    List<double>? dashArray,
    double? dashPhase,
    BlendMode? blendMode,
  }) {
    List<double> dashes = dashArray ?? const <double>[];
    _draw(kindLine, <double>[
      // pdf-lib: the line opacity is the stroke opacity (`CA`)
      ..._head(borderOpacity: opacity, blendMode: blendMode, color: color),
      start.x,
      start.y,
      end.x,
      end.y,
      thickness ?? 1,
      dashPhase ?? 0,
      (lineCap?.index ?? 0).toDouble(),
      dashes.length.toDouble(),
      ...dashes,
    ]);
  }

  /// Draws a rectangle (default 150 x 100). With no [color] and no
  /// [borderColor], it is filled black.
  void drawRectangle({
    double? x,
    double? y,
    double? width,
    double? height,
    Rotation? rotate,
    Rotation? xSkew,
    Rotation? ySkew,
    double? borderWidth,
    Color? color,
    double? opacity,
    Color? borderColor,
    double? borderOpacity,
    List<double>? borderDashArray,
    double? borderDashPhase,
    LineCapStyle? borderLineCap,
    BlendMode? blendMode,
  }) {
    if (color == null && borderColor == null) color = const RGB(0, 0, 0);
    List<double> dashes = borderDashArray ?? const <double>[];
    _draw(kindRectangle, <double>[
      ..._head(
        opacity: opacity,
        borderOpacity: borderOpacity,
        blendMode: blendMode,
        color: color,
        borderColor: borderColor,
      ),
      x ?? _state.x,
      y ?? _state.y,
      width ?? 150,
      height ?? 100,
      _radians(rotate),
      _radians(xSkew),
      _radians(ySkew),
      borderWidth ?? 0,
      (borderLineCap?.index ?? 0).toDouble(),
      borderDashPhase ?? 0,
      dashes.length.toDouble(),
      ...dashes,
    ]);
  }

  /// Draws a square of [size]. Like pdf-lib, no size gives 150 x 100.
  void drawSquare({
    double? x,
    double? y,
    double? size,
    Rotation? rotate,
    Rotation? xSkew,
    Rotation? ySkew,
    double? borderWidth,
    Color? color,
    double? opacity,
    Color? borderColor,
    double? borderOpacity,
    List<double>? borderDashArray,
    double? borderDashPhase,
    LineCapStyle? borderLineCap,
    BlendMode? blendMode,
  }) => drawRectangle(
    x: x,
    y: y,
    width: size,
    height: size,
    rotate: rotate,
    xSkew: xSkew,
    ySkew: ySkew,
    borderWidth: borderWidth,
    color: color,
    opacity: opacity,
    borderColor: borderColor,
    borderOpacity: borderOpacity,
    borderDashArray: borderDashArray,
    borderDashPhase: borderDashPhase,
    borderLineCap: borderLineCap,
    blendMode: blendMode,
  );

  /// Draws an ellipse around [x], [y] with radii [xScale] and [yScale]
  /// (default 100). With no [color] and no [borderColor], it is filled
  /// black.
  void drawEllipse({
    double? x,
    double? y,
    double? xScale,
    double? yScale,
    Rotation? rotate,
    Color? color,
    double? opacity,
    Color? borderColor,
    double? borderOpacity,
    double? borderWidth,
    List<double>? borderDashArray,
    double? borderDashPhase,
    LineCapStyle? borderLineCap,
    BlendMode? blendMode,
  }) {
    if (color == null && borderColor == null) color = const RGB(0, 0, 0);
    List<double> dashes = borderDashArray ?? const <double>[];
    _draw(kindEllipse, <double>[
      ..._head(
        opacity: opacity,
        borderOpacity: borderOpacity,
        blendMode: blendMode,
        color: color,
        borderColor: borderColor,
      ),
      x ?? _state.x,
      y ?? _state.y,
      xScale ?? 100,
      yScale ?? 100,
      // no rotate: pdf-lib's older path, without a transform
      rotate == null ? double.nan : toRadians(rotate),
      borderWidth ?? 0,
      (borderLineCap?.index ?? 0).toDouble(),
      borderDashPhase ?? 0,
      dashes.length.toDouble(),
      ...dashes,
    ]);
  }

  /// Draws a circle around [x], [y] with radius [size].
  void drawCircle({
    double? x,
    double? y,
    double size = 100,
    Color? color,
    double? opacity,
    Color? borderColor,
    double? borderOpacity,
    double? borderWidth,
    List<double>? borderDashArray,
    double? borderDashPhase,
    LineCapStyle? borderLineCap,
    BlendMode? blendMode,
  }) => drawEllipse(
    x: x,
    y: y,
    xScale: size,
    yScale: size,
    color: color,
    opacity: opacity,
    borderColor: borderColor,
    borderOpacity: borderOpacity,
    borderWidth: borderWidth,
    borderDashArray: borderDashArray,
    borderDashPhase: borderDashPhase,
    borderLineCap: borderLineCap,
    blendMode: blendMode,
  );
}
