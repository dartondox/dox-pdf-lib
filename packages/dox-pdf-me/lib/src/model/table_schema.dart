part of 'schema.dart';

/// What a table column shows.
enum TableCellType implements _JsonEnum {
  text,

  /// PNG and JPEG data URLs, fitted in the cell. The head stays text.
  image;

  @override
  String get json => name;
}

/// The height of the images of an image column.
enum ImageHeightMode implements _JsonEnum {
  /// `imageHeight` mm (20 by default).
  fixed,

  /// Follows the image ratio, and fits on one page.
  auto;

  @override
  String get json => name;
}

/// The outer border of a table.
class TableStyles {
  const TableStyles({this.borderColor = '#000000', this.borderWidth = 0.3});

  TableStyles.fromJson(Map<String, Object?> json)
    : borderColor = _str(json['borderColor']) ?? '#000000',
      borderWidth = _num(json['borderWidth']) ?? 0.3;

  /// A hex color, or `''` for none.
  final String borderColor;

  /// mm.
  final double borderWidth;

  Map<String, Object?> toJson() => <String, Object?>{
    'borderColor': borderColor,
    'borderWidth': _out(borderWidth),
  };
}

/// The style of the head cells or the body cells of a table.
class CellStyle {
  /// The head style of the pdfme designer: white text on blue.
  const CellStyle.head({
    this.fontName,
    this.alignment = Alignment.left,
    this.verticalAlignment = VerticalAlignment.middle,
    this.fontSize = 13,
    this.lineHeight = 1,
    this.characterSpacing = 0,
    this.fontColor = '#ffffff',
    this.backgroundColor = '#2980ba',
    this.borderColor = '',
    this.borderWidth = Sides.zero,
    this.padding = const Sides.all(5),
    this.alternateBackgroundColor,
  });

  /// The body style of the pdfme designer: black text, gray lines and a
  /// light gray background on every second row.
  const CellStyle.body({
    this.fontName,
    this.alignment = Alignment.left,
    this.verticalAlignment = VerticalAlignment.middle,
    this.fontSize = 13,
    this.lineHeight = 1,
    this.characterSpacing = 0,
    this.fontColor = '#000000',
    this.backgroundColor = '',
    this.borderColor = '#888888',
    this.borderWidth = const Sides.all(0.1),
    this.padding = const Sides.all(5),
    this.alternateBackgroundColor = '#f5f5f5',
  });

  /// Reads a cell style. When a key is missing, the getter shows the
  /// [CellStyle.head] value when [head] is true, else the [CellStyle.body]
  /// value. The PDF is drawn from the source JSON, and the drawer uses its
  /// own fallback there (`_defaultStyle` in `table_layout.dart`: `fontSize`
  /// 10, `borderColor` `#000000`, `borderWidth` 0). The two differ only for
  /// a missing key. The pdfme designer always writes every key.
  ///
  /// `alternateBackgroundColor` is null when the key is missing. It does
  /// not take the body default.
  CellStyle.fromJson(Map<String, Object?> json, {bool head = false})
    : fontName = _str(json['fontName']),
      alignment = _enum(Alignment.values, json['alignment'], Alignment.left),
      verticalAlignment = _enum(
        VerticalAlignment.values,
        json['verticalAlignment'],
        VerticalAlignment.middle,
      ),
      fontSize = _num(json['fontSize']) ?? 13,
      lineHeight = _num(json['lineHeight']) ?? 1,
      characterSpacing = _num(json['characterSpacing']) ?? 0,
      fontColor = _str(json['fontColor']) ?? (head ? '#ffffff' : '#000000'),
      backgroundColor =
          _str(json['backgroundColor']) ?? (head ? '#2980ba' : ''),
      borderColor = _str(json['borderColor']) ?? (head ? '' : '#888888'),
      borderWidth = json['borderWidth'] is Map
          ? Sides.fromJson(_map(json['borderWidth']))
          : (head ? Sides.zero : const Sides.all(0.1)),
      padding = json['padding'] is Map
          ? Sides.fromJson(_map(json['padding']))
          : const Sides.all(5),
      alternateBackgroundColor = _str(json['alternateBackgroundColor']);

  /// A font name of the `font` option. Null: the fallback font.
  final String? fontName;

  final Alignment alignment;

  final VerticalAlignment verticalAlignment;

  /// Points.
  final double fontSize;

  /// A factor of the font size.
  final double lineHeight;

  /// Points between letters.
  final double characterSpacing;

  /// A hex color.
  final String fontColor;

  /// A hex color, or `''` for none.
  final String backgroundColor;

  /// A hex color, or `''` for none.
  final String borderColor;

  /// mm on each side.
  final Sides borderWidth;

  /// mm on each side.
  final Sides padding;

  /// The background of every second body row: a hex color, or `''` for
  /// none. Body cells only.
  final String? alternateBackgroundColor;

  Map<String, Object?> toJson() => <String, Object?>{
    if (fontName != null) 'fontName': fontName,
    'alignment': alignment.json,
    'verticalAlignment': verticalAlignment.json,
    'fontSize': _out(fontSize),
    'lineHeight': _out(lineHeight),
    'characterSpacing': _out(characterSpacing),
    'fontColor': fontColor,
    'backgroundColor': backgroundColor,
    'borderColor': borderColor,
    'borderWidth': borderWidth.toJson(),
    'padding': padding.toJson(),
    if (alternateBackgroundColor != null)
      'alternateBackgroundColor': alternateBackgroundColor,
  };
}

/// Styles of single columns, by column index (0 is the first column).
class ColumnStyles {
  const ColumnStyles({
    this.alignment = const <int, Alignment>{},
    this.verticalAlignment = const <int, VerticalAlignment>{},
    this.cellType = const <int, TableCellType>{},
    this.imageHeightMode = const <int, ImageHeightMode>{},
    this.imageHeight = const <int, double>{},
  });

