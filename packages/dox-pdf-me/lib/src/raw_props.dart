import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import 'fonts/font_store.dart';
import 'options.dart';
import 'plugin.dart' show RenderCache;
import 'schema.dart';

/// What a built-in drawer gets to draw one schema, like pdfme's
/// `PDFRenderProps`. The schema is the JSON map, read like pdfme reads it.
class RawProps {
  RawProps({
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

  final RawSchema schema;

  /// The `basePdf` of the template: a blank page map, or PDF bytes.
  final Object? basePdf;

  final PDFDocument doc;

  final PDFPage page;

  final GenerateOptions options;

  /// The fonts of the options, embedded on first use.
  final FontStore fonts;

  /// One cache for the whole document (fonts, images, ...).
  final RenderCache cache;

  /// A copy with another [value] or [schema].
  RawProps copyWith({String? value, RawSchema? schema}) => RawProps(
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

/// The drawing code of one built-in schema type. It reads the schema JSON
/// map, so a template from the pdfme designer draws like in pdfme.
abstract interface class RawDrawer {
  /// The schema `type` this drawer draws, eg. `text`.
  String get type;

  /// Draws the schema of [props] on its page.
  Future<void> draw(RawProps props);
}
