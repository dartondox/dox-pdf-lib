import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import 'fonts/font_store.dart';
import 'model/schema.dart';
import 'options.dart';
import 'raw_props.dart';
import 'schema.dart';
import 'template.dart';

/// What a plugin gets to draw one schema, like pdfme's `PDFRenderProps`.
class RenderProps<S extends Schema> {
  RenderProps({
    required this.value,
    required this.schema,
    required this.basePdf,
    required this.doc,
    required this.page,
    required this.options,
    required this.fonts,
    required this.cache,
  });

  /// The input value of the schema (`''` when there is none). For a
  /// read-only schema, its content.
  final String value;

  final S schema;

  /// The base PDF of the template.
  final BasePdf basePdf;

  final PDFDocument doc;

  final PDFPage page;

  final GenerateOptions options;

  /// The fonts of the options, embedded on first use.
  final FontStore fonts;

  /// One cache for the whole document (fonts, images, ...).
  final RenderCache cache;

  /// A copy with another [value] or [schema].
  RenderProps<S> copyWith({String? value, S? schema}) =>
      withSchema<S>(schema ?? this.schema, value: value);

  /// A copy for another schema, eg. to draw a [TextSchema] with
  /// `TextPlugin` from your own plugin.
  RenderProps<T> withSchema<T extends Schema>(T schema, {String? value}) =>
      RenderProps<T>(
        value: value ?? this.value,
        schema: schema,
        basePdf: basePdf,
        doc: doc,
        page: page,
        options: options,
        fonts: fonts,
        cache: cache,
      );
}

/// Values a plugin keeps for the whole document, eg. an embedded image or
/// font, so it is embedded once.
class RenderCache {
  final Map<String, Object?> _values = <String, Object?>{};

  /// The value of [key], or null when there is none of type [T].
  T? get<T>(String key) {
    Object? v = _values[key];
    return v is T ? v : null;
  }

  void set<T>(String key, T value) => _values[key] = value;
}

/// A schema type, like a pdfme plugin. It reads one schema type from JSON
/// and draws it on a page.
///
/// For your own type, make a schema class (see [Schema]) and a plugin for
/// it. Pass the plugin in the `plugins` of `generate`:
///
/// ```dart
/// class StampPlugin extends SchemaPlugin<StampSchema> {
///   const StampPlugin();
///
///   @override
///   String get type => 'stamp';
///
///   @override
///   StampSchema fromJson(Map<String, Object?> json) =>
///       StampSchema.fromJson(json);
///
///   @override
///   Future<void> pdf(RenderProps<StampSchema> props) async {
///     // draw props.schema on props.page
///   }
/// }
/// ```
abstract class SchemaPlugin<S extends Schema> {
  const SchemaPlugin();

  /// The schema `type` this plugin draws, eg. `text`.
  String get type;

  /// Reads the pdfme JSON of a schema of [type].
  S fromJson(Map<String, Object?> json);

  /// Draws the schema of [props] on its page.
  Future<void> pdf(RenderProps<S> props);

  Future<void> _drawRaw(RawProps raw, BasePdf basePdf) => pdf(
    RenderProps<S>(
      value: raw.value,
      schema: fromJson(raw.schema.json),
      basePdf: basePdf,
      doc: raw.doc,
      page: raw.page,
      options: raw.options,
      fonts: raw.fonts,
      cache: raw.cache,
    ),
  );
}

/// Draws the JSON schema of [raw] with [plugin]: the plugin reads it into
/// its own schema class first.
Future<void> drawWithPlugin(
  SchemaPlugin<Schema> plugin,
  RawProps raw,
  BasePdf basePdf,
) => plugin._drawRaw(raw, basePdf);

/// [props] as the JSON form the built-in drawers read.
RawProps rawProps(RenderProps<Schema> props) => RawProps(
  value: props.value,
  schema: RawSchema(props.schema.toJson()),
  basePdf: rawBasePdf(props.basePdf),
  doc: props.doc,
  page: props.page,
  options: props.options,
  fonts: props.fonts,
  cache: props.cache,
);
