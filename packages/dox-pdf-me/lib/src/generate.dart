import 'dart:convert';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import 'base_pdf.dart';
import 'constants.dart';
import 'expression.dart';
import 'fonts/font_store.dart';
import 'options.dart';
import 'plugin.dart';
import 'plugins.dart';
import 'schema.dart';
import 'template.dart';

/// Makes a PDF from a pdfme [template] and [inputs], like pdfme's
/// `generate`.
///
/// - [template]: the pdfme template JSON (a `Map`): `basePdf` and
///   `schemas`, or a [Template].
/// - [inputs]: one map per copy of the template. Keys are schema names.
/// - [options]: the pdfme options JSON (`font`, `lang`, `title`, ...), or
///   [GenerateOptions].
/// - [plugins]: the schema types to use. With no plugins, only `text`
///   works, like pdfme. Pass [builtInPlugins] for all built-in types.
///
/// Returns the bytes of the PDF file.
Future<Uint8List> generate({
  required Object template,
  required List<Map<String, dynamic>> inputs,
  Object? options,
  Map<String, SchemaPlugin>? plugins,
}) => Generator(
  template: template is Template ? template : Template.fromJson(template),
  inputs: inputs,
  options: switch (options) {
    GenerateOptions o => o,
    Map<String, dynamic> m => GenerateOptions.fromJson(m),
    null => GenerateOptions(),
    _ => throw ArgumentError.value(options, 'options', 'must be a Map'),
  },
  plugins: plugins == null || plugins.isEmpty ? defaultPlugins : plugins,
  userPlugins: plugins != null && plugins.isNotEmpty,
).run();

/// One run of [generate].
class Generator {
  Generator({
    required this.template,
    required this.inputs,
    required this.options,
    required this.plugins,
    required this.userPlugins,
  });

  final Template template;
  final List<Map<String, dynamic>> inputs;
  final GenerateOptions options;
  final Map<String, SchemaPlugin> plugins;

  /// True when the caller passed plugins (they are checked first).
  final bool userPlugins;

  Future<Uint8List> run() async {
    _validate();
    Map<String, SchemaPlugin> renderers = _renderers();
    PDFDocument doc = await PDFDocument.create();
    try {
      FontStore fonts = FontStore(doc, options.font);
      Map<Object, Object?> cache = <Object, Object?>{};
      BasePages base = await BasePages.create(doc, template, options);
      List<Schema> allSchemas = <Schema>[
        for (List<Schema> page in template.schemas) ...page,
      ];
      for (Map<String, dynamic> input in inputs) {
        for (int j = 0; j < base.length; j++) {
          PDFPage page = base.insert(j);
          PlaceholderResolver resolver = PlaceholderResolver(
            schemas: allSchemas,
            variables: <String, dynamic>{
              ...input,
              'totalPages': base.length,
              'currentPage': j + 1,
            },
          );
          RenderProps props(Schema schema, String value) => RenderProps(
            value: value,
            schema: schema,
            basePdf: template.basePdf,
            doc: doc,
            page: page,
            options: options,
            fonts: fonts,
            cache: cache,
          );
          for (Schema s in template.staticSchema) {
            SchemaPlugin? plugin = renderers[s.type];
            if (plugin == null) continue;
            String value = s.readOnly ? resolver.resolve(s) : (s.content ?? '');
            await plugin.pdf(props(s, value));
          }
          List<Schema> pageSchemas = j < template.schemas.length
              ? template.schemas[j]
              : const <Schema>[];
          for (Schema s in pageSchemas) {
            if (s.name.isEmpty) continue;
            SchemaPlugin? plugin = renderers[s.type];
            if (plugin == null) continue;
            String value = s.readOnly
                ? resolver.resolve(s)
                : inputValue(input[s.name]);
            await plugin.pdf(props(s, value));
          }
        }
      }
      _metadata(doc);
      return await doc.save();
    } finally {
      doc.dispose();
    }
  }

  /// pdfme's `input[name] || ''`, as a string.
  static String inputValue(Object? value) => switch (value) {
    null || false || '' => '',
    num n when n == 0 || n.isNaN => '',
    String s => s,
    Map<dynamic, dynamic> _ || List<dynamic> _ => jsonEncode(value),
    _ => PlaceholderResolver.jsString(value),
  };

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
    for (List<Schema> page in template.schemas) {
      for (Schema s in page) {
        if (s.required &&
            !s.readOnly &&
            !inputs.any((Map<String, dynamic> i) => _truthy(i[s.name]))) {
          throw ArgumentError(
            "[@pdfme/generator] input for '${s.name}' is required to "
            'generate this PDF',
          );
        }
      }
    }
  }

  static bool _truthy(Object? v) => inputValue(v).isNotEmpty;

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
      for (List<Schema> page in template.schemas)
        for (Schema s in page)
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
    Set<String> types = <String>{for (SchemaPlugin p in plugins.values) p.type};
    Set<String> missing = <String>{
      for (List<Schema> page in template.schemas)
        for (Schema s in page)
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
  Map<String, SchemaPlugin> _renderers() {
    Map<String, SchemaPlugin> out = <String, SchemaPlugin>{};
    Iterable<Schema> all = <Schema>[
      for (List<Schema> page in template.schemas) ...page,
      ...template.staticSchema,
    ];
    for (Schema s in all) {
      if (out.containsKey(s.type)) continue;
      SchemaPlugin? plugin = findPlugin(plugins, s.type);
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
