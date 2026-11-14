# dox_pdf_lib

[![pub package](https://img.shields.io/pub/v/dox_pdf_lib.svg)](https://pub.dev/packages/dox_pdf_lib)
[![CI](https://github.com/dartondox/dox-pdf-lib/actions/workflows/ci.yaml/badge.svg)](https://github.com/dartondox/dox-pdf-lib/actions/workflows/ci.yaml)

Create and edit PDF files in Dart.

dox_pdf_lib follows the API of the JavaScript library [pdf-lib](https://pdf-lib.js.org). Classes and methods have the same names.
If you know pdf-lib, you already know this package.
A small native core, written in Rust, does the work.

- Create new PDFs, or load and edit existing ones.
- Add, insert, remove, copy and merge pages.
- Draw text, lines, shapes, SVG paths, JPEG and PNG images.
- Use the 14 standard fonts, or embed your own TrueType and OpenType fonts. You can embed only the letters you use (a subset).
- Write text in many languages, including Thai, Myanmar, Khmer, Arabic, Hebrew and Hindi.
- Read, fill, create and flatten forms.
- Attach files, and read them back.
- Place pages of another PDF on a page (for templates).
- Set the title, author and other metadata.

It works in Dart programs on macOS, Linux and Windows. It does not work on the web. Android and iOS are not supported yet.

## Install

```bash
dart pub add dox_pdf_lib
```

You need Dart 3.13 or newer.
A ready-built native library is downloaded for macOS, Linux and Windows, so you do not need Rust.
See [Platforms](#platforms).

## Quick start

```dart
import 'dart:io';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

Future<void> main() async {
  PDFDocument doc = await PDFDocument.create();
  PDFFont font = await doc.embedFont(StandardFonts.helvetica);
  PDFPage page = doc.addPage(PageSizes.A4);
  page.drawText('Hello, PDF!', x: 50, y: 750, font: font, size: 30);
  File('hello.pdf').writeAsBytesSync(await doc.save());
}
```

## Guide

### Load, edit and save

```dart
PDFDocument doc = await PDFDocument.load(File('in.pdf').readAsBytesSync());
print(doc.getPageCount());
PDFPage first = doc.getPage(0);
first.setRotation(degrees(90));
File('out.pdf').writeAsBytesSync(await doc.save());
```

- `save()` returns the bytes of the file. `saveAsBase64()` returns a base64 string, or a data URI with `dataUri: true`.
- `load` throws `EncryptedPDFError` for an encrypted file. Use `ignoreEncryption: true` to load it anyway (see [Differences](#differences-from-pdf-lib)).
- Big files load and save on a native thread, so your app is not blocked.
- A document is freed when Dart's garbage collector removes it. Call `doc.dispose()` to free it right away.

### Pages

```dart
PDFDocument doc = await PDFDocument.create();
doc.addPage(PageSizes.Letter);
doc.addPage(<double>[400, 600]); // width and height in points
doc.insertPage(0, PageSizes.A5);
doc.removePage(1);

PDFPage page = doc.getPage(0);
print(page.getSize()); // (height: 595.28, width: 419.53)
page.setSize(420, 600);
page.setCropBox(10, 10, 400, 580);
```

Merge two PDFs with `copyPages`:

```dart
PDFDocument a = await PDFDocument.load(File('a.pdf').readAsBytesSync());
PDFDocument b = await PDFDocument.load(File('b.pdf').readAsBytesSync());
PDFDocument merged = await PDFDocument.create();
for (PDFDocument source in <PDFDocument>[a, b]) {
  List<PDFPage> pages = await merged.copyPages(source, source.getPageIndices());
  for (PDFPage page in pages) {
    merged.addPage(page);
  }
}
File('merged.pdf').writeAsBytesSync(await merged.save());
```

### Metadata

```dart
doc.setTitle('Invoice 42');
doc.setAuthor('Jane Doe');
doc.setKeywords(<String>['invoice', 'paid']);
doc.setLanguage('en-US');
doc.setCreationDate(DateTime.now());
print(doc.getTitle());
```

### Draw text and shapes

```dart
PDFDocument doc = await PDFDocument.create();
PDFFont bold = await doc.embedFont(StandardFonts.helveticaBold);
PDFPage page = doc.addPage();

page.drawText(
  'A long line of text that wraps inside 300 points.',
  x: 50,
  y: 700,
  font: bold,
  size: 14,
  color: rgb(0.1, 0.3, 0.8),
  maxWidth: 300,
  lineHeight: 18,
);
page.drawLine(
  start: (x: 50, y: 650),
  end: (x: 350, y: 650),
  thickness: 2,
  color: grayscale(0.5),
);
page.drawRectangle(
  x: 50,
  y: 500,
  width: 200,
  height: 100,
  color: rgb(1, 0.9, 0.9),
  borderColor: rgb(1, 0, 0),
  borderWidth: 2,
  opacity: 0.8,
);
page.drawCircle(x: 350, y: 550, size: 40, color: cmyk(0.5, 0, 0, 0));
page.drawSvgPath('M 0,20 L 100,160 Q 130,200 150,120 Z', x: 50, y: 450);
```

Options are named parameters, with the same names and defaults as pdf-lib.
Measure text with `font.widthOfTextAtSize(text, size)` and `font.heightAtSize(size)`.

### Images

```dart
PDFImage png = await doc.embedPng(File('logo.png').readAsBytesSync());
PDFImage jpg = await doc.embedJpg(File('photo.jpg').readAsBytesSync());
page.drawImage(png, x: 50, y: 700, width: 100, height: 50);
({double width, double height}) size = jpg.scaleToFit(200, 200);
page.drawImage(jpg, x: 50, y: 400, width: size.width, height: size.height);
```

PNG files with transparency, palettes, gray and 16-bit colors work.
JPEG files go into the PDF as they are, without new compression.

### Custom fonts and languages

```dart
import 'dart:typed_data';

Uint8List bytes = File('NotoSansThai-Regular.ttf').readAsBytesSync();
PDFFont thai = await doc.embedFont(bytes, subset: true);
page.drawText('สวัสดีครับ', x: 50, y: 700, font: thai, size: 20);
```

- `embedFont` takes TrueType (`.ttf`) and OpenType (`.otf`) files. There is no `registerFontkit`: the font code is built in.
- `subset: true` puts only the letters you use into the file. Use it for big fonts, like Chinese, Japanese and Korean fonts. Without a subset, a 16 MB font makes a PDF of about 14 MB.
- Use `subset: false` for fonts in form fields that people will edit in a PDF viewer. A subset has only the letters known at save time, so the viewer cannot show new letters people type.
- `features` turns OpenType features on or off, for example `features: {'liga': false}`.
- A font file is read once and shared by all documents that use the same bytes.

For Latin, Chinese, Japanese, Korean and other simple scripts, text widths and heights are the same as in pdf-lib with fontkit. So text is measured and wrapped the same way.
Complex scripts, like Thai, Arabic and Hindi, are laid out like HarfBuzz, the standard text engine. Copy and paste from the PDF gives back the text.
Right-to-left text with numbers or English words follows the Unicode rules, like a web browser.

These languages are tested, with full and subset fonts:
English, German, Vietnamese, Japanese, Chinese, Korean, Thai, Myanmar, Khmer, Arabic, Hebrew and Hindi.

### Word breaks in Thai, Lao, Khmer and Myanmar

These scripts have no spaces between words. To wrap such text yourself, you need the places where a word ends. `dictionaryWordBreaks` gives them. It is an extra: pdf-lib does not have it.

```dart
List<int> breaks = dictionaryWordBreaks('ทุกสองสัปดาห์'); // [3, 6]
```

- The result is a sorted list of indexes into the string (UTF-16, like `String.substring`). A word starts at each index.
- The words come from the ICU word lists, with the same rules as ICU. So the breaks are the same as `Intl.Segmenter` with `granularity: 'word'` in Node.js 24 and in browsers.
- Each run of Thai, Lao, Khmer or Myanmar letters is cut into words. The start and the end of a run are not in the list. Other text (spaces, numbers, Latin, Chinese, ...) gives no breaks.
- The word lists make the native library about 1 MB bigger. They load the first time you call the function.

### Forms

Fill a form:

```dart
PDFDocument doc = await PDFDocument.load(File('form.pdf').readAsBytesSync());
PDFForm form = doc.getForm();
form.getTextField('person.name').setText('Jane Doe');
form.getCheckBox('agree').check();
form.getRadioGroup('color').select('green');
form.getDropdown('country').select('Myanmar');
form.flatten(); // optional: draw the fields into the pages
File('filled.pdf').writeAsBytesSync(await doc.save());
```

Create a form:

```dart
PDFDocument doc = await PDFDocument.create();
PDFPage page = doc.addPage();
PDFForm form = doc.getForm();
PDFTextField name = form.createTextField('name');
name.setText('Jane');
name.addToPage(page, x: 50, y: 700, width: 200, height: 24);
PDFCheckBox agree = form.createCheckBox('agree');
agree.addToPage(page, x: 50, y: 650, width: 16, height: 16);
```

Text fields, check boxes, radio groups, dropdowns, option lists, buttons and signatures all work, with the pdf-lib methods.
`save()` updates the look of changed fields, like pdf-lib.
To use a custom font in fields, call `form.updateFieldAppearances(font)`, or pass `font:` to `addToPage`.

### Attachments

```dart
await doc.attach(
  File('data.csv').readAsBytesSync(),
  'data.csv',
  mimeType: 'text/csv',
  description: 'The raw data',
);
for (PDFAttachment file in doc.getAttachments()) {
  print('${file.name}: ${file.data.length} bytes');
}
```

`attach` also takes a base64 string or a data URI.

### Place pages of another PDF

Use another PDF as a background or template:

```dart
PDFDocument out = await PDFDocument.create();
List<PDFEmbeddedPage> pages = await out.embedPdf(
  File('template.pdf').readAsBytesSync(),
);
PDFEmbeddedPage template = pages.first;
PDFPage page = out.addPage(<double>[template.width, template.height]);
page.drawPage(template);
page.drawText('Filled in on top', x: 50, y: 50);
```

- `embedPdf` takes bytes, a base64 string or a loaded `PDFDocument`. `embedPage` and `embedPages` take pages.
- By default `embedPdf` embeds only the first page, like pdf-lib. Pass page indices for more, for example `embedPdf(bytes, [0, 1])`.
- `drawPage` takes `x`, `y`, `xScale`, `yScale`, `width`, `height`, `rotate`, `xSkew`, `ySkew`, `opacity` and `blendMode`.
- To make many files from one template, load the template once and embed its pages into each new document. Shared parts, like fonts, are copied only once per document.

## Coming from pdf-lib

The names are the same. These things change because this is Dart:

| pdf-lib (JavaScript) | dox_pdf_lib (Dart) |
|---|---|
| `page.drawText('Hi', { x: 50, y: 50 })` | `page.drawText('Hi', x: 50, y: 50)` |
| `StandardFonts.TimesRoman` | `StandardFonts.timesRoman` |
| `BlendMode.Multiply`, `LineCapStyle.Round` | `BlendMode.multiply`, `LineCapStyle.round` |
| `PageSizes['4A0']` | `PageSizes.$4A0` |
| `page.drawLine({ start: { x: 0, y: 0 }, ... })` | `page.drawLine(start: (x: 0, y: 0), ...)` |
| `page.getSize()` gives `{ width, height }` | `page.getSize()` gives a record: `.width`, `.height` |
| `page.pushOperators(a, b, c)` | `page.pushOperators([a, b, c])` |
| `doc.registerFontkit(fontkit)` | not needed |
| `field.ref` is a `PDFRef` | `field.ref` is an `int` |

Errors have the pdf-lib names, for example `EncryptedPDFError`, `NoSuchFieldError` and `ExceededMaxLengthError`.
They all extend `PDFLibError`.
Wrong arguments throw Dart's `ArgumentError` or `RangeError`.

## Differences from pdf-lib

This list compares with pdf-lib 1.17.1.
Most of these are fixes or small extras. Most pdf-lib code works the same after you change it to Dart.

### Documents

- The default producer is `dox_pdf_lib (...)`, not `pdf-lib (...)`. `getLanguage()` is an extra.
- Sizes and boxes keep about 7 digits: `595.28` stays `595.28`, `123456.789` becomes `123456.79`.
- A page with no size at all (no MediaBox) reads as US Letter. pdf-lib throws an error.
- NaN and infinity in page sizes and boxes throw an `ArgumentError`.
- There is no low-level object API: no `doc.context`, `doc.catalog`, `PDFDict` or `PDFName`, and no `doc.copy()`.
- A bad page index in `copyPages`, and a file that has only a header, throw clear errors. pdf-lib fails with a `TypeError`.
- `load(..., ignoreEncryption: true)`:
  - A file with only an owner password (it opens with no password) is decrypted. `isEncrypted` stays true. `save()` writes the file without encryption.
  - A file with a user password throws `PDFParsingError`. pdf-lib still lists its pages, but they cannot be read.

### Drawing

- A font, image or opacity setting is added once per page, not once per draw call. Their names are `Helvetica-1`, `Image-1`, `GS-1`, without a random number.
- Pages with no font set share one Helvetica font per document. pdf-lib adds one per page.
- An SVG path with too few numbers (for example `M 1 2 L`) throws an error. pdf-lib draws nothing or writes broken numbers for some of them.
- A font or image of another document throws an `ArgumentError` in `drawText`, `drawImage` and `setFont`.

### Fonts

- Complex scripts (Thai, Lao, Myanmar, Khmer, Indic, Arabic, Hebrew and others) are laid out like HarfBuzz, not like fontkit. fontkit draws some of them wrong or cannot lay them out at all. Their widths are HarfBuzz widths.
- Right-to-left text with numbers or English words follows the Unicode bidi rules. pdf-lib draws numbers in reversed order.
- With `wordBreaks: ['']`, a line never breaks between a letter and its marks.
- pdf-lib gives some glyphs no width, so viewers draw them too wide. Here every glyph gets its real width. Copy and paste works for them too.
- A full OpenType (CFF) font is embedded as OpenType. pdf-lib embeds it as TrueType.
- Font collections (`.ttc`), WOFF files and variable OpenType (CFF2) fonts are not supported. A variable TrueType font uses its default style, like fontkit.

### Forms

- A field with no `/DA` takes it from its parent field or the form, as the PDF standard says.
- `removeField` and `flatten` also remove the widgets from their pages. pdf-lib leaves broken references behind.
- `flatten` skips a broken widget (no page or no look). pdf-lib throws.
- Some options have a short export value and a longer display text, for example `CA` and `Canada`. `select` takes either one and saves the export value. `getSelected` returns the display text. pdf-lib saves the display text.
- A combed text field with more than 1000 cells is drawn as one normal line.
- There are no custom appearance providers. `acroField` is a small read-only view.
- `getForm()` removes XFA data like pdf-lib, but prints no warning.

### Attachments and placed pages

- `getAttachments()` is an extra: pdf-lib cannot read attachments.
- New attachment names are kept in sorted order, as the PDF standard asks. pdf-lib adds them at the end.
- Pages of another document are embedded right away. Embedding the same page twice gives the same result, so it is stored once. Pages of the same document are embedded at save, like pdf-lib.
- If you change a source document after you embed its pages, the next embed sees the change.

## Platforms

dox_pdf_lib works in Dart programs on macOS, Linux and Windows.
It uses `dart:ffi`, so it does not work on the web.
Android and iOS are not supported yet.

**Do you need iOS or Android?** Give a 👍 or a comment on the issue for your platform:

- iOS: [issue #18](https://github.com/dartondox/dox-pdf-lib/issues/18)
- Android: [issue #19](https://github.com/dartondox/dox-pdf-lib/issues/19)

When an issue has requests from 50 users, we add support for that platform.

Ready-built native libraries exist for:

| System | CPU |
|---|---|
| macOS | arm64, x64 |
| Linux | x64, arm64 |
| Windows | x64 |

The Linux libraries are built on Ubuntu 22.04. They need glibc 2.35 or newer, for example Ubuntu 22.04 or Debian 12. On older Linux, or on Alpine (musl), build the library with cargo and set `lib_path` (see below).

On another desktop system, install [Rust](https://rustup.rs). The library is then built from source.
Cross builds (building on one system for another) work only with a ready-built library. cargo and `native/target/release` are used only when you build for the system you are on.

### How the native library is found

A Dart build hook finds the library. It tries these steps in order:

1. A path you set in your app's `pubspec.yaml`:
   ```yaml
   hooks:
     user_defines:
       dox_pdf_lib:
         lib_path: /path/to/libdox_pdf_lib.so
   ```
   Use the file name of your system: `.dylib` on macOS, `.so` on Linux, `.dll` on Windows.
   If the file does not exist, the build fails.
2. From pub.dev: the ready-built library from the GitHub release, checked with SHA-256.
3. A build from source with `cargo`, when Rust is installed.
4. A library that is already in `native/target/release`, when Rust is not installed.
5. As a path or git dependency: the ready-built library from the GitHub release.

As a path or git dependency, cargo comes first, because the source may be newer than the release.

If no step works, the build still passes.
Every PDF call then throws an `ArgumentError` that starts with `Couldn't resolve native function`.

## Thanks

The API comes from [pdf-lib](https://github.com/Hopding/pdf-lib) by Andrew Dillon.
The native core uses [lopdf](https://crates.io/crates/lopdf), [harfrust](https://crates.io/crates/harfrust), [read-fonts](https://crates.io/crates/read-fonts), [subsetter](https://crates.io/crates/subsetter), [png](https://crates.io/crates/png), [flate2](https://crates.io/crates/flate2), [unicode-bidi](https://crates.io/crates/unicode-bidi) and [icu_segmenter](https://crates.io/crates/icu_segmenter) (its word lists of Thai, Lao, Khmer and Myanmar). The word break rules are a port of the ICU4C dictionary break engines (Unicode License V3).

The native library contains code and data of these and other Rust crates. Their licenses and copyright notices are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES). It is also attached to each GitHub release, next to the libraries.

## License

MIT. See [LICENSE](LICENSE).
