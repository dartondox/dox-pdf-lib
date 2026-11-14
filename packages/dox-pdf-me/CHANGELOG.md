## Unreleased

- **Breaking: a typed API.** Each schema type has its own class with
  typed fields and the pdfme defaults: `TextSchema`, `BarcodeSchema` (with
  `BarcodeType.qrcode`, ...), `TableSchema`, and so on. Fixed choices are
  enums (`Alignment`, `VerticalAlignment`, `ObjectFit`, ...). You can now
  build a template in Dart with no frontend.
  - `generate` takes a `Template`, not a `Map`. Read pdfme JSON with
    `Template.fromJson(json)` (both pdfme formats, like before).
  - `inputs` is a `List<Map<String, String>>`. Every pdfme input is a
    string. A table takes a JSON string of rows: use `jsonEncode(rows)`.
    A list or a map as input is no longer taken.
  - `options` is a `GenerateOptions`. Read the pdfme options JSON with
    `GenerateOptions.fromJson(json)`. `colorType` is a `ColorType` enum,
    and `extra` is gone.
  - `Template.basePdf` is a `BasePdf`: `BlankPdf(width, height, padding,
    staticSchema)` or `PdfFile(bytes)`.
  - A plugin is a `SchemaPlugin<S>`. It names its own schema class and
    reads it from JSON (`fromJson`), and `pdf` gets a `RenderProps<S>`
    with the typed schema. `RenderProps.cache` is a `RenderCache`.
  - Plugin renames: `ShapePlugin.rectangle()` is `RectanglePlugin()`,
    `ShapePlugin.ellipse()` is `EllipsePlugin()`, `DatePlugin.date()`,
    `.time()` and `.dateTime()` are `DatePlugin()`, `TimePlugin()` and
    `DateTimePlugin()`, and `BarcodePlugin('qrcode')` is
    `BarcodePlugin(BarcodeType.qrcode)`.
  - Custom plugins: the old `Schema` class, a wrapper of the JSON map with
    `[]`, `string()`, `number()`, `boolean()` and `copyWith(Map)`, is gone.
    `Schema` is now the typed base class. Extend it and read your keys in
    a `fromJson` constructor. The JSON-map wrapper is internal now.
  - `PdfLayout.of` takes the typed `Schema` (it took the old JSON-map
    `Schema`).
  - `toJson()` and `fromJson()` on every schema. A schema read from JSON
    keeps its map, so `toJson()` gives the designer JSON back with no
    change, also keys this package does not know.

  Before:

  ```dart
  await generate(
    template: <String, dynamic>{
      'basePdf': <String, dynamic>{'width': 210, 'height': 297, 'padding': <int>[10, 10, 10, 10]},
      'schemas': <List<Map<String, dynamic>>>[
        <Map<String, dynamic>>[
          <String, dynamic>{'name': 'title', 'type': 'text', 'position': <String, num>{'x': 20, 'y': 20}, 'width': 170, 'height': 15},
        ],
      ],
    },
    inputs: <Map<String, dynamic>>[<String, dynamic>{'title': 'Hello'}],
    options: <String, dynamic>{'lang': 'en'},
  );
  ```

  After:

  ```dart
  await generate(
    template: Template(
      basePdf: const BlankPdf(),
      schemas: <List<Schema>>[
        <Schema>[
          const TextSchema(name: 'title', position: Position(20, 20), width: 170, height: 15),
        ],
      ],
    ),
    inputs: <Map<String, String>>[<String, String>{'title': 'Hello'}],
    options: GenerateOptions(lang: 'en'),
  );

  // or, with the pdfme JSON:
  await generate(
    template: Template.fromJson(json),
    inputs: <Map<String, String>>[<String, String>{'title': 'Hello'}],
    options: GenerateOptions.fromJson(optionsJson),
  );
  ```
- A deeply nested list as a table input could overflow the stack in
  `generate` (it was turned into JSON there). Inputs are strings now, so
  this path is gone.
- New `table` schema type (`TablePlugin`, in `builtInPlugins` as `Table`).
  The value is a JSON string of rows. It has the props and defaults of
  pdfme: head, column widths, table, head, body and column styles.
