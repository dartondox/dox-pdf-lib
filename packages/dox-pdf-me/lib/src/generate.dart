import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import 'base_pdf.dart';
import 'constants.dart';
import 'dynamic_template.dart';
import 'expression.dart';
import 'fonts/font_store.dart';
import 'model/schema.dart';
import 'options.dart';
import 'plugin.dart';
import 'plugins.dart';
import 'raw_props.dart';
import 'raw_template.dart';
import 'schema.dart';
import 'table/table_layout.dart';
import 'template.dart';

/// Makes a PDF from a [template] and [inputs], like pdfme's `generate`.
///
/// - [template]: build it in Dart, or read the pdfme JSON with
///   `Template.fromJson`.
/// - [inputs]: one map per copy of the template. Keys are schema names,
///   values are the input strings. A table takes a JSON string of rows
///   (`jsonEncode(rows)`), a multiVariableText a JSON string of values.
/// - [options]: fonts, language and PDF metadata.
/// - [plugins]: the schema types to use. With no plugins, only `text`
///   works, like pdfme. Pass [builtInPlugins] for all built-in types.
///
/// Returns the bytes of the PDF file.
Future<Uint8List> generate({
  required Template template,
  required List<Map<String, String>> inputs,
  GenerateOptions? options,
  Map<String, SchemaPlugin<Schema>>? plugins,
}) => Generator(
  template: rawTemplate(template),
  basePdf: template.basePdf,
  inputs: inputs,
  options: options ?? GenerateOptions(),
  plugins: plugins == null || plugins.isEmpty ? defaultPlugins : plugins,
  userPlugins: plugins != null && plugins.isNotEmpty,
).run();

/// One run of [generate].
class Generator {
  Generator({
    required this.template,
    required this.basePdf,
    required this.inputs,
    required this.options,
    required this.plugins,
    required this.userPlugins,
  });

  final RawTemplate template;

  /// The typed base PDF of the template, for the plugins.
  final BasePdf basePdf;

  final List<Map<String, String>> inputs;
  final GenerateOptions options;
  final Map<String, SchemaPlugin<Schema>> plugins;

  /// True when the caller passed plugins (they are checked first).
  final bool userPlugins;

  Future<Uint8List> run() async {
    _validate();
    Map<String, SchemaPlugin<Schema>> renderers = _renderers();
    PDFDocument doc = await PDFDocument.create();
    try {
      FontStore fonts = FontStore(doc, options.font);
      RenderCache cache = RenderCache();
      BasePages base = await BasePages.create(doc, template, options);
      // pdfme: tables grow and go on over pages, on a blank base PDF only
      bool grows =
          template.isBlank &&
          template.schemas.any(
            (List<RawSchema> p) => p.any(isDynamicLayoutSchema),
          );
      for (Map<String, String> input in inputs) {
        List<List<RawSchema>> schemas = grows
            ? await dynamicTemplate(
                template,
                (RawSchema s) => tableDynamicLayout(
                  s,
                  _value(s, input, null),
                  fonts,
                  template.basePdf,
                ),
              )
            : template.schemas;
        List<RawSchema> allSchemas = <RawSchema>[
          for (List<RawSchema> page in schemas) ...page,
        ];
        int pageCount = template.isBlank ? schemas.length : base.length;
        for (int j = 0; j < pageCount; j++) {
          PDFPage page = base.insert(j);
          PlaceholderResolver resolver = PlaceholderResolver(
            schemas: allSchemas,
            variables: <String, dynamic>{
              ...input,
              'totalPages': pageCount,
              'currentPage': j + 1,
            },
          );
          RawProps props(RawSchema schema, String value) => RawProps(
            value: value,
            schema: schema,
            basePdf: template.basePdf,
            doc: doc,
            page: page,
            options: options,
            fonts: fonts,
            cache: cache,
          );
          for (RawSchema s in template.staticSchema) {
            SchemaPlugin<Schema>? plugin = renderers[s.type];
            if (plugin == null) continue;
            String value = s.readOnly && s.type == 'table'
                ? readOnlyTableValue(s, input)
                : s.readOnly
                ? resolver.resolve(s)
                : (s.content ?? '');
            await drawWithPlugin(plugin, props(s, value), basePdf);
          }
          List<RawSchema> pageSchemas = j < schemas.length
              ? schemas[j]
              : const <RawSchema>[];
          for (RawSchema s in pageSchemas) {
            if (s.name.isEmpty) continue;
            SchemaPlugin<Schema>? plugin = renderers[s.type];
            if (plugin == null) continue;
            await drawWithPlugin(
              plugin,
              props(s, _value(s, input, resolver)),
              basePdf,
            );
          }
        }
      }
      _metadata(doc);
      return await doc.save();
    } finally {
      doc.dispose();
    }
  }

