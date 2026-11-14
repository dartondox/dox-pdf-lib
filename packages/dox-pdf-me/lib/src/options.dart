import 'fonts/font_store.dart';

/// The `options` of `generate`, like pdfme's `GeneratorOptions`.
class GenerateOptions {
  GenerateOptions({
    this.font,
    this.colorType,
    this.lang,
    this.title,
    this.author,
    this.subject,
    this.keywords,
    this.creator,
    this.producer,
    this.creationDate,
    this.modificationDate,
    this.basePdfPassword,
  });

  /// Reads the pdfme options map.
  factory GenerateOptions.fromJson(Map<String, Object?> json) {
    Map<String, Object?> m = json;
    Object? fonts = m['font'];
    String? str(String key) => m[key] is String ? m[key] as String : null;
    return GenerateOptions(
      font: fonts is Map
          ? <String, FontSource>{
              for (MapEntry<Object?, Object?> e in fonts.entries)
                '${e.key}': switch (e.value) {
                  Map<Object?, Object?> f => FontSource.fromJson(
                    '${e.key}',
                    <String, Object?>{
                      for (MapEntry<Object?, Object?> k in f.entries)
                        '${k.key}': k.value,
                    },
                  ),
                  _ => throw ArgumentError.value(
                    e.value,
                    'font.${e.key}',
                    'must be a map',
                  ),
                },
            }
          : null,
      colorType: str('colorType')?.toLowerCase() == 'cmyk'
          ? ColorType.cmyk
          : null,
      lang: str('lang'),
      title: str('title'),
      author: str('author'),
      subject: str('subject'),
      keywords: m['keywords'] is List
          ? <String>[for (Object? k in m['keywords'] as List<dynamic>) '$k']
          : null,
      creator: str('creator'),
      producer: str('producer'),
      creationDate: _date(m['creationDate']),
      modificationDate: _date(m['modificationDate']),
      basePdfPassword: str('basePdfPassword'),
    );
  }

  /// Fonts by name. Null: the default font (Roboto).
  final Map<String, FontSource>? font;

  /// RGB (default) or CMYK colors.
  final ColorType? colorType;

  /// The language of the PDF and the default date locale, eg. `en`.
  final String? lang;

  final String? title;
  final String? author;
  final String? subject;
  final List<String>? keywords;
  final String? creator;
  final String? producer;
  final DateTime? creationDate;
  final DateTime? modificationDate;

  /// Not supported yet: encrypted base PDFs can not be read.
  final String? basePdfPassword;

  static DateTime? _date(Object? v) => switch (v) {
    DateTime d => d,
    String s => DateTime.tryParse(s),
    _ => null,
  };
}

/// The color space of the colors in the PDF.
enum ColorType { rgb, cmyk }
