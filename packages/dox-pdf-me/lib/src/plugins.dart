import 'barcodes/barcode_plugin.dart';
import 'plugin.dart';
import 'schemas/circle_mark_plugin.dart';
import 'schemas/date_plugin.dart';
import 'schemas/image_plugin.dart';
import 'schemas/select_plugin.dart';
import 'schemas/shape_plugins.dart';
import 'schemas/signature_plugin.dart';
import 'svg/svg_plugin.dart';
import 'text/multi_variable_text_plugin.dart';
import 'text/text_plugin.dart';

/// The plugins `generate` uses when you pass none: only `text`, like
/// pdfme's `builtInPlugins`.
const Map<String, SchemaPlugin> defaultPlugins = <String, SchemaPlugin>{
  'Text': TextPlugin(),
};

/// Every schema type of this package, by label. Pass it as `plugins` to
/// use them all (pdfme users import them from `@pdfme/schemas`).
const Map<String, SchemaPlugin> builtInPlugins = <String, SchemaPlugin>{
  'Text': TextPlugin(),
  'Image': ImagePlugin(),
  'SVG': SvgPlugin(),
  'Line': LinePlugin(),
  'Rectangle': ShapePlugin.rectangle(),
  'Ellipse': ShapePlugin.ellipse(),
  'QR Code': BarcodePlugin('qrcode'),
  'JAPANPOST': BarcodePlugin('japanpost'),
  'EAN13': BarcodePlugin('ean13'),
  'EAN8': BarcodePlugin('ean8'),
  'Code39': BarcodePlugin('code39'),
  'Code128': BarcodePlugin('code128'),
  'NW7': BarcodePlugin('nw7'),
  'ITF14': BarcodePlugin('itf14'),
  'UPCA': BarcodePlugin('upca'),
  'UPCE': BarcodePlugin('upce'),
  'GS1DataMatrix': BarcodePlugin('gs1datamatrix'),
  'PDF417': BarcodePlugin('pdf417'),
  'Date': DatePlugin.date(),
  'Time': DatePlugin.time(),
  'DateTime': DatePlugin.dateTime(),
  'Checkbox': CheckboxPlugin(),
  'RadioGroup': RadioGroupPlugin(),
  'Select': SelectPlugin(),
  'Multi-Variable Text': MultiVariableTextPlugin(),
  'Signature': SignaturePlugin(),
  'Circle Mark': CircleMarkPlugin(),
};

/// The first plugin of [plugins] for schema [type], like pdfme's
/// `pluginRegistry.findByType`. The label does not matter.
SchemaPlugin? findPlugin(Map<String, SchemaPlugin> plugins, String type) {
  for (SchemaPlugin p in plugins.values) {
    if (p.type == type) return p;
  }
  return null;
}
