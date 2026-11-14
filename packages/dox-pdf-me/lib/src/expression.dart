import 'dart:convert';

import 'schema.dart';

/// Fills `{...}` placeholders in the content of read-only schemas, like
/// pdfme's `replacePlaceholders`.
///
/// pdfme runs a small JavaScript expression in the braces. This port reads
/// names and dotted paths only: `{name}`, `{currentPage}`, `{totalPages}`,
/// `{date}`, `{dateTime}`, `{customer.name}`. Other expressions stay as
/// they are, like pdfme does when an expression fails.
class PlaceholderResolver {
  PlaceholderResolver({required this.schemas, required this.variables});

  /// All page schemas of the template.
  final List<RawSchema> schemas;

  /// The input, `totalPages` and `currentPage`.
  final Map<String, dynamic> variables;

  static final RegExp _path = RegExp(
    r'^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*$',
  );

  /// pdfme's `resolveReadOnlyContent`.
  String resolve(RawSchema schema) {
    String content = schema.content ?? '';
    if (schema.type == 'multiVariableText') return content;
    return replace(content);
  }

  /// pdfme's `replacePlaceholders`.
  String replace(String content) {
    if (!content.contains('{') || !content.contains('}')) return content;
    DateTime now = DateTime.now();
    Map<String, dynamic> context = <String, dynamic>{
      'date': _date(now),
      'dateTime': '${_date(now)} ${_two(now.hour)}:${_two(now.minute)}',
      for (RawSchema s in schemas) s.name: s.readOnly ? (s.content ?? '') : '',
      ...variables,
    };
    context.updateAll((String key, dynamic value) => _parseJson(value));
    for (String key in context.keys.toList()) {
      Object? value = context[key];
      if (value is String && value.contains('{') && value.contains('}')) {
        context[key] = _evaluate(value, context);
      }
    }
    return _evaluate(content, context);
  }

  String _evaluate(String content, Map<String, dynamic> context) {
    StringBuffer out = StringBuffer();
    int index = 0;
    while (index < content.length) {
      int start = content.indexOf('{', index);
      if (start < 0) {
        out.write(content.substring(index));
        break;
      }
      out.write(content.substring(index, start));
      int depth = 1;
      int end = start + 1;
      while (end < content.length && depth > 0) {
        if (content[end] == '{') depth++;
        if (content[end] == '}') depth--;
        end++;
      }
      if (depth != 0) {
        out.write(content.substring(start));
        break;
      }
      String code = content.substring(start + 1, end - 1).trim();
      (bool, Object?) value = _lookup(code, context);
      out.write(value.$1 ? jsString(value.$2) : content.substring(start, end));
      index = end;
    }
    return out.toString();
  }

  /// A name or dotted path in [context]: (found, value).
  (bool, Object?) _lookup(String code, Map<String, dynamic> context) {
    if (!_path.hasMatch(code)) return (false, null);
    List<String> parts = code.split('.');
    if (!context.containsKey(parts.first)) return (false, null);
    Object? value = context[parts.first];
    for (String part in parts.skip(1)) {
      if (value is Map && value.containsKey(part)) {
        value = value[part];
      } else if (value is List && part == 'length') {
        value = value.length;
      } else if (value is String && part == 'length') {
        value = value.length;
      } else {
        // JavaScript gives `undefined` for a missing key
        value = _undefined;
      }
    }
    return (true, value);
  }

  static const Object _undefined = Object();

  /// JavaScript's `String(value)` for JSON values.
  static String jsString(Object? value) {
    if (identical(value, _undefined)) return 'undefined';
    return switch (value) {
      null => 'null',
      String s => s,
      double d when d == d.truncateToDouble() && d.isFinite => '${d.toInt()}',
      List<dynamic> l => l.map(jsString).join(','),
      Map<dynamic, dynamic> _ => '[object Object]',
      _ => '$value',
    };
  }

  /// pdfme's `parseData`: a string that is JSON is parsed (`"12"` becomes
  /// the number 12).
  static Object? _parseJson(Object? value) {
    if (value is! String || value.isEmpty) return value;
    try {
      return jsonDecode(value);
    } on FormatException {
      return value;
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _date(DateTime d) =>
      '${d.year}/${_two(d.month)}/${_two(d.day)}';
}
