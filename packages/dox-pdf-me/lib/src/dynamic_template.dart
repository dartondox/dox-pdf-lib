import 'dart:math' as math;

import 'schema.dart';
import 'template.dart';

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
bool isDynamicLayoutSchema(Schema schema) => schema.type == 'table';

const double _epsilon = 0.01;

/// pdfme's `getDynamicTemplate`: lays out the schemas of a blank base PDF
/// again for one input. A schema that grows moves the schemas below it
/// down, and goes on to new pages when it does not fit. Each template page
/// is laid out on its own. Returns [Template.schemas] when nothing moved.
///
/// [layout] gives the units of a dynamic schema (see
/// [isDynamicLayoutSchema]); other schemas are one unit of their height.
Future<List<List<Schema>>> dynamicTemplate(
  Template template,
  Future<DynamicLayout> Function(Schema schema) layout,
) async {
  Map<dynamic, dynamic> basePdf = template.basePdf! as Map<dynamic, dynamic>;
  List<dynamic> padding = basePdf['padding'] as List<dynamic>;
  double paddingTop = (padding[0] as num).toDouble();
  double contentHeight =
      (basePdf['height'] as num) - paddingTop - (padding[2] as num);
  List<List<Schema>> result = <List<Schema>>[];

  for (List<Schema> pageSchemas in template.schemas) {
    if (pageSchemas.isEmpty) {
      result.add(<Schema>[]);
      continue;
    }
    Map<String, int> order = <String, int>{};
    List<_Item> items = <_Item>[];
    for (int i = 0; i < pageSchemas.length; i++) {
      Schema s = pageSchemas[i];
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

    List<List<Schema>> pages = <List<Schema>>[];
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
      List<Schema> page = pages[p];
      List<int> idx = List<int>.generate(page.length, (int i) => i)
        ..sort((int a, int b) {
          int c = (order[page[a].name] ?? 0) - (order[page[b].name] ?? 0);
          return c != 0 ? c : a - b;
        });
      pages[p] = <Schema>[for (int i in idx) page[i]];
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

  final Schema schema;
  final double baseY;
  final int index;
  late DynamicLayout layout;
}

/// pdfme's `placeUnitsOnPages`. Returns the y (over all pages, without the
/// padding) where the schema ends.
double _place(
  Schema schema,
  DynamicLayout layout,
  double startY,
  double contentHeight,
  double paddingTop,
  List<List<Schema>> pages,
) {
  List<double> heights = layout.heights;
  int unit = 0;
  int page = math.max(0, (startY / contentHeight).floor());
  // JS `%` keeps the sign, like Dart's remainder
  double y = startY.remainder(contentHeight);
  if (y < 0) y = 0;
  double end = 0;
  bool splittable = heights.length > 1;

  while (unit < heights.length) {
    while (pages.length <= page) {
      pages.add(<Schema>[]);
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

bool _unchanged(List<List<Schema>> before, List<List<Schema>> after) {
  if (before.length != after.length) return false;
  for (int i = 0; i < before.length; i++) {
    if (before[i].length != after[i].length) return false;
    for (int j = 0; j < before[i].length; j++) {
      Schema a = before[i][j];
      Schema b = after[i][j];
      if ((a.height - b.height).abs() > _epsilon ||
          (a.y - b.y).abs() > _epsilon) {
        return false;
      }
    }
  }
  return true;
}
