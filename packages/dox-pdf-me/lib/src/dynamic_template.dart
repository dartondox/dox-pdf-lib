import 'dart:math' as math;

import 'schema.dart';
import 'raw_template.dart';

/// How a schema is cut into units for the page layout, like pdfme's
/// `DynamicLayoutResult`.
class DynamicLayout {
  DynamicLayout(
    List<double> heights, {
    this.avoidFirstUnitOnly = false,
    this.patch,
  }) : heights = heights.isEmpty ? const <double>[0] : heights;

  /// The height of each unit (eg. table rows), in mm.
  final List<double> heights;

  /// Do not leave unit 0 (eg. a table head) alone at the end of a page.
  final bool avoidFirstUnitOnly;

  /// Extra schema keys for the part with units [start] to [end].
  final Map<String, dynamic> Function(int start, int end, bool isSplit)? patch;
}

/// The schema types that can grow, like pdfme's `isDynamicLayoutSchema`.
/// pdfme also grows `list`, and `text` with `overflow: "expand"`; this
/// package does not support those yet.
bool isDynamicLayoutSchema(RawSchema schema) => schema.type == 'table';

const double _epsilon = 0.01;

/// The most pages one template page can grow to. pdfme has no limit; a
/// schema at a huge `y` would make millions of empty pages and hang.
const int maxDynamicPages = 100000;

/// pdfme's `getDynamicTemplate`: lays out the schemas of a blank base PDF
/// again for one input. A schema that grows moves the schemas below it
/// down, and goes on to new pages when it does not fit. Each template page
/// is laid out on its own. Returns [RawTemplate.schemas] when nothing moved.
///
/// [layout] gives the units of a dynamic schema (see
/// [isDynamicLayoutSchema]); other schemas are one unit of their height.
Future<List<List<RawSchema>>> dynamicTemplate(
  RawTemplate template,
  Future<DynamicLayout> Function(RawSchema schema) layout,
) async {
  Map<dynamic, dynamic> basePdf = template.basePdf! as Map<dynamic, dynamic>;
  List<dynamic> padding = basePdf['padding'] as List<dynamic>;
  double paddingTop = (padding[0] as num).toDouble();
  double contentHeight =
      (basePdf['height'] as num) - paddingTop - (padding[2] as num);
  // pdfme has no check here; a page with no room would never end
  if (!contentHeight.isFinite || contentHeight <= 0) {
    throw ArgumentError(
      'basePdf leaves no room for schemas: height ${basePdf['height']} '
      'minus the top and bottom padding is $contentHeight mm',
    );
  }
  List<List<RawSchema>> result = <List<RawSchema>>[];

  for (List<RawSchema> pageSchemas in template.schemas) {
    if (pageSchemas.isEmpty) {
      result.add(<RawSchema>[]);
      continue;
    }
    Map<String, int> order = <String, int>{};
    List<_Item> items = <_Item>[];
    for (int i = 0; i < pageSchemas.length; i++) {
      RawSchema s = pageSchemas[i];
      items.add(_Item(s, math.max(0, s.y - paddingTop), i));
      order[s.name] = i;
    }
    // by y; the same y keeps the template order (JS sort is stable)
    items.sort((_Item a, _Item b) {
      if ((a.baseY - b.baseY).abs() > _epsilon) {
        return a.baseY.compareTo(b.baseY);
      }
      int byOrder = (order[a.schema.name] ?? 0) - (order[b.schema.name] ?? 0);
      return byOrder != 0 ? byOrder : a.index - b.index;
    });
    for (_Item item in items) {
      item.layout = isDynamicLayoutSchema(item.schema)
          ? await layout(item.schema)
          : DynamicLayout(<double>[item.schema.height]);
    }

    List<List<RawSchema>> pages = <List<RawSchema>>[];
    double offset = 0;
    for (_Item item in items) {
      double end = _place(
        item.schema,
        item.layout,
        item.baseY + offset,
        contentHeight,
        paddingTop,
        pages,
      );
      offset = end - (item.baseY + item.schema.height);
    }
    for (int p = 0; p < pages.length; p++) {
      List<RawSchema> page = pages[p];
      List<int> idx = List<int>.generate(page.length, (int i) => i)
        ..sort((int a, int b) {
          int c = (order[page[a].name] ?? 0) - (order[page[b].name] ?? 0);
          return c != 0 ? c : a - b;
        });
      pages[p] = <RawSchema>[for (int i in idx) page[i]];
    }
    while (pages.length > 1 && pages.last.isEmpty) {
      pages.removeLast();
    }
    result.addAll(pages);
  }

  if (_unchanged(template.schemas, result)) return template.schemas;
  return result;
}

