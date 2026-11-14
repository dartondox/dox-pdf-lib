# dox_pdf_me

[![pub package](https://img.shields.io/pub/v/dox_pdf_me.svg)](https://pub.dev/packages/dox_pdf_me)
[![CI](https://github.com/dartondox/dox-pdf-lib/actions/workflows/ci.yaml/badge.svg)](https://github.com/dartondox/dox-pdf-lib/actions/workflows/ci.yaml)

Make PDF files from [pdfme](https://pdfme.com) templates in Dart.

pdfme is a JavaScript tool. You design a template in its designer. Then you
fill the template with data and get a PDF. This package is a Dart port of the
pdfme generator. It reads the same template JSON and the same inputs, and it
makes PDFs that look the same.

It is built on [dox_pdf_lib](https://pub.dev/packages/dox_pdf_lib), our Dart
port of pdf-lib.

> **Not stable yet.** This package is new and still at version 0.0.x. Its API
> can change between versions, with small breaking changes. Pin the exact
> version in your `pubspec.yaml`, and read the CHANGELOG before you update.

## Install

```bash
dart pub add dox_pdf_me
```

You need Dart 3.13 or newer. It works where dox_pdf_lib works (see
[Platforms](#platforms)).

## Quick start

Build a template in Dart. You do not need the pdfme designer for this.

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';

Future<void> main() async {
  // An A4 page. Sizes and positions are in millimetres.
  Template template = Template(
    basePdf: const BlankPdf(),
    schemas: <List<Schema>>[
      <Schema>[
        const TextSchema(
          name: 'title',
          position: Position(20, 20),
          width: 170,
          height: 15,
          fontSize: 24,
        ),
        BarcodeSchema(
          name: 'link',
          barcodeType: BarcodeType.qrcode,
          position: const Position(20, 40),
        ),
      ],
    ],
  );

  Uint8List pdf = await generate(
    template: template,
    inputs: <Map<String, String>>[
      <String, String>{'title': 'Hello, pdfme!', 'link': 'https://pdfme.com'},
    ],
    plugins: builtInPlugins,
  );
  File('hello.pdf').writeAsBytesSync(pdf);
}
```

- `template` is a `Template`: the base PDF and a list of schemas for each
  page. Each schema type has its own class, eg. `TextSchema`.
- `inputs` is a list of maps. Each map makes one copy of the template. The
  keys are the schema names. The values are strings, like in pdfme.
- `options` is a `GenerateOptions`: `font`, `lang`, `title`, `author`,
  `subject`, `keywords`, `creator`, `producer`, `creationDate`,
  `modificationDate` and `colorType` (`ColorType.rgb` or `ColorType.cmyk`).
- `plugins` are the schema types to use. Pass `builtInPlugins` for all of
  them.
- The result is the bytes of the PDF file.

## Templates from the pdfme designer

The pdfme designer (or your own frontend) saves the template as JSON. Read
it with `Template.fromJson`:

```dart
Map<String, Object?> json =
    jsonDecode(File('template.json').readAsStringSync()) as Map<String, Object?>;

Uint8List pdf = await generate(
  template: Template.fromJson(json),
  inputs: <Map<String, String>>[
    <String, String>{'title': 'Hello'},
  ],
  options: GenerateOptions.fromJson(<String, Object?>{'lang': 'en'}),
  plugins: builtInPlugins,
);
```

- Both pdfme formats work: each page a list of schemas, or (the old
  format) each page a map of name to schema.
- Each schema becomes its typed class. Eg. a `qrcode` schema is a
  `BarcodeSchema`. A type with no plugin is an `UnknownSchema`.
- `toJson()` gives the JSON back. A schema read with `fromJson` keeps its
  JSON map, also the keys this package does not know. So you can send the
  template back to the frontend with no change.
- `GenerateOptions.fromJson` reads the pdfme options JSON.

### The base PDF

`basePdf` is one of these:

- `BlankPdf()`: blank pages. The default is A4 (210 x 297 mm) with a
  padding of 10 mm: `BlankPdf(width: 210, height: 297, padding:
  Sides.all(10))`. It can have a `staticSchema` list. Static schemas are
  drawn on every page, for example a header with `{currentPage}` and
  `{totalPages}`. In JSON: `{"width": 210, "height": 297, "padding": [10,
  10, 10, 10]}`.
- `PdfFile(bytes)`: a PDF file. Each page of the file is one page of the
  template. The schemas are drawn on top. In JSON: a base64 string or a
  data URI.

### Inputs

Every input value is a string, like in pdfme:

- A `table` takes a JSON string of rows. Use `jsonEncode(rows)`, eg.
  `[["Alice","Paris"]]`.
- A `multiVariableText` takes a JSON string of values, eg.
  `{"name": "Ann"}`.
- A `checkbox`, `radioGroup` or `circleMark` is on for `'true'`.
- An `image` or `signature` takes a PNG or JPEG data URL or base64.

## Schema types

Each type has a schema class and a plugin. Every pdfme option is a named,
typed field with the pdfme default. Fixed choices are enums, eg.
`Alignment.center`. All schemas have `name`, `position`, `width`,
`height`, `rotate`, `opacity`, `readOnly`, `required` and `content`.

| Type | Schema class | Plugin | Main options |
|---|---|---|---|
| `text` | `TextSchema` | `TextPlugin` | `fontName`, `fontSize`, `alignment`, `verticalAlignment`, `lineHeight`, `characterSpacing`, `fontColor`, `backgroundColor`, `borderColor`, `borderWidth`, `padding`, `underline`, `strikethrough`, `dynamicFontSize` |
| `multiVariableText` | `MultiVariableTextSchema` | `MultiVariableTextPlugin` | the text options, `text`, `variables` |
| `select` | `SelectSchema` | `SelectPlugin` | the text options, `options` |
| `image` | `ImageSchema` | `ImagePlugin` | `objectFit`, `objectPosition` |
| `signature` | `SignatureSchema` | `SignaturePlugin` | drawn like an image |
| `svg` | `SvgSchema` | `SvgPlugin` | the input is the SVG text |
| `line` | `LineSchema` | `LinePlugin` | `color` |
| `rectangle`, `ellipse` | `RectangleSchema`, `EllipseSchema` | `RectanglePlugin`, `EllipsePlugin` | `color`, `borderColor`, `borderWidth`, `radius` |
| `circleMark` | `CircleMarkSchema` | `CircleMarkPlugin` | `color`, `borderWidth` |
| `qrcode`, `ean13`, `ean8`, `code39`, `code128`, `nw7`, `itf14`, `upca`, `upce`, `japanpost`, `gs1datamatrix`, `pdf417` | `BarcodeSchema` with a `BarcodeType` | `BarcodePlugin(type)` | `backgroundColor`, `barColor`, `textColor`, `includetext` |
| `date`, `time`, `dateTime` | `DateSchema`, `TimeSchema`, `DateTimeSchema` | `DatePlugin`, `TimePlugin`, `DateTimePlugin` | `format`, `locale`, `fontName`, `fontSize`, `alignment`, `characterSpacing`, `fontColor`, `backgroundColor` |
| `checkbox`, `radioGroup` | `CheckboxSchema`, `RadioGroupSchema` | `CheckboxPlugin`, `RadioGroupPlugin` | `color`, `group` |
| `table` | `TableSchema` | `TablePlugin` | `head`, `headWidthPercentages`, `showHead`, `repeatHead`, `tableStyles`, `headStyles`, `bodyStyles`, `columnStyles` |

A QR code is a `BarcodeSchema` with `barcodeType: BarcodeType.qrcode`. Its
box is 30 x 30 mm by default. Each barcode type has the default size of
the pdfme designer.

Colors are hex strings, like in the pdfme JSON: `#ff0000`, `#f00`, or
with alpha `#ff000080`. An empty string means no color. A bad hex value
makes `generate` throw. Strings keep the JSON the same as in pdfme, and
the drawing API of dox_pdf_lib has its own `Color` type, so a second color
type would only confuse.

The sides of a text `padding` or `borderWidth` are `Sides(top: 1, right:
2, bottom: 1, left: 2)` or `Sides.all(1)`.

The text props work like in pdfme: `fontName`, `fontSize`, `alignment`
(`left`, `center`, `right`, `justify`), `verticalAlignment` (`top`,
`middle`, `bottom`), `lineHeight`, `characterSpacing`, `fontColor`,
`backgroundColor`, `borderColor`, `borderWidth`, `padding`, `underline`,
`strikethrough` and `dynamicFontSize` (`min`, `max`, `fit`). Long text wraps
with the same line break rules as pdfme (Unicode line breaking). Thai, Lao,
Khmer and Myanmar text breaks between words, like in pdfme: the words come
from the same ICU word lists as in Node.js 24 (`dictionaryWordBreaks` of
dox_pdf_lib).

A `table` value is a JSON string of rows, eg. `[["Alice","Paris"]]`. The
props work like in pdfme: `head`, `showHead`, `repeatHead`,
`headWidthPercentages`, `tableStyles` (`borderColor`, `borderWidth`),
`headStyles` and `bodyStyles` (cell styles; `bodyStyles` also has
`alternateBackgroundColor`) and `columnStyles` (`alignment` and
`verticalAlignment` per column). A cell style (`CellStyle.head()`,
`CellStyle.body()`) has the text props plus `borderWidth` and `padding`
per side. A read-only table uses its input when there is one, else its `content`.

A column with `columnStyles.cellType` `"image"` shows PNG and JPEG data
URLs, fitted in the cell (`contain`, placed by the cell alignment). The
head of the column stays text. `imageHeightMode` `fixed` (default) makes
the image `imageHeight` mm high (20 by default), also when the cell is
empty or not an image; `auto` follows the image ratio and fits on one
page. Like pdfme, an empty cell or a value that is not a PNG or JPEG
data URL draws no image.

On a blank base PDF, a table that is taller than its box grows. The
schemas below it move down, and the table goes on over new pages (pdfme's
dynamic layout). On a PDF base, the table draws its full height on the
same page, like pdfme.

Barcodes: a value that pdfme's check refuses (eg. a bad EAN-13 check digit)
draws nothing, like in pdfme. A value that passes that check but that
bwip-js can not encode makes `generate` throw a `BarcodeInputException`
with the bwip-js message, like pdfme's `generate` fails. Eg. GS1 data that
breaks the GS1 rules: `bwipp.GS1valueTooLong#3845: AI 10: Too long`.

### multiVariableText

The schema has a `text` with `{name}` variables and a `variables` list of
the names. The input is a JSON string with the value of each variable:

```dart
MultiVariableTextSchema schema = const MultiVariableTextSchema(
  name: 'greeting',
  position: Position(20, 20),
  width: 170,
  height: 10,
  text: 'Hello {name}, welcome to {city}!',
  variables: <String>['name', 'city'],
);
Map<String, String> input = <String, String>{
  'greeting': '{"name": "Ann", "city": "Paris"}',
};
```

- The result is drawn like a `text` schema. All text props work, also
  `dynamicFontSize`.
- `{...}` parts without a value are removed.
- When a variable of `variables` is missing in the input (or `null`),
  nothing is drawn. With `required: true`, `generate` throws.
- `readOnly: true`: the values come from the schema `content` (a JSON
  string). With `contentSnapshot: true`, `content` is the text to draw.

### circleMark

A circle line around the box when the input is `'true'`. `color` is the
line color (a hex value) and `borderWidth` is the line width (mm). Nothing
is drawn for other inputs, a bad color or a width of 0.

## Plugins

Each schema `type` is a plugin. Like pdfme, `generate` uses only the `text`
plugin when you pass no `plugins`. Pass `builtInPlugins` to use all types
of this package, or pick the plugins you need.

### Your own schema type

A plugin extends `SchemaPlugin<S>`. `S` is its own schema class, so the
plugin gets typed values. The plugin also says how to read its schema
from JSON.

```dart
import 'package:dox_pdf_me/dox_pdf_me.dart';

class StampSchema extends Schema {
  const StampSchema({
    required super.name,
    required super.position,
    super.width = 30,
    super.height = 10,
    this.label = 'PAID',
  });

  StampSchema.fromJson(super.json)
    : label = json['label'] is String ? json['label']! as String : 'PAID',
      super.fromJson();

  final String label;

  @override
  String get type => 'stamp';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    ...super.toJson(),
    'label': label,
  };
}

class StampPlugin extends SchemaPlugin<StampSchema> {
  const StampPlugin();

  @override
  String get type => 'stamp';

  @override
  StampSchema fromJson(Map<String, Object?> json) => StampSchema.fromJson(json);

  @override
  Future<void> pdf(RenderProps<StampSchema> props) async {
    PdfLayout box = PdfLayout.of(props.schema, props.page.getHeight());
    props.page.drawRectangle(
      x: box.x,
      y: box.y,
      width: box.width,
      height: box.height,
      color: rgb(1, 0, 0),
    );
    // draw the label with a built-in plugin
    await const TextPlugin().pdf(
      props.withSchema(
        TextSchema(
          name: props.schema.name,
          position: props.schema.position,
          width: props.schema.width,
          height: props.schema.height,
          fontColor: '#ffffff',
        ),
        value: props.schema.label,
      ),
    );
  }
}
```

Pass the plugin to `generate`. Pass it to `Template.fromJson` too, so the
`stamp` schemas of frontend JSON are read as `StampSchema`:

```dart
Map<String, SchemaPlugin<Schema>> plugins = <String, SchemaPlugin<Schema>>{
  ...builtInPlugins,
  'Stamp': const StampPlugin(),
};
Template template = Template.fromJson(json, plugins: plugins);
await generate(template: template, inputs: inputs, plugins: plugins);
```

`RenderProps` has the input `value`, the typed `schema`, the `basePdf`,
the `page`, the document (`doc`), the `options`, the `fonts` and a `cache`
for the whole document. Use the drawing methods of dox_pdf_lib on the page.
`dox_pdf_me` exports the dox_pdf_lib API, so one import is enough.

## Fonts

pdfme uses the Roboto font when you give no fonts. This package does the
same. Roboto is included in the package, so you do not need a font file for
Latin text.

For other languages, pass your fonts in `options.font`, like in pdfme:

```dart
Uint8List noto = File('NotoSansJP-Regular.otf').readAsBytesSync();
await generate(
  template: template,
  inputs: inputs,
  plugins: builtInPlugins,
  options: GenerateOptions(
    font: <String, FontSource>{
      'Roboto': FontStore.defaultFont,
      'NotoSansJP': FontSource(noto),
    },
  ),
);
```

- `FontSource(data)`: `data` is the font file. In the pdfme options JSON
  (`GenerateOptions.fromJson`), it can also be a base64 string or a data
  URI.
- Exactly one font has `fallback: true`. Schemas without `fontName` use it.
- `subset` is true by default: only the used letters go into the PDF.
- A schema uses one font. Letters that are not in the font are drawn as
  empty boxes, like in pdfme.

## Differences from pdfme

This list compares with pdfme 6.2.8.

- **Barcodes are vectors.** pdfme draws barcodes with bwip-js. This package
  draws them as vector shapes, with the same bars and modules as bwip-js:
  the same places for the bars of all linear types, the same code sets for
  Code 128, and the same modules for QR code, Data Matrix and PDF417
  (same segments, version, error correction level and mask). One small
  difference: the text under the bars uses Helvetica, not OCR-B. It has the
  same place and size.
- **SVG:** `fill-rule="evenodd"` fills like `nonzero`.
- **Complex scripts** (Thai, Arabic, Hindi, ...) are drawn with HarfBuzz
  rules (see dox_pdf_lib). Mark positions can be a little different. For
  Myanmar, the widths can differ by a few percent (pdfme's fontkit does not
  shape Myanmar fully), so a `dynamicFontSize` box can get another size.
- **Word breaks** of Thai, Lao, Khmer and Myanmar match pdfme on Node.js 24
  (ICU 78). Another Node.js version or a browser can have other word lists.
- **Missing letters** in a font: their width is the real width of the empty
  box glyph. pdfme gives them no width in the PDF, so a viewer draws them
  wider than pdfme measured.
- **Date formats:** all date-fns tokens work (`yyyy`, `MMMM`, `do`, `EEEE`,
  `HH`, `aa`, `PPP`, `p`, `Q`, `w`, ...). Month and day names and the long
  formats (`P`, `p`) are English for every locale, and weeks start on
  Sunday (`w`, `e`, `c`, `Y`).
- **Read-only text:** `{...}` placeholders support names and dotted paths,
  like `{name}`, `{order.id}`, `{currentPage}`, `{totalPages}`, `{date}` and
  `{dateTime}`. pdfme also runs JavaScript expressions, like `{price * 2}`.
  Those stay as they are.
- **Tables:** a column without a width in `headWidthPercentages` throws
  an error. pdfme gives that column no width (NaN): pdf-lib then throws
  when it draws the column, or the column comes out broken when nothing
  is drawn in it. A row with fewer cells than the head throws, like pdfme
  (`Cannot read properties of undefined (reading 'split')`). Number cells
  work (pdfme throws `raw.split is not a function` on a blank base PDF).
- **Not supported yet:** `overflow: "expand"` (the text box does not grow,
  and it does not move other schemas), `list`, inline markdown text,
  font URLs, base PDFs
  with a user password (`basePdfPassword`), and link annotations of the base PDF.
- **Inline markdown:** with `textFormat: "inline-markdown"`, the text is
  drawn as plain text (inline markdown is not supported yet).
- **EXIF orientation** of JPEG and PNG images works like in pdfme. pdfme
  turns the pixels and encodes a JPEG again; this package keeps the file and
  turns it when it draws it. The page looks the same.

## Platforms

dox_pdf_me runs where dox_pdf_lib runs: Dart programs on macOS, Linux and
Windows. It does not work on the web. Android and iOS are not supported yet.
See the [dox_pdf_lib platforms](https://pub.dev/packages/dox_pdf_lib#platforms).

Need iOS or Android? Give a 👍 on [issue #18 (iOS)](https://github.com/dartondox/dox-pdf-lib/issues/18)
or [issue #19 (Android)](https://github.com/dartondox/dox-pdf-lib/issues/19). When an
issue has requests from 50 users, we add support for that platform.

## Thanks and licenses

The behavior comes from [pdfme](https://github.com/pdfme/pdfme) (MIT) by
Kyohei Fukuda and the pdfme contributors. The line break tables come from
pdfme and the Unicode Character Database. The PDF417, QR code, Data Matrix and Code 128 encoders are ports of
[BWIPP](https://github.com/bwipp/postscriptbarcode) (MIT) by Terry Burton,
which bwip-js uses. See
[lib/src/barcodes/BWIPP-LICENSE.txt](lib/src/barcodes/BWIPP-LICENSE.txt).

The package includes the **Roboto** font (Copyright 2011 Google Inc.), under
the Apache License 2.0. See
[lib/src/fonts/ROBOTO-LICENSE.txt](lib/src/fonts/ROBOTO-LICENSE.txt).

## License

MIT. See [LICENSE](LICENSE).
