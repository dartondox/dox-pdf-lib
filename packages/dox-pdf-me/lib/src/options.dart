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
    Map<String, dynamic>? extra,
  }) : extra = extra ?? <String, dynamic>{};

  /// Reads the pdfme options map. Unknown keys go to [extra].
  factory GenerateOptions.fromJson(Map<String, dynamic>? json) {
    Map<String, dynamic> m = json ?? <String, dynamic>{};
    Object? fonts = m['font'];
    String? str(String key) => m[key] is String ? m[key] as String : null;
    return GenerateOptions(
      font: fonts is Map
          ? <String, FontSource>{
              for (MapEntry<dynamic, dynamic> e in fonts.entries)
                '${e.key}': FontSource.fromJson('${e.key}', e.value),
            }
          : null,
      colorType: str('colorType'),
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
      extra: m,
    );
  }

  /// Fonts by name. Null: the default font (Roboto).
  final Map<String, FontSource>? font;

  /// `rgb` (default) or `cmyk`.
  final String? colorType;

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

  /// The whole options map, for plugins that read their own keys.
  final Map<String, dynamic> extra;

  static DateTime? _date(Object? v) => switch (v) {
    DateTime d => d,
    String s => DateTime.tryParse(s),
    _ => null,
  };
}