class _Item {
  _Item(this.schema, this.baseY, this.index);

  final RawSchema schema;
  final double baseY;
  final int index;
  late DynamicLayout layout;
}

/// pdfme's `placeUnitsOnPages`. Returns the y (over all pages, without the
/// padding) where the schema ends.
double _place(
  RawSchema schema,
  DynamicLayout layout,
  double startY,
  double contentHeight,
  double paddingTop,
  List<List<RawSchema>> pages,
) {
  if (!startY.isFinite) {
    throw ArgumentError(
      'schema "${schema.name}" has no finite position after the layout '
      '(y: ${schema.y}, height: ${schema.height})',
    );
  }
  List<double> heights = layout.heights;
  int unit = 0;
  double first = (startY / contentHeight).floorToDouble();
  int page = first >= maxDynamicPages
      ? maxDynamicPages
      : math.max(0, first.toInt());
  // JS `%` keeps the sign, like Dart's remainder
  double y = startY.remainder(contentHeight);
  if (y < 0) y = 0;
  double end = 0;
  bool splittable = heights.length > 1;

  while (unit < heights.length) {
    if (page >= maxDynamicPages) {
      throw ArgumentError(
        'schema "${schema.name}" would make more than $maxDynamicPages '
        'pages (y: ${schema.y})',
      );
    }
    while (pages.length <= page) {
      pages.add(<RawSchema>[]);
    }
    double spaceLeft = contentHeight - y;
    if (heights[unit] > spaceLeft + _epsilon) {
      bool atPageStart = (spaceLeft - contentHeight).abs() <= _epsilon;
      if (!atPageStart) {
        page++;
        y = 0;
        continue;
      }
      // too big even for a new page: place it anyway
    }

    double chunk = 0;
    int first = unit;
    while (unit < heights.length) {
      double h = heights[unit];
      if (y + chunk + h <= contentHeight + _epsilon) {
        chunk += h;
        unit++;
      } else {
        break;
      }
    }

    // a table head must not stay alone at the end of a page
    bool atPageTop = y <= _epsilon;
    if (layout.avoidFirstUnitOnly &&
        splittable &&
        first == 0 &&
        unit == 1 &&
        !atPageTop) {
      unit = 0;
      if (pages[page].isNotEmpty) page++;
      y = 0;
      continue;
    }

    if (unit == first) {
      chunk += heights[unit];
      unit++;
    }

    pages[page].add(
      schema.copyWith(<String, dynamic>{
        ...?layout.patch?.call(first, unit, first > 0),
        'height': chunk,
        'position': <String, double>{'x': schema.x, 'y': y + paddingTop},
      }),
    );

    y += chunk;
    if (y >= contentHeight - _epsilon) {
      page++;
      y = 0;
    }
    end = page * contentHeight + y;
  }
  return end;
}

bool _unchanged(List<List<RawSchema>> before, List<List<RawSchema>> after) {
  if (before.length != after.length) return false;
  for (int i = 0; i < before.length; i++) {
    if (before[i].length != after[i].length) return false;
    for (int j = 0; j < before[i].length; j++) {
      RawSchema a = before[i][j];
      RawSchema b = after[i][j];
      if ((a.height - b.height).abs() > _epsilon ||
          (a.y - b.y).abs() > _epsilon) {
        return false;
      }
    }
  }
  return true;
}
