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

## Install

```bash
dart pub add dox_pdf_me
```

You need Dart 3.13 or newer. It works where dox_pdf_lib works (see
[Platforms](#platforms)).

## Quick start

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';

Future<void> main() async {
  // A template from the pdfme designer (JSON). Sizes are in millimetres.
  Map<String, dynamic> template = <String, dynamic>{
    'basePdf': <String, dynamic>{
      'width': 210,
      'height': 297,
      'padding': <int>[10, 10, 10, 10],
    },
    'schemas': <List<Map<String, dynamic>>>[
      <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'title',
          'type': 'text',
          'position': <String, num>{'x': 20, 'y': 20},
          'width': 170,
          'height': 15,
          'fontSize': 24,
        },
        <String, dynamic>{
          'name': 'link',
          'type': 'qrcode',
          'position': <String, num>{'x': 20, 'y': 40},
          'width': 30,
          'height': 30,
        },
      ],
    ],
  };

  List<Map<String, dynamic>> inputs = <Map<String, dynamic>>[
    <String, dynamic>{'title': 'Hello, pdfme!', 'link': 'https://pdfme.com'},
  ];

  Uint8List pdf = await generate(
    template: template,
    inputs: inputs,
    plugins: builtInPlugins,
  );
  File('hello.pdf').writeAsBytesSync(pdf);
}
```

- `template` is the template JSON from pdfme, as a Dart `Map`. You can read
  it from a file with `jsonDecode`.
- `inputs` is a list of maps. Each map makes one copy of the template. The
  keys are the schema names.
- `options` is the pdfme options map: `font`, `lang`, `title`, `author`,
  `subject`, `keywords`, `creator`, `producer`, `creationDate`,
  `modificationDate` and `colorType` (`rgb` or `cmyk`). You can also pass a
  `GenerateOptions` object.
- The result is the bytes of the PDF file.

### The base PDF

`basePdf` is one of these:

- A blank page: `{"width": 210, "height": 297, "padding": [10, 10, 10, 10]}`
  (millimetres). It can have a `staticSchema` list. Static schemas are drawn
  on every page, for example a header with `{currentPage}` and `{totalPages}`.
- A PDF file: bytes (`Uint8List`), a base64 string or a data URI. Each page
  of the file is one page of the template. The schemas are drawn on top.

## Plugins

Each schema `type` is a plugin. A plugin is a class that extends
`SchemaPlugin`. It has a `type` and a `pdf` method that draws one schema.

Like pdfme, `generate` uses only the `text` plugin when you pass no
`plugins`. Pass `builtInPlugins` to use all types of this package:

```dart
await generate(template: template, inputs: inputs, plugins: builtInPlugins);
```

You can also pick the plugins you need, or add your own:

```dart
import 'package:dox_pdf_me/dox_pdf_me.dart';

class StampPlugin extends SchemaPlugin {
  const StampPlugin();

  @override
  String get type => 'stamp';

  @override
  Future<void> pdf(RenderProps props) async {
    PdfLayout box = PdfLayout.of(props.schema, props.page.getHeight());
    props.page.drawRectangle(
      x: box.x,
      y: box.y,
      width: box.width,
      height: box.height,
      color: rgb(1, 0, 0),
    );
  }
}

await generate(
  template: template,
  inputs: inputs,
  plugins: <String, SchemaPlugin>{
    ...builtInPlugins,
    'Stamp': const StampPlugin(),
  },
);
```

`RenderProps` has the input `value`, the `schema`, the `page`, the document
(`doc`), the `options`, the `fonts` and a `cache` for the whole document. Use
the drawing methods of dox_pdf_lib on the page. `dox_pdf_me` exports the
dox_pdf_lib API, so one import is enough.

## Schema types

| Type | Plugin |
|---|---|
| `text` | `TextPlugin` |
| `image` | `ImagePlugin` (PNG and JPEG, as data URL or base64) |
| `svg` | `SvgPlugin` |
| `line`, `rectangle`, `ellipse` | `LinePlugin`, `ShapePlugin.rectangle()`, `ShapePlugin.ellipse()` |
| `qrcode`, `ean13`, `ean8`, `code39`, `code128`, `nw7`, `itf14`, `upca`, `upce`, `japanpost`, `gs1datamatrix`, `pdf417` | `BarcodePlugin(type)` |
| `date`, `time`, `dateTime` | `DatePlugin.date()`, `.time()`, `.dateTime()` |
| `checkbox`, `radioGroup` | `CheckboxPlugin`, `RadioGroupPlugin` |
| `select` | `SelectPlugin` |
| `table` | `TablePlugin` |

The text props work like in pdfme: `fontName`, `fontSize`, `alignment`
(`left`, `center`, `right`, `justify`), `verticalAlignment` (`top`,
`middle`, `bottom`), `lineHeight`, `characterSpacing`, `fontColor`,
`backgroundColor`, `borderColor`, `borderWidth`, `padding`, `underline`,
`strikethrough` and `dynamicFontSize` (`min`, `max`, `fit`). Long text wraps
with the same line break rules as pdfme (Unicode line breaking). Thai, Lao,
Khmer and Myanmar text breaks between words, like in pdfme: the words come
from the same ICU word lists as in Node.js 24 (`dictionaryWordBreaks` of
dox_pdf_lib).

A `table` value is a JSON string of rows, eg. `[["Alice","Paris"]]` (a
list of lists works too). The props work like in pdfme: `head`,
`showHead`, `repeatHead`, `headWidthPercentages`, `tableStyles`
(`borderColor`, `borderWidth`), `headStyles` and `bodyStyles` (cell
styles; `bodyStyles` also has `alternateBackgroundColor`) and
`columnStyles` (`alignment` and `verticalAlignment` per column). A cell
style has the text props plus `borderWidth` and `padding` per side. A
read-only table uses its input when there is one, else its `content`.

On a blank base PDF, a table that is taller than its box grows. The
schemas below it move down, and the table goes on over new pages (pdfme's
dynamic layout). On a PDF base, the table draws its full height on the
same page, like pdfme.

`multiVariableText` is not supported yet.

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
  options: <String, dynamic>{
    'font': <String, dynamic>{
      'Roboto': <String, dynamic>{'data': FontStore.defaultFont.data, 'fallback': true},
      'NotoSansJP': <String, dynamic>{'data': noto},
    },
  },
);
```

