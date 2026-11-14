/// One field of a pdfme template, read from its JSON map.
///
/// Sizes and positions are in millimetres, like in pdfme. Read other keys
/// of the map with [operator []], or with [string], [number] and [boolean].
class RawSchema {
  RawSchema(Map<String, dynamic> json) : json = Map<String, dynamic>.of(json);

  /// The JSON map of the schema. Extra keys (eg. `fontSize`) are here.
  final Map<String, dynamic> json;

  dynamic operator [](String key) => json[key];

  String get name => string('name') ?? '';

  String get type => string('type') ?? '';

  String? get content => string('content');

  double get x => _position('x');

  double get y => _position('y');

  double get width => number('width') ?? 0;

  double get height => number('height') ?? 0;

  /// Degrees, clockwise on the page.
  double? get rotate => number('rotate');

  double? get opacity => number('opacity');

  bool get readOnly => json['readOnly'] == true;

  bool get required => json['required'] == true;

  double _position(String key) {
    Object? p = json['position'];
    return p is Map ? _toDouble(p[key]) ?? 0 : 0;
  }

  /// A string value, or null when it is missing or not a string.
  String? string(String key) {
    Object? v = json[key];
    return v is String ? v : null;
  }

  /// A number value (an int, a double or a number in a string), or null.
  double? number(String key) => _toDouble(json[key]);

  /// True only for the JSON value `true`.
  bool boolean(String key) => json[key] == true;

  /// A copy with other values for some keys.
  RawSchema copyWith(Map<String, dynamic> changes) =>
      RawSchema(<String, dynamic>{...json, ...changes});

  static double? _toDouble(Object? v) => switch (v) {
    num n => n.toDouble(),
    String s => double.tryParse(s),
    _ => null,
  };
}
