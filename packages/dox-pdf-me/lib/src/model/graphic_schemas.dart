part of 'schema.dart';

/// How an image fits its box.
enum ObjectFit implements _JsonEnum {
  /// The whole image shows, as big as fits.
  contain,

  /// The image fills the box. Parts outside the box are cut off.
  cover;

  @override
  String get json => name;
}

/// Where a [ObjectFit.contain] image sits in its box.
enum ObjectPosition implements _JsonEnum {
  leftTop('left top'),
  centerTop('center top'),
  rightTop('right top'),
  leftCenter('left center'),
  centerCenter('center center'),
  rightCenter('right center'),
  leftBottom('left bottom'),
  centerBottom('center bottom'),
  rightBottom('right bottom');

  const ObjectPosition(this.json);

  @override
  final String json;
}

/// The `image` schema type. The input is a PNG or JPEG file as a data URL
/// (`data:image/png;base64,...`) or base64.
class ImageSchema extends Schema {
  const ImageSchema({
    required super.name,
    required super.position,
    super.width = 40,
    super.height = 40,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    this.objectFit = ObjectFit.contain,
    this.objectPosition = ObjectPosition.centerCenter,
  });

  ImageSchema.fromJson(super.json)
    : objectFit = _enum(ObjectFit.values, json['objectFit'], ObjectFit.contain),
      objectPosition = _enum(
        ObjectPosition.values,
        json['objectPosition'],
        ObjectPosition.centerCenter,
      ),
      super.fromJson();

  @override
  String get type => 'image';

  final ObjectFit objectFit;

  final ObjectPosition objectPosition;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    'objectFit': objectFit.json,
    'objectPosition': objectPosition.json,
  };
}

/// The `signature` schema type: a PNG or JPEG image, drawn like an
/// [ImageSchema].
class SignatureSchema extends Schema {
  const SignatureSchema({
    required super.name,
    required super.position,
    super.width = 62.5,
    super.height = 37.5,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
  });

  SignatureSchema.fromJson(super.json) : super.fromJson();

  @override
  String get type => 'signature';
}

/// The `svg` schema type. The input is the SVG text.
class SvgSchema extends Schema {
  const SvgSchema({
    required super.name,
    required super.position,
    super.width = 40,
    super.height = 50,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
  });

  SvgSchema.fromJson(super.json) : super.fromJson();

  @override
  String get type => 'svg';
}

/// The `line` schema type: a line through the middle of the box. The box
/// height is the line thickness. Read-only by default.
class LineSchema extends Schema {
  const LineSchema({
    required super.name,
    required super.position,
    super.width = 50,
    super.height = 0.5,
    super.rotate,
    super.opacity,
    super.readOnly = true,
    super.required,
    super.content,
    this.color = '#000000',
  });

  /// From JSON, a missing `readOnly` is false. The constructor default is
  /// true.
  LineSchema.fromJson(super.json)
    : color = _str(json['color']) ?? '#000000',
      super.fromJson();

  @override
  String get type => 'line';

  /// A hex color.
  final String color;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    'color': color,
  };
}

/// The props of [RectangleSchema] and [EllipseSchema]. The border is drawn
/// inside the box. Read-only by default.
abstract class ShapeSchema extends Schema {
  const ShapeSchema({
    required super.name,
    required super.position,
    super.width = 62.5,
    super.height = 37.5,
    super.rotate,
    super.opacity,
    super.readOnly = true,
    super.required,
    super.content,
    this.borderWidth = 1,
    this.borderColor = '#000000',
    this.color = '',
    this.radius = 0,
  });

  ShapeSchema.fromJson(super.json)
    : borderWidth = _num(json['borderWidth']) ?? 1,
      borderColor = _str(json['borderColor']) ?? '#000000',
      color = _str(json['color']) ?? '',
      radius = _num(json['radius']) ?? 0,
      super.fromJson();

  /// mm.
  final double borderWidth;

  /// A hex color, or `''` for no border.
  final String borderColor;

  /// The fill: a hex color, or `''` for none.
  final String color;

  /// The corner radius in mm (rectangle only).
  final double radius;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    'borderWidth': _out(borderWidth),
    'borderColor': borderColor,
    'color': color,
    'radius': _out(radius),
  };
}

/// The `rectangle` schema type.
class RectangleSchema extends ShapeSchema {
  const RectangleSchema({
    required super.name,
    required super.position,
    super.width,
    super.height,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    super.borderWidth,
    super.borderColor,
    super.color,
    super.radius,
  });

  RectangleSchema.fromJson(super.json) : super.fromJson();

  @override
  String get type => 'rectangle';
}

/// The `ellipse` schema type: an ellipse in the box.
class EllipseSchema extends ShapeSchema {
  const EllipseSchema({
    required super.name,
    required super.position,
    super.width,
    super.height,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    super.borderWidth,
    super.borderColor,
    super.color,
  });

  EllipseSchema.fromJson(super.json) : super.fromJson();

  @override
  String get type => 'ellipse';
}

/// The `circleMark` schema type: a circle line around the box when the
/// input is `'true'`.
class CircleMarkSchema extends Schema {
  const CircleMarkSchema({
    required super.name,
    required super.position,
    super.width = 10,
    super.height = 10,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    this.color = '#000000',
    this.borderWidth = 1,
  });

  CircleMarkSchema.fromJson(super.json)
    : color = _str(json['color']) ?? '#000000',
      borderWidth = _num(json['borderWidth']) ?? 1,
      super.fromJson();

  @override
  String get type => 'circleMark';

  /// The line color: a hex color.
  final String color;

  /// The line width in mm.
  final double borderWidth;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    'color': color,
    'borderWidth': _out(borderWidth),
  };
}

/// The `checkbox` schema type: a checked box when the input is `'true'`.
class CheckboxSchema extends Schema {
  const CheckboxSchema({
    required super.name,
    required super.position,
    super.width = 8,
    super.height = 8,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    this.color = '#000000',
  });

  CheckboxSchema.fromJson(super.json)
    : color = _str(json['color']) ?? '#000000',
      super.fromJson();

  @override
  String get type => 'checkbox';

  /// A hex color.
  final String color;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    'color': color,
  };
}

/// The `radioGroup` schema type: a checked circle when the input is
/// `'true'`. The radio buttons of one [group] work together in the
/// designer.
class RadioGroupSchema extends Schema {
  const RadioGroupSchema({
    required super.name,
    required super.position,
    super.width = 8,
    super.height = 8,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    this.group = 'MyGroup',
    this.color = '#000000',
  });

  RadioGroupSchema.fromJson(super.json)
    : group = _str(json['group']) ?? 'MyGroup',
      color = _str(json['color']) ?? '#000000',
      super.fromJson();

  @override
  String get type => 'radioGroup';

  final String group;

  /// A hex color.
  final String color;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    'group': group,
    'color': color,
  };
}