- `data` is the font file: bytes, a base64 string or a data URI.
- Exactly one font has `fallback: true`. Schemas without `fontName` use it.
- `subset` is true by default: only the used letters go into the PDF.
- A schema uses one font. Letters that are not in the font are drawn as
  empty boxes, like in pdfme.

## Differences from pdfme

This list compares with pdfme 6.2.8.

- **Barcodes are vectors.** pdfme draws barcodes with bwip-js. This package
  draws them as vector shapes with the `barcode` package. The bars of EAN-13,
  EAN-8, UPC-A, UPC-E, Code 39, NW-7, ITF-14 and Japan Post are in the same
  places. PDF417 has the same modules as bwip-js (same codewords, columns
  and rows). Small differences:
  - The text under the bars uses Helvetica, not OCR-B. It has the same place
    and size.
  - QR codes can use another mask. The size, place and data are the same,
    and scanners read them.
  - Code 128 can pick other code sets for some texts. The data is the same.
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
- **Date formats:** month and day names are English for every locale. Most
  date-fns tokens work (`yyyy`, `MM`, `MMMM`, `dd`, `EEEE`, `HH`, `hh`, `mm`,
  `ss`, `aa`, ...). A format with other tokens falls back to the default
  format.
- **Read-only text:** `{...}` placeholders support names and dotted paths,
  like `{name}`, `{order.id}`, `{currentPage}`, `{totalPages}`, `{date}` and
  `{dateTime}`. pdfme also runs JavaScript expressions, like `{price * 2}`.
  Those stay as they are.
- **Tables:** image cells (`columnStyles.cellType: "image"`) are not
  supported yet; the cell shows the value as text. A column without a
  width in `headWidthPercentages` gets a share of the rest of the table
  width (pdfme gives it no width). A row with fewer cells than the head
  gets empty cells (pdfme throws).
- **Not supported yet:** `overflow: "expand"` (the text box does not grow,
  and it does not move other schemas), `list`, inline markdown text,
  `multiVariableText`, font URLs, base PDFs
  with a user password (`basePdfPassword`), and link annotations of the base PDF.
- **EXIF orientation** of JPEG and PNG images works like in pdfme. pdfme
  turns the pixels and encodes a JPEG again; this package keeps the file and
  turns it when it draws it. The page looks the same.

## Platforms

dox_pdf_me runs where dox_pdf_lib runs: Dart programs on macOS, Linux and
Windows. It does not work on the web. Android and iOS are not supported yet.
See the [dox_pdf_lib platforms](https://pub.dev/packages/dox_pdf_lib#platforms).

## Thanks and licenses

The behavior comes from [pdfme](https://github.com/pdfme/pdfme) (MIT) by
Kyohei Fukuda and the pdfme contributors. The line break tables come from
pdfme and the Unicode Character Database. The PDF417 encoder is a port of
[BWIPP](https://github.com/bwipp/postscriptbarcode) (MIT) by Terry Burton,
which bwip-js uses. See
[lib/src/barcodes/BWIPP-LICENSE.txt](lib/src/barcodes/BWIPP-LICENSE.txt).

The package includes the **Roboto** font (Copyright 2011 Google Inc.), under
the Apache License 2.0. See
[lib/src/fonts/ROBOTO-LICENSE.txt](lib/src/fonts/ROBOTO-LICENSE.txt).

## License

MIT. See [LICENSE](LICENSE).
