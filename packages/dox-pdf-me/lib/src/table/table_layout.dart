import 'dart:convert';
import 'dart:math' as math;

import '../constants.dart';
import '../dynamic_template.dart';
import '../expression.dart';
import '../fonts/font_store.dart';
import '../schema.dart';
import '../raw_template.dart';
import '../text/text_box.dart';
import '../text/text_measure.dart';
import 'table_image.dart';

/// The `__splitRange` unit of a table part, like pdfme's `tableBody`.
const String tableBodyUnit = 'tableBody';

/// One cell of a table: its text and its style. The style uses the keys
/// of a pdfme cell schema (`fontName`, `fontSize`, `fontColor`,
/// `borderColor`, `borderWidth`, `padding`, ...).
class TableCell {
  TableCell(this.raw, this.style, {this.image = false});

  final String raw;
  final Map<String, dynamic> style;

  /// A body cell of an image column (`columnStyles.cellType: "image"`).
  /// [raw] is a PNG or JPEG data URL.
  final bool image;

  double width = 0;

  /// The height of the text (or image) plus the padding and the border,
  /// in mm.
  double contentHeight = 0;
}

/// One row of a table. All cells of a row get the row height.
class TableRow {
  TableRow(this.cells);

  final List<TableCell> cells;

  /// mm.
  double height = 0;
}

/// The columns and rows of one table schema, with their sizes in mm, like
/// pdfme's `createSingleTable` (an autoTable port).
class TableLayout {
  TableLayout._({
    required this.schema,
    required this.columnWidths,
    required this.head,
    required this.body,
    required this.showHead,
  });

  /// pdfme's `createSingleTable`. [body] is the part of the body this
  /// schema draws (see [tableBodyRange]). [basePdf] is the `basePdf` of
  /// the template (a blank page limits the height of `auto` images).
  static Future<TableLayout> create(
    RawSchema schema,
    List<List<String>> body,
    FontStore fonts,
    Object? basePdf,
  ) async {
    int start = tableBodyRange(schema)?.start ?? 0;
    Map<String, dynamic> bodyStyles = _map(schema['bodyStyles']);
    Object? background = bodyStyles['backgroundColor'];
    Object? alternate = bodyStyles['alternateBackgroundColor'];
    // pdfme: a part that starts on an odd row swaps the two colors, so the
    // rows keep their colors over pages
    if (start.isOdd) {
      bodyStyles = <String, dynamic>{
        ...bodyStyles,
        'backgroundColor': alternate,
        'alternateBackgroundColor': background,
      };
      (background, alternate) = (alternate, background);
    }
    bool showHead =
        schema['showHead'] != false &&
        (schema['__isSplit'] != true || schema['repeatHead'] == true);

    Object? headJson = schema['head'];
    List<String> headRow = headJson is List
        ? <String>[for (Object? h in headJson) _cellText(h)]
        : const <String>[];
    // pdfme: the columns are the head cells (or the first body row when
    // there is no head)
    int columnCount = headJson is List
        ? headRow.length
        : (body.isEmpty ? 0 : body.first.length);
    List<double> columnWidths = _columnWidths(schema, columnCount);
    Map<int, Object?> alignments = _columnMap(schema, 'alignment');
    Map<int, Object?> verticalAlignments = _columnMap(
      schema,
      'verticalAlignment',
    );
    // pdfme's normalizeTableCellType: a set value that is not `text` or
    // `image` is `text`
    Map<int, Object?> cellTypes = _columnMap(schema, 'cellType');
    Map<int, Object?> imageModes = _columnMap(schema, 'imageHeightMode');
    Map<int, Object?> imageHeights = _columnMap(schema, 'imageHeight');

    TableRow row(
      List<String> raw,
      Map<String, dynamic> section, {
      bool body = false,
      bool even = false,
    }) {
      if (raw.length < columnCount) {
        // pdfme reads the missing cell as undefined and fails on it
        throw ArgumentError(
          "Cannot read properties of undefined (reading 'split')",
        );
      }
      return TableRow(<TableCell>[
        for (int c = 0; c < columnCount; c++)
          TableCell(raw[c], <String, dynamic>{
            ..._defaultStyle(fonts.fallbackName),
            ..._sectionStyle(section),
            // pdfme: even body rows (0, 2, ...) take the alternate
            // color, also when it is not set
            if (even) 'backgroundColor': alternate,
            if (alignments[c] case String a) 'alignment': a,
            if (verticalAlignments[c] case String v) 'verticalAlignment': v,
            if (imageModes[c] case String m when m == 'fixed' || m == 'auto')
              'imageHeightMode': m,
            if (imageHeights[c] case num h when h.isFinite) 'imageHeight': h,
          }, image: body && cellTypes[c] == 'image')..width = columnWidths[c],
      ]);
    }

    Map<String, dynamic> headStyles = _map(schema['headStyles']);
    TableLayout table = TableLayout._(
      schema: schema,
      columnWidths: columnWidths,
      head: <TableRow>[row(headRow, headStyles)],
      body: <TableRow>[
        for (int r = 0; r < body.length; r++)
          row(body[r], bodyStyles, body: true, even: r.isEven),
      ],
      showHead: showHead,
    );
    await table._fitContent(fonts, basePdf);
    return table;
  }

