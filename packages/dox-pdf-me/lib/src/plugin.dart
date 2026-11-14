import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import 'fonts/font_store.dart';
import 'options.dart';
import 'schema.dart';

/// What a plugin gets to draw one schema, like pdfme's `PDFRenderProps`.
class RenderProps {
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

  /// The input value of the schema (`''` when there is none).
  final String value;

  final Schema schema;

  /// The `basePdf` of the template: a blank page map, or PDF data.
  final Object? basePdf;

  final PDFDocument doc;

  final PDFPage page;

  final GenerateOptions options;

  /// The fonts of the options, embedded on first use.
  final FontStore fonts;

  /// One cache for the whole document (fonts, images, ...).
  final Map<Object, Object?> cache;

  /// A copy with another [value] or [schema].
  RenderProps copyWith({String? value, Schema? schema}) => RenderProps(
    value: value ?? this.value,
    schema: schema ?? this.schema,
    basePdf: basePdf,
    doc: doc,
    page: page,
    options: options,
    fonts: fonts,
    cache: cache,
  );
}

/// A schema type, like a pdfme plugin. It draws one schema on a page.
///
/// Make your own type: extend this class, and pass it in the `plugins` of
/// `generate`.
abstract class SchemaPlugin {
  const SchemaPlugin();

  /// The schema `type` this plugin draws, eg. `text`.
  String get type;

  /// Draws the schema of [props] on its page.
  Future<void> pdf(RenderProps props);
}
