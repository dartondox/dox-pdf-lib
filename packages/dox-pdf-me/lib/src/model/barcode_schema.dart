part of 'schema.dart';

/// The barcode types of pdfme. The value is the schema `type`.
enum BarcodeType implements _JsonEnum {
  /// QR code.
  qrcode(30, 30),
  japanpost(80, 7.2),
  ean13(40, 16),
  ean8(40, 20),
  code39(40, 20),
  code128(40, 20),
  nw7(40, 20),
  itf14(40, 12),
  upca(40, 16),
  upce(40, 20),
  gs1datamatrix(30, 30),
  pdf417(40, 11.65);

  const BarcodeType(this.width, this.height);

  /// The default box width in mm, like the pdfme designer.
  final double width;

  /// The default box height in mm, like the pdfme designer.
  final double height;

  /// True for the 2D codes (QR code, Data Matrix, PDF417). They have no
  /// text under the bars.
  bool get is2D => this == qrcode || this == gs1datamatrix || this == pdf417;

  @override
  String get json => name;
}

/// A barcode or QR code schema. [barcodeType] picks the code, eg.
/// [BarcodeType.qrcode]. The input is the text of the code.
///
/// ```dart
/// BarcodeSchema(
///   name: 'link',
///   barcodeType: BarcodeType.qrcode,
///   position: Position(20, 40),
/// )
/// ```
class BarcodeSchema extends Schema {
  /// The box size defaults to the size of the pdfme designer for
  /// [barcodeType].
  BarcodeSchema({
    required super.name,
    required this.barcodeType,
    required super.position,
    double? width,
    double? height,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    this.backgroundColor = '#ffffff',
    this.barColor = '#000000',
    this.textColor = '#000000',
    this.includetext = true,
  }) : super(
         width: width ?? barcodeType.width,
         height: height ?? barcodeType.height,
       );

  /// Reads a barcode schema. An unknown `type` reads as
  /// [BarcodeType.qrcode], and `toJson` keeps the real type.
  BarcodeSchema.fromJson(super.json)
    : barcodeType = _enum(BarcodeType.values, json['type'], BarcodeType.qrcode),
      backgroundColor = _str(json['backgroundColor']) ?? '#ffffff',
      barColor = _str(json['barColor']) ?? '#000000',
      textColor = _str(json['textColor']) ?? '#000000',
      includetext =
          !json.containsKey('includetext') || json['includetext'] == true,
      super.fromJson();

  @override
  String get type => barcodeType.json;

  final BarcodeType barcodeType;

  /// A hex color, or `''` for none.
  final String backgroundColor;

  /// A hex color.
  final String barColor;

  /// The color of the text under the bars (linear codes only).
  final String textColor;

  /// Shows the text under the bars (linear codes only).
  final bool includetext;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    'backgroundColor': backgroundColor,
    'barColor': barColor,
    if (!barcodeType.is2D) 'textColor': textColor,
    if (!barcodeType.is2D) 'includetext': includetext,
  };
}