  final RawSchema schema;

  /// mm, one per column.
  final List<double> columnWidths;

  /// The head rows (pdfme has one head row). They are measured also when
  /// they are not drawn.
  final List<TableRow> head;
  final List<TableRow> body;

  /// The head is drawn: `showHead` is not false, and this is the first part
  /// of the table or `repeatHead` is true.
  final bool showHead;

  List<TableRow> get allRows => <TableRow>[...head, ...body];

  double get headHeight =>
      head.fold(0, (double sum, TableRow r) => sum + r.height);

  double get bodyHeight =>
      body.fold(0, (double sum, TableRow r) => sum + r.height);

  /// pdfme's `fitContent`: wraps the text of each cell and sets the row
  /// heights. A cell is `lines * fontSize * lineHeight` plus the padding
  /// and the border. An image cell is its image height (see
  /// [tableImageContentHeight]) plus the padding and the border.
  Future<void> _fitContent(FontStore fonts, Object? basePdf) async {
    Map<String, TextMeasure> measures = <String, TextMeasure>{};
    for (TableRow row in allRows) {
      for (TableCell cell in row.cells) {
        RawSchema s = RawSchema(cell.style);
        BoxSides border = BoxSides.fromJson(s['borderWidth']);
        BoxSides padding = BoxSides.fromJson(s['padding']);
        double contentWidth = math.max(
          0,
          cell.width -
              border.left -
              border.right -
              padding.left -
              padding.right,
        );
        double vertical =
            border.top + border.bottom + padding.top + padding.bottom;
        if (cell.image) {
          double height = tableImageContentHeight(
            value: cell.raw,
            mode: s.string('imageHeightMode'),
            imageHeight: s.number('imageHeight'),
            contentWidth: contentWidth,
          );
          if (s.string('imageHeightMode') == 'auto') {
            double? limit = _autoImageLimit(basePdf, vertical);
            if (limit != null) height = math.min(height, math.max(0, limit));
          }
          cell.contentHeight = height + vertical;
          if (cell.contentHeight > row.height) row.height = cell.contentHeight;
          continue;
        }
        String fontName = fonts.resolve(s.string('fontName'));
        TextMeasure measure = measures[fontName] ??= TextMeasure(
          await fonts.embed(fontName),
          fonts.metrics(fontName),
        );
        double fontSize = s.number('fontSize') ?? 0;
        int lines = measure
            .wrap(
              cell.raw,
              fontSize,
              s.number('characterSpacing') ?? 0,
              mm2pt(contentWidth),
            )
            .length;
        cell.contentHeight =
            lines * pt2mm(fontSize) * (s.number('lineHeight') ?? 0) + vertical;
        if (cell.contentHeight > row.height) row.height = cell.contentHeight;
      }
    }
  }

  /// pdfme's `autoImageHeightLimit`: an `auto` image fits on one page
  /// below the head. Null for a PDF base (it gets no new pages).
  double? _autoImageLimit(Object? basePdf, double vertical) {
    if (!_isBlank(basePdf)) return null;
    Map<dynamic, dynamic> b = basePdf! as Map<dynamic, dynamic>;
    List<dynamic> padding = b['padding'] as List<dynamic>;
    double pageContentHeight =
        ((b['height'] as num) - (padding[0] as num) - (padding[2] as num))
            .toDouble();
    // the head rows are measured first; the limit uses the template
    // showHead, also for a part that does not draw the head
    double head = schema['showHead'] != false ? headHeight : 0.0;
    return pageContentHeight - head - vertical - tableImageAutoSafetyMargin;
  }

