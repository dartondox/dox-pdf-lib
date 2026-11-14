part of 'schema.dart';

/// How a `dynamicFontSize` text fits its box.
enum DynamicFontSizeFit implements _JsonEnum {
  /// The text gets as big as fits the box width.
  horizontal,

  /// The text gets as big as fits the box height.
  vertical;

  @override
  String get json => name;
}

/// How the text of a text schema is read.
enum TextFormat implements _JsonEnum {
  plain('plain'),

  /// `**bold**`, `*italic*`, ... Not supported yet: drawn as plain text.
  inlineMarkdown('inline-markdown');

  const TextFormat(this.json);

  @override
  final String json;
}

/// What text does when it is longer than its box.
enum TextOverflow implements _JsonEnum {
  /// The text goes out of the box.
  visible,

  /// The box grows. Not supported yet: drawn like [visible].
  expand;

  @override
  String get json => name;
}

/// What happens when a font variant (bold, italic) is missing.
enum FontVariantFallback implements _JsonEnum {
  synthetic,
  plain,
  error;

  @override
  String get json => name;
}

/// The font size changes with the text, between [min] and [max], so the
/// text fits the box.
class DynamicFontSize {
  const DynamicFontSize({
    this.min = 4,
    this.max = 72,
    this.fit = DynamicFontSizeFit.vertical,
  });

  DynamicFontSize.fromJson(Map<String, Object?> json)
    : min = _num(json['min']) ?? 4,
      max = _num(json['max']) ?? 72,
      fit = _enum(
        DynamicFontSizeFit.values,
        json['fit'],
        DynamicFontSizeFit.vertical,
      );

  final double min;
  final double max;
  final DynamicFontSizeFit fit;

  Map<String, Object?> toJson() => <String, Object?>{
    'min': _out(min),
    'max': _out(max),
    'fit': fit.json,
  };
}

/// Font names for bold, italic, bold italic and code text (inline
/// markdown). Not supported yet: kept in the JSON only.
class FontVariants {
  const FontVariants({this.bold, this.italic, this.boldItalic, this.code});

  FontVariants.fromJson(Map<String, Object?> json)
    : bold = _str(json['bold']),
      italic = _str(json['italic']),
      boldItalic = _str(json['boldItalic']),
      code = _str(json['code']);

  final String? bold;
  final String? italic;
  final String? boldItalic;
  final String? code;

  Map<String, Object?> toJson() => <String, Object?>{
    if (bold != null) 'bold': bold,
    if (italic != null) 'italic': italic,
    if (boldItalic != null) 'boldItalic': boldItalic,
    if (code != null) 'code': code,
  };
}

/// The `text` schema type: text in a box.
///
/// Colors are hex strings like `#ff0000` (also `#f00` and with alpha,
/// `#ff000080`). An empty string means no color. A bad hex value makes
/// `generate` throw.
class TextSchema extends Schema {
  const TextSchema({
    required super.name,
    required super.position,
    super.width = 45,
    super.height = 10,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    this.fontName,
    this.textFormat = TextFormat.plain,
    this.fontVariants,
    this.fontVariantFallback = FontVariantFallback.synthetic,
    this.alignment = Alignment.left,
    this.verticalAlignment = VerticalAlignment.top,
    this.fontSize = 13,
    this.lineHeight = 1,
    this.characterSpacing = 0,
    this.strikethrough = false,
    this.underline = false,
    this.dynamicFontSize,
    this.overflow = TextOverflow.visible,
    this.fontColor = '#000000',
    this.backgroundColor = '',
    this.borderColor = '#000000',
    this.borderWidth = Sides.zero,
    this.padding = Sides.zero,
  });

  TextSchema.fromJson(super.json)
    : fontName = _str(json['fontName']),
      textFormat = _enum(
        TextFormat.values,
        json['textFormat'],
        TextFormat.plain,
      ),
      fontVariants = json['fontVariants'] is Map
          ? FontVariants.fromJson(_map(json['fontVariants']))
          : null,
      fontVariantFallback = _enum(
        FontVariantFallback.values,
        json['fontVariantFallback'],
        FontVariantFallback.synthetic,
      ),
      alignment = _enum(Alignment.values, json['alignment'], Alignment.left),
      verticalAlignment = _enum(
        VerticalAlignment.values,
        json['verticalAlignment'],
        VerticalAlignment.top,
      ),
      fontSize = _num(json['fontSize']) ?? 13,
      lineHeight = _num(json['lineHeight']) ?? 1,
      characterSpacing = _num(json['characterSpacing']) ?? 0,
      strikethrough = json['strikethrough'] == true,
      underline = json['underline'] == true,
      dynamicFontSize = json['dynamicFontSize'] is Map
          ? DynamicFontSize.fromJson(_map(json['dynamicFontSize']))
          : null,
      overflow = _enum(
        TextOverflow.values,
        json['overflow'],
        TextOverflow.visible,
      ),
      fontColor = _str(json['fontColor']) ?? '#000000',
      backgroundColor = _str(json['backgroundColor']) ?? '',
      borderColor = _str(json['borderColor']) ?? '#000000',
      borderWidth = Sides.fromJson(_map(json['borderWidth'])),
      padding = Sides.fromJson(_map(json['padding'])),
      super.fromJson();

