import 'barcodes/barcode_plugin.dart';
import 'model/schema.dart';
import 'plugin.dart';
import 'raw_props.dart';
import 'schemas/circle_mark_plugin.dart';
import 'schemas/date_plugin.dart';
import 'schemas/image_plugin.dart';
import 'schemas/select_plugin.dart';
import 'schemas/shape_plugins.dart';
import 'schemas/signature_plugin.dart';
import 'svg/svg_plugin.dart';
import 'table/table_plugin.dart';
import 'text/multi_variable_text_plugin.dart';
import 'text/text_plugin.dart';

/// The plugins `generate` uses when you pass none: only `text`, like
/// pdfme's `builtInPlugins`.
const Map<String, SchemaPlugin<Schema>> defaultPlugins =
    <String, SchemaPlugin<Schema>>{'Text': TextPlugin()};

/// Every schema type of this package, by label. Pass it as `plugins` to
/// use them all (pdfme users import them from `@pdfme/schemas`).
const Map<String, SchemaPlugin<Schema>> builtInPlugins =
    <String, SchemaPlugin<Schema>>{
      'Text': TextPlugin(),
      'Image': ImagePlugin(),
      'SVG': SvgPlugin(),
      'Line': LinePlugin(),
      'Rectangle': RectanglePlugin(),
      'Ellipse': EllipsePlugin(),
      'QR Code': BarcodePlugin(BarcodeType.qrcode),
      'JAPANPOST': BarcodePlugin(BarcodeType.japanpost),
      'EAN13': BarcodePlugin(BarcodeType.ean13),
      'EAN8': BarcodePlugin(BarcodeType.ean8),
      'Code39': BarcodePlugin(BarcodeType.code39),
      'Code128': BarcodePlugin(BarcodeType.code128),
      'NW7': BarcodePlugin(BarcodeType.nw7),
      'ITF14': BarcodePlugin(BarcodeType.itf14),
      'UPCA': BarcodePlugin(BarcodeType.upca),
      'UPCE': BarcodePlugin(BarcodeType.upce),
      'GS1DataMatrix': BarcodePlugin(BarcodeType.gs1datamatrix),
      'PDF417': BarcodePlugin(BarcodeType.pdf417),
      'Date': DatePlugin(),
      'Time': TimePlugin(),
      'DateTime': DateTimePlugin(),
      'Checkbox': CheckboxPlugin(),
      'RadioGroup': RadioGroupPlugin(),
      'Select': SelectPlugin(),
      'Multi-Variable Text': MultiVariableTextPlugin(),
      'Signature': SignaturePlugin(),
      'Circle Mark': CircleMarkPlugin(),
      'Table': TablePlugin(),
    };

/// The first plugin of [plugins] for schema [type], like pdfme's
/// `pluginRegistry.findByType`. The label does not matter.
SchemaPlugin<Schema>? findPlugin(
  Map<String, SchemaPlugin<Schema>> plugins,
  String type,
) {
  for (SchemaPlugin<Schema> p in plugins.values) {
    if (p.type == type) return p;
  }
  return null;
}

/// A built-in plugin: it draws the schema JSON with the drawing code of
/// its type, so the result is the same as for the pdfme JSON.
abstract class _BuiltIn<S extends Schema> extends SchemaPlugin<S> {
  const _BuiltIn();

  RawDrawer get _drawer;

  @override
  Future<void> pdf(RenderProps<S> props) => _drawer.draw(rawProps(props));
}

/// The barcode schema types, eg. `BarcodePlugin(BarcodeType.qrcode)`.
class BarcodePlugin extends _BuiltIn<BarcodeSchema> {
  const BarcodePlugin(this.barcodeType);

  final BarcodeType barcodeType;

  @override
  String get type => barcodeType.json;

  @override
  BarcodeSchema fromJson(Map<String, Object?> json) =>
      BarcodeSchema.fromJson(json);

  @override
  RawDrawer get _drawer => BarcodeDrawer(barcodeType.json);
}

/// The `text` schema type.
class TextPlugin extends _BuiltIn<TextSchema> {
  const TextPlugin();

  @override
  String get type => 'text';

  @override
  TextSchema fromJson(Map<String, Object?> json) => TextSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const TextDrawer();
}

/// The `multiVariableText` schema type.
class MultiVariableTextPlugin extends _BuiltIn<MultiVariableTextSchema> {
  const MultiVariableTextPlugin();

  @override
  String get type => 'multiVariableText';