  static bool _isBlank(Object? basePdf) =>
      RawTemplate(basePdf: basePdf, schemas: const <List<RawSchema>>[]).isBlank;

  /// pdfme's `getDynamicHeightsForTable`: the height of each unit of the
  /// table for the page layout. Unit 0 is the head (0 when `showHead` is
  /// not true), then one unit per body row. With `repeatHead` on a blank
  /// base PDF, a row that starts a new page also holds the head height.
  List<double> dynamicHeights(Object? basePdf) {
    bool templateShowHead = schema['showHead'] == true;
    List<double> base = templateShowHead
        ? <double>[for (TableRow r in allRows) r.height]
        : <double>[0, for (TableRow r in body) r.height];
    double headerHeight = templateShowHead ? headHeight : 0;
    if (schema['repeatHead'] != true ||
        !_isBlank(basePdf) ||
        headerHeight <= 0) {
      return base;
    }
    Map<dynamic, dynamic> b = basePdf! as Map<dynamic, dynamic>;
    List<dynamic> padding = b['padding'] as List<dynamic>;
    double paddingTop = (padding[0] as num).toDouble();
    double pageContentHeight =
        (b['height'] as num) - paddingTop - (padding[2] as num);
    double pageStartY(int index) => index * pageContentHeight + paddingTop;

    int initialPage = math.max(
      0,
      ((schema.y - paddingTop) / pageContentHeight).floor(),
    );
    int headRowCount = templateShowHead ? head.length : 0;
    const double safetyMargin = 0.5;
    const double epsilon = 0.01;

    int page = initialPage;
    double y = schema.y;
    int rowsOnPage = 0;
    // the head moves with the first body row: that row must not also get
    // a repeated head
    bool headerTravelsWithBody = false;
    List<double> result = <double>[];

    for (int i = 0; i < base.length; i++) {
      bool isBodyRow = i >= headRowCount;
      double rowHeight = base[i];
      while (true) {
        double start = pageStartY(page);
        double remaining = start + pageContentHeight - y;
        bool needsHeader =
            isBodyRow &&
            rowsOnPage == 0 &&
            page > initialPage &&
            !headerTravelsWithBody;
        double total = rowHeight + (needsHeader ? headerHeight : 0);

        if (total > remaining - safetyMargin + epsilon) {
          if (rowsOnPage == 0 && (y - start).abs() < safetyMargin) {
            result.add(total);
            y += total;
            rowsOnPage++;
            headerTravelsWithBody = false;
            break;
          }
          bool headerWouldBeAlone =
              !headerTravelsWithBody &&
              page == initialPage &&
              isBodyRow &&
              headRowCount > 0 &&
              result.length == headRowCount &&
              rowsOnPage == headRowCount;
          page++;
          if (headerWouldBeAlone) {
            headerTravelsWithBody = true;
            y = pageStartY(page) + headerHeight;
            rowsOnPage = headRowCount;
          } else {
            headerTravelsWithBody = false;
            y = pageStartY(page);
            rowsOnPage = 0;
          }
          continue;
        }

        result.add(total);
        y += total;
        rowsOnPage++;
        if (isBodyRow) headerTravelsWithBody = false;
        if (y >= start + pageContentHeight - safetyMargin) {
          page++;
          y = pageStartY(page);
          rowsOnPage = 0;
          headerTravelsWithBody = false;
        }
        break;
      }
    }
    return result;
  }

  /// pdfme's `getDefaultCellStyles` of the generator (`cellStyles`).
  static Map<String, dynamic> _defaultStyle(String fallbackFont) =>
      <String, dynamic>{
        'fontName': fallbackFont,
        'backgroundColor': '',
        'fontColor': '#000000',
        'lineHeight': 1,
        'characterSpacing': 0,
        'alignment': 'left',
        'verticalAlignment': 'middle',
        'fontSize': 10,
        'padding': _box(5),
        'borderColor': '#000000',
        'borderWidth': _box(0),
      };

  static const List<String> _styleKeys = <String>[
    'fontName',
    'alignment',
    'verticalAlignment',
    'fontSize',
    'lineHeight',
    'characterSpacing',
    'backgroundColor',
    'fontColor',
    'borderColor',
    'borderWidth',
    'padding',
  ];

