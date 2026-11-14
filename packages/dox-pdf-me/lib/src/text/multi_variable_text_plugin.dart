import 'dart:convert';

import '../expression.dart';
import '../raw_props.dart';
import '../schema.dart';
import 'text_plugin.dart';

/// The `multiVariableText` schema type, like pdfme's.
///
/// The schema has a `text` with `{name}` variables and a `variables` list
/// of names. The input is a JSON object with the value of each variable,
/// eg. `{"name": "Ann", "city": "Paris"}`. The plugin puts the values in
/// the text, removes the `{...}` variables that have no value, and draws
/// the result like a `text` schema (all text props work, also
/// `dynamicFontSize`).
///
/// - A variable of `variables` that is missing in the input (or `null`):
///   nothing is drawn. With `required: true`, it is an error.
/// - `readOnly: true`: the values come from the schema `content` (a JSON
///   object). With `contentSnapshot: true`, `content` is the text to draw.
class MultiVariableTextDrawer implements RawDrawer {
  const MultiVariableTextDrawer();

  @override
  String get type => 'multiVariableText';

  @override
  Future<void> draw(RawProps props) async {
    RawSchema schema = props.schema;
    String value;
    if (schema.readOnly) {
      value = readOnlyText(schema, props.value);
    } else {
      if (!validateVariables(props.value, schema)) return;
      value = substituteVariables(schema.string('text') ?? '', props.value);
    }
    await const TextDrawer().draw(props.copyWith(value: value));
  }

  /// pdfme's `substituteVariables`. [variables] is a JSON string or a
  /// decoded object. Every `{name}` of a key gets its value, in the key
  /// order of JavaScript. Then all `{...}` that are left are removed.
  static String substituteVariables(String text, Object? variables) {
    if (text.isEmpty) return '';
    String out = text;
    if (_truthy(variables)) {
      Object? map = variables;
      if (variables is String) {
        try {
          map = jsonDecode(variables);
        } on FormatException {
          throw FormatException(
            "[@pdfme/schemas] MVT: invalid JSON string '$variables'",
          );
        }
      }
      for (String key in _keys(map)) {
        String value = PlaceholderResolver.jsString(_get(map, key).$2);
        out = _replaceAll(out, '{$key}', value);
      }
    }
    // the variables without a value
    return out.replaceAll(_leftover, '');
  }

  /// pdfme's `validateVariables`: false when a variable of the schema is
  /// missing in [value] (or `null`). Throws for bad JSON, and for a missing
  /// variable of a `required` schema.
  static bool validateVariables(String value, RawSchema schema) {
    List<dynamic> names = _variables(schema);
    if (names.isEmpty) return true;
    Object? values;
    try {
      values = value.isEmpty ? <String, dynamic>{} : jsonDecode(value);
    } on FormatException {
      throw FormatException(
        "[@pdfme/generator] invalid JSON string '$value' for variables in "
        'field ${schema.name}',
      );
    }
    if (values == null) {
      throw ArgumentError(
        'Cannot convert undefined or null to object (field ${schema.name})',
      );
    }
    for (Object? name in names) {
      String key = PlaceholderResolver.jsString(name);
      (bool, Object?) found = _get(values, key);
      if (!found.$1 || found.$2 == null) {
        if (schema.required) {
          throw ArgumentError(
            '[@pdfme/generator] variable $key is missing for field '
            '${schema.name}',
          );
        }
        return false;
      }
    }
    return true;
  }

  /// pdfme's `resolveReadOnlyMultiVariableText`. [value] is the schema
  /// content, as `generate` passes it.
  static String readOnlyText(RawSchema schema, String value) {
    String text = schema.string('text') ?? '';
    Object? content = schema['content'];
    if (_truthy(schema['contentSnapshot'])) {
      // pdfme: `content ?? value ?? text`, and value is never null
      return schema.content ?? value;
    }
    Object? names = schema['variables'];
    bool noVariables = switch (names) {
      List<dynamic> l => l.isEmpty,
      String s => s.isEmpty,
      _ => true,
    };
    if (noVariables) return text;
    Map<dynamic, dynamic>? map = _variableMap(content) ?? _variableMap(value);
    if (map != null) return substituteVariables(text, map);
    if (value.isNotEmpty) return value;
    String contentText = schema.content ?? '';
    return contentText.isNotEmpty ? contentText : text;
  }