- Tables grow like in pdfme: on a blank base PDF, a table taller than its
  box pushes the schemas below it down and goes on over new pages. The
  head can repeat on each page (`repeatHead`). On a PDF base the table
  draws its full height and makes no new pages, like pdfme.
- Table image columns (`columnStyles.cellType: "image"`): PNG and JPEG
  data URLs in the cells, with `imageHeightMode` (`fixed`, `auto`) and
  `imageHeight`, like pdfme.
- A table row with fewer cells than the head throws, like pdfme. A
  column without a width in `headWidthPercentages` throws a clear error
  (pdfme fails on it too).
- New schema types, like in pdfme: `multiVariableText` (a text with
  `{name}` variables, the input is a JSON object of values), `signature`
  (drawn like an image) and `circleMark` (a circle line when the input is
  `'true'`). They are in `builtInPlugins`.
- PDF417 has the same modules as in pdfme. The `barcode` package picked
  other columns, rows and codewords, so the code was wider and lower than
  in pdfme and did not fill a box made for it. Now a port of the bwip-js
  (BWIPP) encoder makes the symbol.
- 2D codes (QR code, Data Matrix, PDF417) put their module edges on the
  same grid as bwip-js, so small codes look the same as in pdfme.
- QR codes have the same modules as in pdfme. bwip-js raises the error
  correction level when the data still fits the same size, picks the mask
  with its own scores and mixes number, letter and byte segments (never
  kanji). The `barcode` package did not, so the codes looked different.
  Now a port of the bwip-js (BWIPP) encoder makes the symbol.
- Barcode values that pass pdfme's check but that bwip-js refuses make
  `generate` throw a `BarcodeInputException` with the bwip-js message,
  like pdfme. Before, they drew a code or nothing. Eg. GS1 Data Matrix data
  that breaks the GS1 rules (unknown AI, too long, bad date or check
  digit, AIs that exclude or need each other), a UPC-E with a wrong check
  digit, Code 39 with white space other than a space, a lowercase NW-7
  start or stop letter, too long Code 128, Japan Post or PDF417 data, and text with
  a lone UTF-16 surrogate (`URI malformed`).
- GS1 Data Matrix has the same modules and size as in pdfme. Letters now
  use C40, Text, X12 and EDIFACT like bwip-js, so a value with many letters
  is no longer one size bigger.
- Code 128 has the same bars as in pdfme. The `barcode` package started
  some texts (like `HELLO` or `12345`) in another code set. Text with
  letters like `é` works now.
- The bearer box of ITF-14 is black, like in pdfme. It had the bar color.
- UPC-E has the right check digit, like bwip-js: it comes from the UPC-A
  the code stands for. The `barcode` package drew a wrong check digit (and
  bars) for about 1 in 15 codes, like `0481683`.
- Date formats: all date-fns tokens work, like `do` (`7th`), `PPP` (`May
  7th, 2024`), `Q`, `w` and `B`. Other tokens made the format fall back to
  the default format. `iiii` gives the full day name (it gave `Tue`).
  Seven or more `S` (like `ss.SSSSSSS`) made `generate` crash.
- The crosscheck with pdfme compares every schema box on its own: the ink
  box (place and size) and the pixels, with tight limits per type, and the
  bars of linear barcodes. It has many new variants of every type.

## 0.0.1

- First version: `generate(template, inputs, options, plugins)`, a Dart port
  of the pdfme generator (pdfme 6.2.8). It reads pdfme template JSON.
- Schema types: text, image, svg, line, rectangle, ellipse, qrcode, ean13,
  ean8, code39, code128, nw7, itf14, upca, upce, japanpost, gs1datamatrix,
  pdf417, date, time, dateTime, checkbox, radioGroup and select.
- Plugins: extend `SchemaPlugin` for your own types. `builtInPlugins` has
  all types of this package.
- Roboto is the default font, like in pdfme.
- Barcodes are drawn as vectors.
- Images with an EXIF orientation are turned like in pdfme.
- Thai, Lao, Khmer and Myanmar text breaks between words, like pdfme with
  `Intl.Segmenter` (needs `dictionaryWordBreaks` of dox_pdf_lib 0.0.2).