  /// pdfme's `mapCellStyle`: the set keys of `headStyles` or `bodyStyles`.
  static Map<String, dynamic> _sectionStyle(Map<String, dynamic> styles) =>
      <String, dynamic>{
        for (String key in _styleKeys)
          if (styles[key] != null) key: styles[key],
      };

  static Map<String, double> _box(double v) => <String, double>{
    'top': v,
    'right': v,
    'bottom': v,
    'left': v,
  };

  /// `width * headWidthPercentages[i] / 100`. pdfme gives a column
  /// without a percentage no width (NaN), and pdf-lib then fails on it.
  /// This port throws a clear error instead.
  static List<double> _columnWidths(RawSchema schema, int count) {
    Object? json = schema['headWidthPercentages'];
    return <double>[
      for (int i = 0; i < count; i++)
        if (json is List && i < json.length && json[i] is num)
          schema.width * (json[i] as num) / 100
        else
          throw ArgumentError(
            '[@pdfme/schemas/table] headWidthPercentages has no width for '
            'column $i of table "${schema.name}"',
          ),
    ];
  }

  /// A `columnStyles` map like `{"alignment": {"0": "right"}}`.
  static Map<int, Object?> _columnMap(RawSchema schema, String key) {
    Object? map = _map(schema['columnStyles'])[key];
    return <int, Object?>{
      if (map is Map)
        for (MapEntry<dynamic, dynamic> e in map.entries)
          if (int.tryParse('${e.key}') case int i) i: e.value,
    };
  }

  static Map<String, dynamic> _map(Object? json) =>
      json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{};

  static String _cellText(Object? v) =>
      v is String ? v : PlaceholderResolver.jsString(v);
}

/// pdfme's `getDynamicLayoutForTable`: the units of table [schema] with
/// [value] for the page layout. A part gets the `__splitRange` of its body
/// rows (unit 0 is the head) and `__isSplit`.
Future<DynamicLayout> tableDynamicLayout(
  RawSchema schema,
  String value,
  FontStore fonts,
  Object? basePdf,
) async {
  TableLayout table = await TableLayout.create(
    schema,
    parseTableBody(value),
    fonts,
    basePdf,
  );
  return DynamicLayout(
    table.dynamicHeights(basePdf),
    avoidFirstUnitOnly: true,
    patch: (int start, int end, bool isSplit) => <String, dynamic>{
      '__splitRange': <String, dynamic>{
        'unit': tableBodyUnit,
        'start': start == 0 ? 0 : start - 1,
        'end': end - 1,
      },
      '__isSplit': isSplit,
    },
  );
}

/// pdfme's `getBody`: the rows of a table value (a JSON string of rows).
/// `''` is no rows. Cells that are not strings become strings, like
/// pdfme's `String(cell)`.
List<List<String>> parseTableBody(String value) {
  try {
    Object? json = jsonDecode(value.isEmpty ? '[]' : value);
    if (json is! List) return const <List<String>>[];
    return <List<String>>[
      for (Object? row in json)
        if (row is List)
          <String>[for (Object? c in row) TableLayout._cellText(c)]
        else
          const <String>[],
    ];
  } on FormatException catch (e) {
    // pdfme: JSON.parse throws a SyntaxError
    throw ArgumentError(
      '[@pdfme/schemas/table] the table value is not valid JSON: ${e.message}',
    );
  } on StackOverflowError {
    // a cell that is a deeply nested list turns into text recursively
    throw ArgumentError(
      '[@pdfme/schemas/table] the table value is nested too deep',
    );
  }
}

/// The `{start, end}` of a table part, from its `__splitRange`.
({int start, int? end})? tableBodyRange(RawSchema schema) {
  Object? range = schema['__splitRange'];
  if (range is! Map || range['unit'] != tableBodyUnit) return null;
  Object? start = range['start'];
  Object? end = range['end'];
  return (
    start: start is num ? start.toInt() : 0,
    end: end is num ? end.toInt() : null,
  );
}

/// The part of [body] this schema draws.
List<List<String>> tableBodyPart(List<List<String>> body, RawSchema schema) {
  ({int start, int? end})? range = tableBodyRange(schema);
  if (range == null) return body;
  int start = math.min(range.start, body.length);
  int end = math.min(range.end ?? body.length, body.length);
  return body.sublist(start, math.max(start, end));
}
