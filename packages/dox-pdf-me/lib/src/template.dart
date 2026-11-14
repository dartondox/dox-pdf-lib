import 'schema.dart';

/// A pdfme template: the base PDF and the schemas of each page.
class Template {
  Template({required this.basePdf, required this.schemas});

  /// Reads the pdfme template JSON. The old format (each page a map of
  /// name to schema) is read too.
  factory Template.fromJson(Object? json) {
    if (json is! Map) {
      throw ArgumentError.value(json, 'template', 'must be a Map');
    }
    Object? pages = json['schemas'];
    if (pages is! List) {
      throw ArgumentError(
        '[@pdfme/common] Invalid argument:\n'
        'ERROR POSITION: template.schemas\n'
        'ERROR MESSAGE: Expected array',
      );
    }
    return Template(
      basePdf: json['basePdf'],
      schemas: <List<Schema>>[for (Object? page in pages) _page(page)],
    );
  }

  /// A blank page map `{width, height, padding}` (mm), or PDF bytes, a
  /// base64 string or a data URI.
  final Object? basePdf;

  final List<List<Schema>> schemas;

  /// True for a blank page map, like pdfme's `isBlankPdf`.
  bool get isBlank {
    Object? b = basePdf;
    if (b is! Map) return false;
    Object? padding = b['padding'];
    return b['width'] is num &&
        b['height'] is num &&
        padding is List &&
        padding.length == 4 &&
        padding.every((Object? p) => p is num);
  }

  /// The schemas drawn on every page (only for a blank base PDF).
  List<Schema> get staticSchema {
    Object? b = basePdf;
    if (!isBlank || b is! Map || b['staticSchema'] is! List) {
      return const <Schema>[];
    }
    return <Schema>[
      for (Object? s in b['staticSchema'] as List<dynamic>)
        if (s is Map) Schema(Map<String, dynamic>.from(s)),
    ];
  }

  static List<Schema> _page(Object? page) {
    if (page is List) {
      return <Schema>[
        for (Object? s in page)
          if (s is Map) Schema(Map<String, dynamic>.from(s)),
      ];
    }
    // pdfme's legacy format: {name: schema}
    if (page is Map) {
      return <Schema>[
        for (MapEntry<dynamic, dynamic> e in page.entries)
          if (e.value is Map)
            Schema(<String, dynamic>{
              ...Map<String, dynamic>.from(e.value as Map<dynamic, dynamic>),
              'name': '${e.key}',
            }),
      ];
    }
    return const <Schema>[];
  }
}