  ColumnStyles.fromJson(Map<String, Object?> json)
    : alignment = _columns(
        json['alignment'],
        (Object? v) => _enum(Alignment.values, v, Alignment.left),
      ),
      verticalAlignment = _columns(
        json['verticalAlignment'],
        (Object? v) =>
            _enum(VerticalAlignment.values, v, VerticalAlignment.middle),
      ),
      cellType = _columns(
        json['cellType'],
        (Object? v) => _enum(TableCellType.values, v, TableCellType.text),
      ),
      imageHeightMode = _columns(
        json['imageHeightMode'],
        (Object? v) => _enum(ImageHeightMode.values, v, ImageHeightMode.fixed),
      ),
      imageHeight = _columns(json['imageHeight'], (Object? v) => _num(v) ?? 20);

  final Map<int, Alignment> alignment;
  final Map<int, VerticalAlignment> verticalAlignment;
  final Map<int, TableCellType> cellType;
  final Map<int, ImageHeightMode> imageHeightMode;

  /// mm, for [ImageHeightMode.fixed].
  final Map<int, double> imageHeight;

  Map<String, Object?> toJson() => <String, Object?>{
    if (alignment.isNotEmpty)
      'alignment': <String, Object?>{
        for (MapEntry<int, Alignment> e in alignment.entries)
          '${e.key}': e.value.json,
      },
    if (verticalAlignment.isNotEmpty)
      'verticalAlignment': <String, Object?>{
        for (MapEntry<int, VerticalAlignment> e in verticalAlignment.entries)
          '${e.key}': e.value.json,
      },
    if (cellType.isNotEmpty)
      'cellType': <String, Object?>{
        for (MapEntry<int, TableCellType> e in cellType.entries)
          '${e.key}': e.value.json,
      },
    if (imageHeightMode.isNotEmpty)
      'imageHeightMode': <String, Object?>{
        for (MapEntry<int, ImageHeightMode> e in imageHeightMode.entries)
          '${e.key}': e.value.json,
      },
    if (imageHeight.isNotEmpty)
      'imageHeight': <String, Object?>{
        for (MapEntry<int, double> e in imageHeight.entries)
          '${e.key}': _out(e.value),
      },
  };

  static Map<int, T> _columns<T>(Object? json, T Function(Object?) read) =>
      <int, T>{
        for (MapEntry<String, Object?> e in _map(json).entries)
          if (int.tryParse(e.key) case int i) i: read(e.value),
      };
}

/// The `table` schema type. The input is a JSON string of rows, eg.
/// `[["Alice", "Paris"], ["Bob", "Rome"]]`: use `jsonEncode(rows)`.
///
/// On a blank base PDF, a table taller than its box grows: the schemas
/// below move down, and the table goes on over new pages.
class TableSchema extends Schema {
  const TableSchema({
    required super.name,
    required super.position,
    super.width = 150,
    super.height = 20,
    super.rotate,
    super.opacity,
    super.readOnly,
    super.required,
    super.content,
    this.head = const <String>['Name', 'City', 'Description'],
    List<double>? headWidthPercentages,
    this.showHead = true,
    this.repeatHead = false,
    this.tableStyles = const TableStyles(),
    this.headStyles = const CellStyle.head(),
    this.bodyStyles = const CellStyle.body(),
    this.columnStyles = const ColumnStyles(),
  }) : _widths = headWidthPercentages;

  TableSchema.fromJson(super.json)
    : head = _strings(json['head']),
      _widths = json['headWidthPercentages'] is List<Object?>
          ? <double>[
              for (Object? p in json['headWidthPercentages']! as List<Object?>)
                _num(p) ?? 0,
            ]
          : null,
      showHead = json['showHead'] != false,
      repeatHead = json['repeatHead'] == true,
      tableStyles = TableStyles.fromJson(_map(json['tableStyles'])),
      headStyles = CellStyle.fromJson(_map(json['headStyles']), head: true),
      bodyStyles = CellStyle.fromJson(_map(json['bodyStyles'])),
      columnStyles = ColumnStyles.fromJson(_map(json['columnStyles'])),
      super.fromJson();

  @override
  String get type => 'table';

  /// The head text of each column. From JSON, a missing `head` is empty.
  final List<String> head;

  final List<double>? _widths;

  /// The width of each column, in percent of the table width. One value
  /// per column, eg. `[30, 70]`. Not set: `[30, 30, 40]` for the default
  /// head, else the same width for each column.
  ///
  /// From JSON, a missing `headWidthPercentages` still shows that split
  /// here, but generating the PDF throws, like pdfme. Only a typed
  /// `TableSchema(...)` built in Dart gets the split when it is drawn.
  List<double> get headWidthPercentages =>
      _widths ??
      (head.length == 3 &&
              head[0] == 'Name' &&
              head[1] == 'City' &&
              head[2] == 'Description'
          ? const <double>[30, 30, 40]
          : List<double>.filled(head.length, 100 / head.length));

  final bool showHead;

  /// Shows the head again on each new page.
  final bool repeatHead;

  final TableStyles tableStyles;

  final CellStyle headStyles;

  final CellStyle bodyStyles;

  final ColumnStyles columnStyles;

  @override
  Map<String, Object?> _fields() => <String, Object?>{
    ...super._fields(),
    'head': head,
    'headWidthPercentages': <num>[
      for (double p in headWidthPercentages) _out(p),
    ],
    'showHead': showHead,
    'repeatHead': repeatHead,
    'tableStyles': tableStyles.toJson(),
    'headStyles': headStyles.toJson(),
    'bodyStyles': bodyStyles.toJson(),
    'columnStyles': columnStyles.toJson(),
  };
}
