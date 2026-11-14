/// The typed schemas of a pdfme template.
library;

part 'barcode_schema.dart';
part 'date_schemas.dart';
part 'graphic_schemas.dart';
part 'table_schema.dart';
part 'text_schemas.dart';

/// One field of a template, like a pdfme schema. Each schema type has its
/// own class, eg. [TextSchema] or [BarcodeSchema].
///
/// Sizes and positions are in millimetres, like in pdfme.
///
/// A schema read with `fromJson` keeps the JSON map it was read from:
/// `toJson` gives it back with no change, also the keys this package does
/// not know. So a template from the pdfme designer goes back to the
/// designer as it was. The typed fields show the values of that map.
///
/// For your own schema type, extend this class. Give it a `fromJson`
/// constructor that calls [Schema.fromJson], and add your fields to
/// [toJson]:
///
/// ```dart
/// class StampSchema extends Schema {
///   StampSchema({required super.name, required super.position,
///       super.width = 20, super.height = 20, this.label = ''});
///
///   StampSchema.fromJson(super.json)
///       : label = json['label'] is String ? json['label'] as String : '',
///         super.fromJson();
///
///   final String label;
///
///   @override
///   String get type => 'stamp';
///
///   @override
///   Map<String, Object?> toJson() => {...super.toJson(), 'label': label};
/// }
/// ```
abstract class Schema {
  const Schema({
    required this.name,
    required this.position,
    required this.width,
    required this.height,
    this.rotate = 0,
    this.opacity = 1,
    this.readOnly = false,
    this.required = false,
    this.content,
  }) : _source = null;

  /// Reads the common keys of a pdfme schema. Values of the wrong type
  /// give the default.
  Schema.fromJson(Map<String, Object?> json)
    : name = _str(json['name']) ?? '',
      position = Position.fromJson(_map(json['position'])),
      width = _num(json['width']) ?? 0,
      height = _num(json['height']) ?? 0,
      rotate = _num(json['rotate']) ?? 0,
      opacity = _num(json['opacity']) ?? 1,
      readOnly = json['readOnly'] == true,
      required = json['required'] == true,
      content = _str(json['content']),
      _source = Map<String, Object?>.of(json);

  /// The schema type, eg. `text` or `qrcode`.
  String get type;

  /// The key of the input value of this schema.
  final String name;

  /// The top left corner on the page, in mm.
  final Position position;

  /// mm.
  final double width;

  /// mm.
  final double height;

  /// Degrees, clockwise on the page.
  final double rotate;

  /// 0 (clear) to 1 (solid).
  final double opacity;

  /// True: the schema shows its [content] and takes no input.
  final bool readOnly;

  /// True: `generate` throws when no input has a value for this schema.
  final bool required;

  /// The value of a read-only schema, or the sample value of the designer.
  final String? content;

  /// The JSON map of `fromJson`, or null.
  final Map<String, Object?>? _source;

  /// The pdfme JSON of this schema. A schema read with `fromJson` gives its
  /// JSON map back (with your fields put over it).
  Map<String, Object?> toJson() {
    Map<String, Object?>? source = _source;
    return source != null ? Map<String, Object?>.of(source) : _fields();
  }

  /// The keys of this schema, made from the fields.
  Map<String, Object?> _fields() => <String, Object?>{
    'name': name,
    'type': type,
    'position': position.toJson(),
    'width': _out(width),
    'height': _out(height),
    'rotate': _out(rotate),
    'opacity': _out(opacity),
    'readOnly': readOnly,
    'required': required,
    if (content != null) 'content': content,
  };
}

/// A schema of a type that no plugin knows. It keeps its JSON map, so
/// `toJson` gives it back. `generate` throws for it, unless a plugin of
/// [type] is passed.
class UnknownSchema extends Schema {
  UnknownSchema.fromJson(super.json)
    : type = _str(json['type']) ?? '',
      super.fromJson();

  @override
  final String type;
}

/// A point on the page, in mm from the top left corner.
class Position {
  const Position(this.x, this.y);

  /// Reads `{x, y}`. A missing value is 0.
  Position.fromJson(Map<String, Object?> json)
    : x = _num(json['x']) ?? 0,
      y = _num(json['y']) ?? 0;

  final double x;
  final double y;

  Map<String, Object?> toJson() => <String, Object?>{
    'x': _out(x),
    'y': _out(y),
  };
}

/// Sizes of the 4 sides of a box, in mm. Used for padding and borders.
class Sides {
  const Sides({this.top = 0, this.right = 0, this.bottom = 0, this.left = 0});

  /// The same size on all sides.
  const Sides.all(double size)
    : top = size,
      right = size,
      bottom = size,
      left = size;

  /// Reads `{top, right, bottom, left}`. A missing side is 0.
  Sides.fromJson(Map<String, Object?> json)
    : top = _num(json['top']) ?? 0,
      right = _num(json['right']) ?? 0,
      bottom = _num(json['bottom']) ?? 0,
      left = _num(json['left']) ?? 0;

  /// 0 on all sides.
  static const Sides zero = Sides();

  final double top;
  final double right;
  final double bottom;
  final double left;

  Map<String, Object?> toJson() => <String, Object?>{
    'top': _out(top),
    'right': _out(right),
    'bottom': _out(bottom),
    'left': _out(left),
  };

  /// pdfme's list form `[top, right, bottom, left]`.
  List<double> toList() => <double>[top, right, bottom, left];
}

/// The horizontal alignment of text.
enum Alignment implements _JsonEnum {
  left,
  center,
  right,
  justify;

  @override
  String get json => name;
}

/// The vertical alignment of text.
enum VerticalAlignment implements _JsonEnum {
  top,
  middle,
  bottom;

  @override
  String get json => name;
}

/// An enum with a pdfme JSON value.
abstract interface class _JsonEnum {
  String get json;
}

/// The value of [values] with the JSON value [json], or [fallback].
T _enum<T extends _JsonEnum>(List<T> values, Object? json, T fallback) {
  for (T v in values) {
    if (v.json == json) return v;
  }
  return fallback;
}

String? _str(Object? v) => v is String ? v : null;

/// A number, or a number in a string (pdfme JSON can have both).
double? _num(Object? v) => switch (v) {
  num n => n.toDouble(),
  String s => double.tryParse(s),
  _ => null,
};

Map<String, Object?> _map(Object? v) => v is Map
    ? <String, Object?>{
        for (MapEntry<Object?, Object?> e in v.entries) '${e.key}': e.value,
      }
    : const <String, Object?>{};

List<String> _strings(Object? v) => v is List
    ? <String>[
        for (Object? s in v)
          if (s is String) s,
      ]
    : const <String>[];

/// A whole number as an int, so the JSON shows `13`, not `13.0`.
num _out(double v) => v.isFinite && v == v.truncateToDouble() ? v.toInt() : v;