  /// pdfme's `tryParseVariableMap`: an object, or a JSON string of one.
  static Map<dynamic, dynamic>? _variableMap(Object? value) {
    if (value is Map) return value;
    if (value is! String || value.isEmpty) return null;
    try {
      Object? parsed = jsonDecode(value);
      return parsed is Map ? parsed : null;
    } on FormatException {
      return null;
    }
  }

  static List<dynamic> _variables(RawSchema schema) {
    Object? names = schema['variables'];
    if (names is List) return names;
    // pdfme reads `schema.variables.length` and fails without a list
    throw ArgumentError(
      'multiVariableText ${schema.name}: `variables` must be a list',
    );
  }

  static final RegExp _leftover = RegExp('{[^{}]+}');

  /// Integer keys come first in a JavaScript object (`Object.keys`).
  static final RegExp _arrayIndex = RegExp(r'^(?:0|[1-9][0-9]*)$');

  static bool _truthy(Object? v) => switch (v) {
    null || false || '' => false,
    num n => n != 0 && !n.isNaN,
    _ => true,
  };

  /// `Object.keys` of a decoded JSON value.
  static List<String> _keys(Object? value) {
    if (value == null) {
      throw ArgumentError('Cannot convert undefined or null to object');
    }
    if (value is List) {
      return <String>[for (int i = 0; i < value.length; i++) '$i'];
    }
    if (value is String) {
      return <String>[for (int i = 0; i < value.length; i++) '$i'];
    }
    if (value is! Map) return const <String>[];
    List<String> index = <String>[];
    List<String> other = <String>[];
    for (Object? k in value.keys) {
      String key = '$k';
      bool isIndex =
          _arrayIndex.hasMatch(key) &&
          key.length <= 10 &&
          int.parse(key) < 4294967295;
      (isIndex ? index : other).add(key);
    }
    index.sort((String a, String b) => int.parse(a).compareTo(int.parse(b)));
    return <String>[...index, ...other];
  }

  /// A JavaScript own property of a decoded JSON value: (found, value).
  static (bool, Object?) _get(Object? value, String key) {
    if (value is Map) {
      return value.containsKey(key) ? (true, value[key]) : (false, null);
    }
    if (value is List || value is String) {
      int length = value is List ? value.length : (value! as String).length;
      if (key == 'length') return (true, length);
      int? i = _arrayIndex.hasMatch(key) ? int.tryParse(key) : null;
      if (i == null || i >= length) return (false, null);
      return (true, value is List ? value[i] : (value! as String)[i]);
    }
    return (false, null);
  }

  /// JavaScript's `text.replace(/pattern/g, replacement)` for a plain
  /// [pattern]: `$$`, `$&`, `` $` `` and `$'` in [replacement] work.
  static String _replaceAll(String text, String pattern, String replacement) {
    if (!replacement.contains(r'$')) {
      return text.replaceAll(pattern, replacement);
    }
    return text.replaceAllMapped(pattern, (Match m) {
      StringBuffer out = StringBuffer();
      for (int i = 0; i < replacement.length; i++) {
        String c = replacement[i];
        String? next = i + 1 < replacement.length ? replacement[i + 1] : null;
        if (c != r'$' || next == null) {
          out.write(c);
          continue;
        }
        String? part = switch (next) {
          r'$' => r'$',
          '&' => m[0],
          '`' => text.substring(0, m.start),
          "'" => text.substring(m.end),
          _ => null,
        };
        if (part == null) {
          out.write(c);
        } else {
          out.write(part);
          i++;
        }
      }
      return out.toString();
    });
  }
}