  @override
  MultiVariableTextSchema fromJson(Map<String, Object?> json) =>
      MultiVariableTextSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const MultiVariableTextDrawer();
}

/// The `image` schema type (PNG and JPEG).
class ImagePlugin extends _BuiltIn<ImageSchema> {
  const ImagePlugin();

  @override
  String get type => 'image';

  @override
  ImageSchema fromJson(Map<String, Object?> json) => ImageSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const ImageDrawer();
}

/// The `signature` schema type (drawn like an image).
class SignaturePlugin extends _BuiltIn<SignatureSchema> {
  const SignaturePlugin();

  @override
  String get type => 'signature';

  @override
  SignatureSchema fromJson(Map<String, Object?> json) =>
      SignatureSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const SignatureDrawer();
}

/// The `svg` schema type.
class SvgPlugin extends _BuiltIn<SvgSchema> {
  const SvgPlugin();

  @override
  String get type => 'svg';

  @override
  SvgSchema fromJson(Map<String, Object?> json) => SvgSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const SvgDrawer();
}

/// The `line` schema type.
class LinePlugin extends _BuiltIn<LineSchema> {
  const LinePlugin();

  @override
  String get type => 'line';

  @override
  LineSchema fromJson(Map<String, Object?> json) => LineSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const LineDrawer();
}

/// The `rectangle` schema type.
class RectanglePlugin extends _BuiltIn<RectangleSchema> {
  const RectanglePlugin();

  @override
  String get type => 'rectangle';

  @override
  RectangleSchema fromJson(Map<String, Object?> json) =>
      RectangleSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const ShapeDrawer.rectangle();
}

/// The `ellipse` schema type.
class EllipsePlugin extends _BuiltIn<EllipseSchema> {
  const EllipsePlugin();

  @override
  String get type => 'ellipse';

  @override
  EllipseSchema fromJson(Map<String, Object?> json) =>
      EllipseSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const ShapeDrawer.ellipse();
}

/// The `circleMark` schema type.
class CircleMarkPlugin extends _BuiltIn<CircleMarkSchema> {
  const CircleMarkPlugin();

  @override
  String get type => 'circleMark';

  @override
  CircleMarkSchema fromJson(Map<String, Object?> json) =>
      CircleMarkSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const CircleMarkDrawer();
}

/// The `checkbox` schema type.
class CheckboxPlugin extends _BuiltIn<CheckboxSchema> {
  const CheckboxPlugin();

  @override
  String get type => 'checkbox';

  @override
  CheckboxSchema fromJson(Map<String, Object?> json) =>
      CheckboxSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const CheckboxDrawer();
}

/// The `radioGroup` schema type.
class RadioGroupPlugin extends _BuiltIn<RadioGroupSchema> {
  const RadioGroupPlugin();

  @override
  String get type => 'radioGroup';

  @override
  RadioGroupSchema fromJson(Map<String, Object?> json) =>
      RadioGroupSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const RadioGroupDrawer();
}

/// The `select` schema type.
class SelectPlugin extends _BuiltIn<SelectSchema> {
  const SelectPlugin();

  @override
  String get type => 'select';

  @override
  SelectSchema fromJson(Map<String, Object?> json) =>
      SelectSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const SelectDrawer();
}

/// The `date` schema type.
class DatePlugin extends _BuiltIn<DateSchema> {
  const DatePlugin();

  @override
  String get type => 'date';

  @override
  DateSchema fromJson(Map<String, Object?> json) => DateSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const DateDrawer.date();
}

/// The `time` schema type.
class TimePlugin extends _BuiltIn<TimeSchema> {
  const TimePlugin();

  @override
  String get type => 'time';

  @override
  TimeSchema fromJson(Map<String, Object?> json) => TimeSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const DateDrawer.time();
}

/// The `dateTime` schema type.
class DateTimePlugin extends _BuiltIn<DateTimeSchema> {
  const DateTimePlugin();

  @override
  String get type => 'dateTime';

  @override
  DateTimeSchema fromJson(Map<String, Object?> json) =>
      DateTimeSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const DateDrawer.dateTime();
}

/// The `table` schema type.
class TablePlugin extends _BuiltIn<TableSchema> {
  const TablePlugin();

  @override
  String get type => 'table';

  @override
  TableSchema fromJson(Map<String, Object?> json) => TableSchema.fromJson(json);

  @override
  RawDrawer get _drawer => const TableDrawer();
}