  /// The value of page schema [s]: the input, or for a read-only schema
  /// its content (with placeholders filled by [resolver]).
  static String _value(
    RawSchema s,
    Map<String, String> input,
    PlaceholderResolver? resolver,
  ) {
    if (!s.readOnly) return input[s.name] ?? '';
    if (s.type == 'table') return readOnlyTableValue(s, input);
    return resolver?.resolve(s) ?? (s.content ?? '');
  }

  /// pdfme's `getReadOnlyTableValue`: the input of the table when it has
  /// one, else the `content` of the schema. Placeholders are not filled.
  static String readOnlyTableValue(RawSchema s, Map<String, String> input) =>
      input[s.name] ?? s.content ?? '';

  void _validate() {
    if (inputs.isEmpty) {
      throw ArgumentError(
        '[@pdfme/generator] inputs should not be empty, pass at least an '
        'empty object in the array',
      );
    }
    Map<String, FontSource>? font = options.font;
    if (font != null) _checkFont(font);
    if (userPlugins) _checkPlugins();
    for (List<RawSchema> page in template.schemas) {
      for (RawSchema s in page) {
        if (s.required &&
            !s.readOnly &&
            !inputs.any((Map<String, String> i) => _truthy(i[s.name]))) {
          throw ArgumentError(
            "[@pdfme/generator] input for '${s.name}' is required to "
            'generate this PDF',
          );
        }
      }
    }
  }

  static bool _truthy(String? v) => v != null && v.isNotEmpty;

  void _checkFont(Map<String, FontSource> font) {
    const String doc =
        'Check this document: https://pdfme.com/docs/custom-fonts#about-font-type';
    int fallbacks = font.values.where((FontSource f) => f.fallback).length;
    if (fallbacks == 0) {
      throw ArgumentError(
        '[@pdfme/common] fallback flag is not found in font. true fallback '
        'flag must be only one.\n$doc',
      );
    }
    if (fallbacks > 1) {
      throw ArgumentError(
        '[@pdfme/common] $fallbacks fallback flags found in font. true '
        'fallback flag must be only one.\n$doc',
      );
    }
    Set<String> missing = <String>{
      for (List<RawSchema> page in template.schemas)
        for (RawSchema s in page)
          if (s.string('fontName') case String n
              when n.isNotEmpty && !font.containsKey(n))
            n,
    };
    if (missing.isNotEmpty) {
      throw ArgumentError(
        '[@pdfme/common] ${missing.join(',')} of template.schemas is not '
        'found in font.\n$doc',
      );
    }
  }

  void _checkPlugins() {
    Set<String> types = <String>{
      for (SchemaPlugin<Schema> p in plugins.values) p.type,
    };
    Set<String> missing = <String>{
      for (List<RawSchema> page in template.schemas)
        for (RawSchema s in page)
          if (!types.contains(s.type)) s.type,
    };
    if (missing.isNotEmpty) {
      throw ArgumentError(
        '[@pdfme/common] ${missing.join(',')} of template.schemas is not '
        'found in plugins.',
      );
    }
  }

  /// One plugin per schema type used. Throws for a type with no plugin.
  Map<String, SchemaPlugin<Schema>> _renderers() {
    Map<String, SchemaPlugin<Schema>> out = <String, SchemaPlugin<Schema>>{};
    Iterable<RawSchema> all = <RawSchema>[
      for (List<RawSchema> page in template.schemas) ...page,
      ...template.staticSchema,
    ];
    for (RawSchema s in all) {
      if (out.containsKey(s.type)) continue;
      SchemaPlugin<Schema>? plugin = findPlugin(plugins, s.type);
      if (plugin == null) {
        throw ArgumentError(
          '[@pdfme/generator] Plugin or renderer for type ${s.type} not '
          'found.\nCheck this document: https://pdfme.com/docs/custom-schemas',
        );
      }
      out[s.type] = plugin;
    }
    return out;
  }

  void _metadata(PDFDocument doc) {
    DateTime now = DateTime.now();
    doc
      ..setAuthor(options.author ?? toolName)
      ..setCreationDate(options.creationDate ?? now)
      ..setCreator(options.creator ?? toolName)
      ..setKeywords(options.keywords ?? const <String>[])
      ..setLanguage(options.lang ?? 'en')
      ..setModificationDate(options.modificationDate ?? now)
      ..setProducer(options.producer ?? toolName)
      ..setSubject(options.subject ?? '')
      ..setTitle(options.title ?? '');
  }
}
