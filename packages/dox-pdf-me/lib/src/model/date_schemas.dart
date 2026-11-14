part of 'schema.dart';

/// The props of [DateSchema], [TimeSchema] and [DateTimeSchema]. The input
/// is a date (`2026/11/14`), a time (`20:25`) or both (`2026/11/14 20:25`).
/// It is formatted with [format] and drawn like a text, centered
/// vertically.
abstract class BaseDateSchema extends Schema {
  const BaseDateSchema({
    required super.name,
    required super.position,
    super.width = 50,
    super.height = 10,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    this.format,
    this.locale,
    this.fontName,
    this.alignment = Alignment.left,
    this.fontSize = 13,
    this.characterSpacing = 0,
    this.fontColor = '#000000',
    this.backgroundColor = '',
  });

  BaseDateSchema.fromJson(super.json)
    : format = _str(json['format']),
      locale = _str(json['locale']),
      fontName = _str(json['fontName']),
      alignment = _enum(Alignment.values, json['alignment'], Alignment.left),
      fontSize = _num(json['fontSize']) ?? 13,
      characterSpacing = _num(json['characterSpacing']) ?? 0,
      fontColor = _str(json['fontColor']) ?? '#000000',
      backgroundColor = _str(json['backgroundColor']) ?? '',
      super.fromJson();

  /// date-fns tokens, eg. `yyyy/MM/dd` or `HH:mm`. Null: the format of the
  /// locale (eg. `MM/dd/yyyy` for `en`).
  final String? format;

  /// eg. `ja`. Null: the `lang` option, or `en`.
  final String? locale;

  /// A font name of the `font` option. Null: the fallback font.
  final String? fontName;

  final Alignment alignment;

  /// Points.
  final double fontSize;

  /// Points between letters.
  final double characterSpacing;

  /// A hex color.
  final String fontColor;

  /// A hex color, or `''` for none.
  final String backgroundColor;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    if (format != null) 'format': format,
    if (locale != null) 'locale': locale,
    if (fontName != null) 'fontName': fontName,
    'alignment': alignment.json,
    'fontSize': _out(fontSize),
    'characterSpacing': _out(characterSpacing),
    'fontColor': fontColor,
    'backgroundColor': backgroundColor,
  };
}

/// The `date` schema type.
class DateSchema extends BaseDateSchema {
  const DateSchema({
    required super.name,
    required super.position,
    super.width,
    super.height,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    super.format,
    super.locale,
    super.fontName,
    super.alignment,
    super.fontSize,
    super.characterSpacing,
    super.fontColor,
    super.backgroundColor,
  });

  DateSchema.fromJson(super.json) : super.fromJson();

  @override
  String get type => 'date';
}

/// The `time` schema type.
class TimeSchema extends BaseDateSchema {
  const TimeSchema({
    required super.name,
    required super.position,
    super.width,
    super.height,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    super.format,
    super.locale,
    super.fontName,
    super.alignment,
    super.fontSize,
    super.characterSpacing,
    super.fontColor,
    super.backgroundColor,
  });

  TimeSchema.fromJson(super.json) : super.fromJson();

  @override
  String get type => 'time';
}

/// The `dateTime` schema type.
class DateTimeSchema extends BaseDateSchema {
  const DateTimeSchema({
    required super.name,
    required super.position,
    super.width,
    super.height,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    super.format,
    super.locale,
    super.fontName,
    super.alignment,
    super.fontSize,
    super.characterSpacing,
    super.fontColor,
    super.backgroundColor,
  });

  DateTimeSchema.fromJson(super.json) : super.fromJson();

  @override
  String get type => 'dateTime';
}
