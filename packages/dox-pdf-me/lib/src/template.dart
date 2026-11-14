import 'dart:convert';
import 'dart:typed_data';

import 'base_pdf.dart';
import 'model/schema.dart';
import 'plugin.dart';
import 'plugins.dart';
import 'raw_template.dart';
import 'schema.dart';

/// A pdfme template: the base PDF and the schemas of each page.
///
/// Build it in Dart:
///
/// ```dart
/// Template(
///   basePdf: BlankPdf(),
///   schemas: [
///     [TextSchema(name: 'title', position: Position(20, 20), width: 170)],
///   ],
/// )
/// ```
///
/// Or read the JSON of the pdfme designer with [Template.fromJson].
class Template {
  const Template({required this.basePdf, required this.schemas})
    : _source = null;

  const Template._(this.basePdf, this.schemas, this._source);

  /// Reads the pdfme template JSON. The old format (each page a map of
  /// name to schema) is read too.
  ///
  /// Each schema is read by the plugin of its type: first [plugins], then
  /// [builtInPlugins]. A type with no plugin reads as [UnknownSchema].
  factory Template.fromJson(
    Map<String, Object?> json, {
    Map<String, SchemaPlugin<Schema>> plugins = builtInPlugins,
  }) {
    RawTemplate raw = RawTemplate.fromJson(json);
    Schema read(RawSchema s) {
      SchemaPlugin<Schema>? plugin =
          findPlugin(plugins, s.type) ?? findPlugin(builtInPlugins, s.type);
      return plugin != null
          ? plugin.fromJson(s.json)
          : UnknownSchema.fromJson(s.json);
    }

    Object? base = raw.basePdf;
    return Template._(
      raw.isBlank && base is Map<Object?, Object?>
          ? BlankPdf(
              width: (base['width']! as num).toDouble(),
              height: (base['height']! as num).toDouble(),
              padding: _padding(base['padding']! as List<Object?>),
              staticSchema: <Schema>[
                for (RawSchema s in raw.staticSchema) read(s),
              ],
            )
          : PdfFile(BasePages.bytes(base)),
      <List<Schema>>[
        for (List<RawSchema> page in raw.schemas)
          <Schema>[for (RawSchema s in page) read(s)],
      ],
      Map<String, Object?>.of(json),
    );
  }

  final BasePdf basePdf;

  /// The schemas of each page.
  final List<List<Schema>> schemas;

  /// The JSON map of `fromJson`, or null.
  final Map<String, Object?>? _source;

  /// The pdfme template JSON.
  ///
  /// A template read with [Template.fromJson] keeps the keys this package
  /// does not know: top-level keys (eg. `pdfmeVersion`) and extra keys of a
  /// blank `basePdf`. The schemas are written from the typed classes, and
  /// each keeps its own extra keys. The old format (each page a map) is
  /// written as the list format.
  Map<String, Object?> toJson() {
    Map<String, Object?>? source = _source;
    Object? sourceBase = source?['basePdf'];
    Object base = switch (basePdf) {
      BlankPdf b => <String, Object?>{
        if (sourceBase is Map<Object?, Object?>)
          for (MapEntry<Object?, Object?> e in sourceBase.entries)
            if (e.key is String) e.key! as String: e.value,
        'width': b.width,
        'height': b.height,
        'padding': b.padding.toList(),
        if (b.staticSchema.isNotEmpty)
          'staticSchema': <Map<String, Object?>>[
            for (Schema s in b.staticSchema) s.toJson(),
          ],
      },
      PdfFile f =>
        sourceBase is String
            ? sourceBase
            : 'data:application/pdf;base64,${base64.encode(f.bytes)}',
    };
    return <String, Object?>{
      ...?source,
      'basePdf': base,
      'schemas': <List<Map<String, Object?>>>[
        for (List<Schema> page in schemas)
          <Map<String, Object?>>[for (Schema s in page) s.toJson()],
      ],
    };
  }

  static Sides _padding(List<Object?> p) => Sides(
    top: (p[0]! as num).toDouble(),
    right: (p[1]! as num).toDouble(),
    bottom: (p[2]! as num).toDouble(),
    left: (p[3]! as num).toDouble(),
  );
}

/// The pages the schemas are drawn on: [BlankPdf] or [PdfFile].
sealed class BasePdf {
  const BasePdf();
}

/// Blank pages of one size, in mm. The template has one page per schema
/// page.
class BlankPdf extends BasePdf {
  /// An A4 page with 10 mm padding, like pdfme's `BLANK_A4_PDF`.
  const BlankPdf({
    this.width = 210,
    this.height = 297,
    this.padding = const Sides.all(10),
    this.staticSchema = const <Schema>[],
  });

  /// mm.
  final double width;

  /// mm.
  final double height;

  /// The page margin in mm. Tables that grow stay inside it.
  final Sides padding;

  /// Schemas drawn on every page, eg. a header with `{currentPage}` and
  /// `{totalPages}` in a read-only text.
  final List<Schema> staticSchema;
}

/// A PDF file. Each page of the file is one page of the template. The
/// schemas are drawn on top.
class PdfFile extends BasePdf {
  const PdfFile(this.bytes);

  final Uint8List bytes;
}

/// The `basePdf` value the internal code reads: a blank page map, or PDF
/// bytes. With [withStatic], the static schemas are in the map.
Object rawBasePdf(BasePdf basePdf, {bool withStatic = false}) =>
    switch (basePdf) {
      BlankPdf b => <String, Object?>{
        'width': b.width,
        'height': b.height,
        'padding': b.padding.toList(),
        if (withStatic)
          'staticSchema': <Map<String, Object?>>[
            for (Schema s in b.staticSchema) s.toJson(),
          ],
      },
      PdfFile f => f.bytes,
    };

/// [template] as the JSON form the internal code reads.
RawTemplate rawTemplate(Template template) => RawTemplate(
  basePdf: rawBasePdf(template.basePdf, withStatic: true),
  schemas: <List<RawSchema>>[
    for (List<Schema> page in template.schemas)
      <RawSchema>[for (Schema s in page) RawSchema(s.toJson())],
  ],
);