  @override
  String get type => 'text';

  /// A font name of the `font` option. Null: the fallback font.
  final String? fontName;

  final TextFormat textFormat;

  final FontVariants? fontVariants;

  final FontVariantFallback fontVariantFallback;

  final Alignment alignment;

  final VerticalAlignment verticalAlignment;

  /// Points.
  final double fontSize;

  /// A factor of the font size.
  final double lineHeight;

  /// Points between letters.
  final double characterSpacing;

  final bool strikethrough;

  final bool underline;

  /// Null: the font size is [fontSize].
  final DynamicFontSize? dynamicFontSize;

  final TextOverflow overflow;

  /// A hex color.
  final String fontColor;

  /// A hex color, or `''` for none.
  final String backgroundColor;

  /// A hex color, or `''` for none.
  final String borderColor;

  /// mm on each side. Drawn inside the box.
  final Sides borderWidth;

  /// mm on each side.
  final Sides padding;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    if (fontName != null) 'fontName': fontName,
    'textFormat': textFormat.json,
    if (fontVariants != null) 'fontVariants': fontVariants!.toJson(),
    'fontVariantFallback': fontVariantFallback.json,
    'alignment': alignment.json,
    'verticalAlignment': verticalAlignment.json,
    'fontSize': _out(fontSize),
    'lineHeight': _out(lineHeight),
    'characterSpacing': _out(characterSpacing),
    'strikethrough': strikethrough,
    'underline': underline,
    if (dynamicFontSize != null) 'dynamicFontSize': dynamicFontSize!.toJson(),
    'overflow': overflow.json,
    'fontColor': fontColor,
    'backgroundColor': backgroundColor,
    'borderColor': borderColor,
    'borderWidth': borderWidth.toJson(),
    'padding': padding.toJson(),
  };
}

/// The `multiVariableText` schema type: a [text] with `{name}` variables.
/// The input is a JSON string with the value of each variable, eg.
/// `{"name": "Ann"}`. It is drawn like a [TextSchema].
class MultiVariableTextSchema extends TextSchema {
  const MultiVariableTextSchema({
    required super.name,
    required super.position,
    super.width = 50,
    super.height = 15,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    super.fontName,
    super.textFormat,
    super.fontVariants,
    super.fontVariantFallback,
    super.alignment,
    super.verticalAlignment,
    super.fontSize,
    super.lineHeight,
    super.characterSpacing,
    super.strikethrough,
    super.underline,
    super.dynamicFontSize,
    super.overflow,
    super.fontColor,
    super.backgroundColor,
    super.borderColor,
    super.borderWidth,
    super.padding,
    this.text = '',
    this.variables = const <String>[],
    this.contentSnapshot = false,
  });

  MultiVariableTextSchema.fromJson(super.json)
    : text = _str(json['text']) ?? '',
      variables = _strings(json['variables']),
      contentSnapshot = json['contentSnapshot'] == true,
      super.fromJson();

  @override
  String get type => 'multiVariableText';

  /// The text with `{name}` variables.
  final String text;

  /// The names of the variables in [text].
  final List<String> variables;

  /// True: a read-only schema draws its `content` as it is.
  final bool contentSnapshot;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    'text': text,
    'variables': variables,
    if (contentSnapshot) 'contentSnapshot': true,
  };
}

/// The `select` schema type: one of [options], drawn like a [TextSchema].
class SelectSchema extends TextSchema {
  const SelectSchema({
    required super.name,
    required super.position,
    super.width,
    super.height,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    super.fontName,
    super.textFormat,
    super.fontVariants,
    super.fontVariantFallback,
    super.alignment,
    super.verticalAlignment,
    super.fontSize,
    super.lineHeight,
    super.characterSpacing,
    super.strikethrough,
    super.underline,
    super.dynamicFontSize,
    super.overflow,
    super.fontColor,
    super.backgroundColor,
    super.borderColor,
    super.borderWidth,
    super.padding,
    this.options = const <String>['option1', 'option2'],
  });

  SelectSchema.fromJson(super.json)
    : options = _strings(json['options']),
      super.fromJson();

  @override
  String get type => 'select';

  /// The values the designer offers.
  final List<String> options;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    'options': options,
  };
}
