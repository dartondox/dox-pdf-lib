import 'dart:convert';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import '../constants.dart';
import 'font_metrics.dart';
import 'roboto.dart';

/// One font of the `font` option, like pdfme's
/// `{data, fallback, subset}`.
class FontSource {
  FontSource(this.data, {this.fallback = false, this.subset = true});

  /// Reads `{data, fallback, subset}`. `data` is bytes, a base64 string or
  /// a `data:` URI.
  factory FontSource.fromJson(String name, Map<String, Object?> json) {
    return FontSource(
      _bytes(name, json['data']),
      fallback: json['fallback'] == true,
      subset: json['subset'] != false,
    );
  }

  /// The font file (TrueType or OpenType).
  final Uint8List data;

  /// The font for schemas with no `fontName`. Exactly one font has it.
  final bool fallback;

  /// Embed only the used glyphs. Default: true, like pdfme.
  final bool subset;

  static Uint8List _bytes(String name, Object? data) => switch (data) {
    Uint8List b => b,
    ByteBuffer b => b.asUint8List(),
    List<int> b => Uint8List.fromList(b),
    String s when s.startsWith('http://') || s.startsWith('https://') =>
      throw ArgumentError.value(
        s,
        'font.$name.data',
        'font URLs are not loaded; pass the font bytes or base64',
      ),
    String s => base64.decode(
      s.startsWith('data:') ? s.substring(s.indexOf(',') + 1) : s,
    ),
    _ => throw ArgumentError.value(
      data,
      'font.$name.data',
      'must be bytes or a base64 string',
    ),
  };
}

/// The fonts of one `generate` call. A font is embedded into the document
/// the first time a schema uses it, and only once.
class FontStore {
  FontStore(this.doc, Map<String, FontSource>? fonts)
    : sources = fonts == null || fonts.isEmpty
          ? <String, FontSource>{defaultFontName: defaultFont}
          : fonts;

  /// pdfme's default font: Roboto, as fallback, subset.
  static final FontSource defaultFont = FontSource(
    base64.decode(robotoBase64),
    fallback: true,
  );

  final PDFDocument doc;

  final Map<String, FontSource> sources;

  final Map<String, Future<PDFFont>> _embedded = <String, Future<PDFFont>>{};
  final Map<String, FontMetrics> _metrics = <String, FontMetrics>{};

  /// The name of the font with `fallback: true` (the first one).
  String get fallbackName {
    for (MapEntry<String, FontSource> e in sources.entries) {
      if (e.value.fallback) return e.key;
    }
    return sources.keys.first;
  }

  /// [name], or the fallback font name when [name] is null or empty.
  String resolve(String? name) =>
      name == null || name.isEmpty ? fallbackName : name;

  /// The embedded font [name]. Throws when there is no such font.
  Future<PDFFont> embed(String name) {
    FontSource? source = sources[name];
    if (source == null) {
      throw ArgumentError('[@pdfme/schemas] Font "$name" is not found.');
    }
    return _embedded[name] ??= doc.embedFont(
      source.data,
      subset: source.subset,
    );
  }

  /// The metrics of font [name]. Like pdfme, an unknown name measures with
  /// the fallback font.
  FontMetrics metrics(String? name) {
    String key = sources.containsKey(name) ? name! : fallbackName;
    return _metrics[key] ??= FontMetrics.parse(sources[key]!.data);
  }
}
