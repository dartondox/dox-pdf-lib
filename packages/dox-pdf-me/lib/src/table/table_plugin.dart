import '../plugin.dart';
import '../schema.dart';
import '../schemas/image_plugin.dart';
import '../schemas/shape_plugins.dart';
import '../text/text_box.dart';
import '../text/text_plugin.dart';
import 'table_image.dart';
import 'table_layout.dart';

/// The `table` schema type, like pdfme's table plugin.
///
/// The value is a JSON string of rows, eg. `[["Alice","Paris"]]`. Props:
/// `head`, `showHead`, `repeatHead`, `headWidthPercentages`, `tableStyles`
/// (`borderColor`, `borderWidth`), `headStyles`, `bodyStyles` (with
/// `alternateBackgroundColor`) and `columnStyles` (`alignment`,
/// `verticalAlignment`, and for image columns `cellType: "image"`,
/// `imageHeightMode` (`fixed` or `auto`) and `imageHeight`). A cell style has `fontName`, `fontSize`,
/// `characterSpacing`, `alignment`, `verticalAlignment`, `lineHeight`,
/// `fontColor`, `borderColor`, `backgroundColor`, `borderWidth` and
/// `padding` (per side, mm).
///
/// On a blank base PDF a long table grows, moves the schemas below it
/// down, and goes on over new pages (see `generate`). Like pdfme, the table
/// is not turned (`rotate`) and has no `opacity`.
class TablePlugin extends SchemaPlugin {
  const TablePlugin();

  @override
  String get type => 'table';

  static const TextPlugin _text = TextPlugin();
  static const LinePlugin _line = LinePlugin();
  static const ShapePlugin _rectangle = ShapePlugin.rectangle();
  static const ImagePlugin _image = ImagePlugin();

  @override
  Future<void> pdf(RenderProps props) async {
    Schema schema = props.schema;
    List<List<String>> body = tableBodyPart(
      parseTableBody(props.value),
      schema,
    );
    TableLayout table = await TableLayout.create(
      schema,
      body,
      props.fonts,
      props.basePdf,
    );
    double x0 = schema.x;
    double y = schema.y;
    for (TableRow row in <TableRow>[
      if (table.showHead) ...table.head,
      ...table.body,
    ]) {
      double x = x0;
      for (TableCell cell in row.cells) {
        await _cell(props, cell, x, y, row.height);
        x += cell.width;
      }
      y += row.height;
    }
    // pdfme's drawTableBorder: around the drawn rows, not the schema box
    Map<String, dynamic> tableStyles = schema['tableStyles'] is Map
        ? Map<String, dynamic>.from(
            schema['tableStyles'] as Map<dynamic, dynamic>,
          )
        : <String, dynamic>{};
    Object? lineWidth = tableStyles['borderWidth'];
    Object? lineColor = tableStyles['borderColor'];
    if (lineWidth is! num || lineWidth == 0) return;
    if (lineColor is! String || lineColor.isEmpty) return;
    await _rectangle.pdf(
      props.copyWith(
        schema: Schema(<String, dynamic>{
          'name': '',
          'type': 'rectangle',
          'borderWidth': lineWidth,
          'borderColor': lineColor,
          'color': '',
          'position': <String, double>{'x': x0, 'y': schema.y},
          'width': schema.width,
          'height': y - schema.y,
        }),
      ),
    );
  }

  /// pdfme's cell plugin: the background, the 4 border lines, then the
  /// text in the box without border and padding.
  Future<void> _cell(
    RenderProps props,
    TableCell cell,
    double x,
    double y,
    double height,
  ) async {
    Map<String, dynamic> style = cell.style;
    double width = cell.width;
    BoxSides border = BoxSides.fromJson(style['borderWidth']);
    BoxSides padding = BoxSides.fromJson(style['padding']);
    Schema box(
      double bx,
      double by,
      double bw,
      double bh,
      Map<String, dynamic> extra,
    ) => Schema(<String, dynamic>{
      ...style,
      'name': '',
      'position': <String, double>{'x': bx, 'y': by},
      'width': bw,
      'height': bh,
      ...extra,
    });
    await _rectangle.pdf(
      props.copyWith(
        schema: box(x, y, width, height, <String, dynamic>{
          'type': 'rectangle',
          'borderWidth': 0,
          'borderColor': '',
          'color': style['backgroundColor'],
        }),
      ),
    );
    Map<String, dynamic> line = <String, dynamic>{
      'type': 'line',
      'color': style['borderColor'],
    };
    for (Schema s in <Schema>[
      box(x, y, width, border.top, line),
      box(x + width - border.right, y, border.right, height, line),
      box(x, y + height - border.bottom, width, border.bottom, line),
      box(x, y, border.left, height, line),
    ]) {
      await _line.pdf(props.copyWith(schema: s));
    }
    double left = border.left + padding.left;
    double top = border.top + padding.top;
    double clamp(double v) => v < 0 ? 0 : v;
    double contentWidth = clamp(width - left - border.right - padding.right);
    double contentHeight = clamp(height - top - border.bottom - padding.bottom);
    if (cell.image) {
      // pdfme: an empty value or a value that is not a PNG or JPEG data
      // URL draws no image; an image that fails to embed is skipped
      if (cell.raw.isEmpty || tableImageSize(cell.raw) == null) return;
      try {
        await _image.pdf(
          props.copyWith(
            value: cell.raw,
            schema: Schema(<String, dynamic>{
              'name': '',
              'type': 'image',
              'content': cell.raw,
              'position': <String, double>{'x': x + left, 'y': y + top},
              'width': contentWidth,
              'height': contentHeight,
              'rotate': 0,
              'opacity': 1,
              'objectFit': 'contain',
              'objectPosition': tableImageObjectPosition(
                style['alignment'] as String?,
                style['verticalAlignment'] as String?,
              ),
            }),
          ),
        );
      } on Object {
        // ponytail: pdfme warns once on the console; nothing to draw
      }
      return;
    }
    await _text.pdf(
      props.copyWith(
        value: cell.raw,
        schema: box(
          x + left,
          y + top,
          contentWidth,
          contentHeight,
          <String, dynamic>{
            'type': 'text',
            'backgroundColor': '',
            'borderColor': '',
            'borderWidth': 0,
            'padding': 0,
          },
        ),
      ),
    );
  }
}
