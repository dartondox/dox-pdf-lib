# dox_pdf_lib

Create and edit PDF files in Dart, with the same API as the JavaScript library [pdf-lib](https://pdf-lib.js.org).
The work is done by a small Rust core (built on [lopdf](https://crates.io/crates/lopdf)), so it is fast.

It is a plain Dart package. It does not need any framework.

## Install

```bash
dart pub add dox_pdf_lib
```

## Use

```dart
import 'dart:io';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

Future<void> main() async {
  // merge two PDFs
  PDFDocument a = await PDFDocument.load(File('a.pdf').readAsBytesSync());
  PDFDocument b = await PDFDocument.load(File('b.pdf').readAsBytesSync());
  PDFDocument merged = await PDFDocument.create();
  for (PDFDocument src in <PDFDocument>[a, b]) {
    for (PDFPage page in await merged.copyPages(src, src.getPageIndices())) {
      merged.addPage(page);
    }
  }
  merged.setTitle('Merged');
  merged.addPage(PageSizes.Letter).setRotation(degrees(90));
  File('merged.pdf').writeAsBytesSync(await merged.save());
}
```

The names and defaults follow pdf-lib. Some small differences, because this is Dart:

- `addPage` takes a `PDFPage` or a `[width, height]` list.
- `PageSizes['4A0']` is `PageSizes.$4A0` (a Dart name can not start with a digit).
- Sizes and boxes are records, eg. `page.getSize().width`.
- `getLanguage()` exists too.
- The default producer is `dox_pdf_lib (...)`, not `pdf-lib (...)`.
- A document is freed when it is garbage collected. Call `dispose()` to free it at once.
- Sizes and boxes are stored with about 7 significant digits (eg. `595.28` stays `595.28`, `12345.678` becomes `12345.68`). pdf-lib keeps more digits. The PDF library under the hood stores real numbers as 32-bit floats.
- A page with no MediaBox at all reads as US Letter (612 x 792). pdf-lib throws an error.
- NaN and infinity in sizes and boxes throw an `ArgumentError`.
- `attach` inserts the file name sorted in the `/EmbeddedFiles` name tree, as the PDF spec asks. pdf-lib appends it at the end.
- `getAttachments()` exists too. pdf-lib can not read attachments.
- A page of another document is embedded at once by `embedPdf`, `embedPage` and `embedPages`; pdf-lib does it at save. The same source page (with the same box and matrix) embedded twice gives the same embedded page. A page of the same document is embedded at save, like pdf-lib.
- `load(..., ignoreEncryption: true)`:
  - A file with only an owner password (it opens with no password) is decrypted. You can read its text and info. `isEncrypted` stays true. `save()` writes an unencrypted file.
  - A file with a user password throws `PDFParsingError`. Its objects can not be read without the password. pdf-lib still lists the pages.

Big files load and save on a native thread, so they do not block the event loop.

### Draw

```dart
PDFDocument doc = await PDFDocument.create();
PDFFont font = await doc.embedFont(StandardFonts.timesRoman);
PDFImage logo = await doc.embedPng(File('logo.png').readAsBytesSync());
PDFPage page = doc.addPage();
page.drawText('Hello', x: 50, y: 750, font: font, size: 30, color: rgb(0, 0.5, 1));
page.drawImage(logo, x: 50, y: 600, width: 100, height: 50);
page.drawRectangle(x: 50, y: 400, width: 200, height: 100, borderColor: rgb(1, 0, 0), borderWidth: 2);
page.drawSvgPath('M 0,20 L 100,160 Q 130,200 150,120', x: 50, y: 300);
File('out.pdf').writeAsBytesSync(await doc.save());
```

Drawing options are named parameters with the pdf-lib names and defaults. Some small differences:

- Enum values are camelCase: `StandardFonts.timesRoman`, `BlendMode.multiply`, `LineCapStyle.round`.
- `drawLine` takes records: `start: (x: 0, y: 0)`.
- `pushOperators` takes a list: `page.pushOperators([pushGraphicsState(), ...])`.
- A font, image or graphics state (opacity, blend mode) is added once per page, not once per draw call. Resource names are `Helvetica-1`, `Image-1`, `GS-1` (pdf-lib adds a random number).
- Pages with no font set share one Helvetica per document (pdf-lib embeds one per page).

### Custom fonts

```dart
Uint8List bytes = File('NotoSansJP-Regular.otf').readAsBytesSync();
PDFFont font = await doc.embedFont(bytes, subset: true);
page.drawText('日本語のテキスト', x: 50, y: 700, font: font, size: 20);
double width = font.widthOfTextAtSize('日本語', 20);
```

`embedFont` takes TrueType and OpenType (CFF) files, like pdf-lib with fontkit, with the options `subset`, `customName` and `features` (eg. `{'liga': false}`).
The font code is built in, so there is no `registerFontkit`.
Text layout (ligatures and the other default OpenType features) and all metrics are the same as fontkit, so `widthOfTextAtSize` and `heightAtSize` give the same numbers as pdf-lib.
Complex scripts (Thai, Lao, Myanmar, Khmer, Indic, Arabic, Hebrew and others) are laid out and drawn as HarfBuzz does it; see below.
The font is read once; a subset is made when you save. A subset of a big CJK font (16 MB, 200 characters) takes about 25 ms.

Use `subset: true` for big fonts, eg. CJK fonts. Without it, the whole font goes into the file: a 16 MB font makes a 14 MB PDF, and the first save takes about 0.4 s to compress it.

Custom fonts work in form fields too: `form.updateFieldAppearances(font)`, `field.updateAppearances(font)` and `addToPage(page, font: font)`.
Use `subset: false` for a font of fillable fields that people will edit in a PDF viewer: a subset has only the glyphs of the text at save, so the viewer can not draw other letters that people type.

A font file is read once per process: embedding the same bytes into another document reuses it (about 1 ms for a 16 MB font). It is freed when no document uses it.

Tested languages, with full and subset fonts (`test/language_test.dart`): English, German, Vietnamese, Japanese, Chinese, Korean, Thai, Myanmar, Khmer, Arabic (also with numbers and English), Hebrew and Hindi. Copy and paste (`pdftotext`) gives the text back in all of them.

Differences from pdf-lib:

- A full OpenType/CFF font is embedded as `FontFile3` (`/OpenType`). pdf-lib embeds it as a TrueType `FontFile2`.
- The widths (`/W`) of a full font also have the glyphs that layout makes but the cmap has not (eg. some ligatures and alternate digits). The widths of a subset also have `.notdef`. pdf-lib leaves them out, so viewers draw these glyphs 1000 units wide.
- The ToUnicode CMap of a full font also has these glyphs, so copy and paste works for them.
- The `BaseFont` name is `<PostScript name>-<n>`; pdf-lib adds a random number.
- Text layout uses harfrust (HarfBuzz in Rust). It gives the same glyphs as fontkit for normal text.
- Right-to-left text (Arabic, Hebrew) with numbers or Latin words is ordered with the Unicode bidi algorithm (UAX #9), like a browser. pdf-lib draws the whole line right to left, so numbers come out reversed.
- Complex scripts are laid out like HarfBuzz (`hb-shape`), not like fontkit. fontkit can not lay out some of them right (eg. Thai, Myanmar) or at all (Khmer). Their widths are HarfBuzz's advances, and `drawText` places each glyph where HarfBuzz puts it (`TJ`, `Ts`), so marks sit in the right place. Their text is in `/ActualText` spans (one per word, one per letter in right-to-left text), so copy and paste gives the text.
- With `wordBreaks: ['']`, a line never breaks between a letter and its marks. pdf-lib breaks between any two characters.
- Font collections (`.ttc`), WOFF and CFF2 (variable OpenType) fonts are not supported. A variable TrueType font uses its default instance, like fontkit.

### Forms

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

Text fields, check boxes, radio groups, dropdowns, option lists, buttons and signatures, with the pdf-lib methods. `createTextField(...)` and the other `create` methods make new fields, and `addToPage` adds them to a page. Appearances are made like pdf-lib's default providers, and `save()` updates them (`updateFieldAppearances: true`). Some small differences:

- `addToPage` options are named parameters. Refs (`field.ref`, `markFieldAsDirty(ref)`) are `int`.
- `acroField` is a small read-only view: `getWidgets()` (rectangle, page, on value, state) and `getFullyQualifiedName()`.
- No custom appearance providers: `updateAppearances(font)` uses the default one.
- A field with no `/DA` takes it from its parent field or the AcroForm, as the PDF spec says. pdf-lib reads only the field's own `/DA`.
- `removeField` and `flatten` also take the widgets out of the `/Annots` of their pages. pdf-lib leaves references to deleted objects there.
- A broken widget (no page, no appearance) is skipped by `flatten`. pdf-lib throws.
- Dropdown and option list options with an export value and a display text (`/Opt [[(CA) (Canada)]]`): `select` takes the display text or the export value, writes the export value to `/V`, and `getSelected` returns the display text. pdf-lib writes the display text to `/V` and returns `/V` as it is.
- A combed text field with more than 1000 cells (`/MaxLen`) is drawn as one normal line.
- `getForm()` removes XFA data like pdf-lib, but prints no warning.

## Status

Ready now: documents, pages, page boxes and rotation, copy and merge, metadata.
Next: drawing (text, shapes, images), fonts, forms, attachments and embedded pages.
Drawing is ready too: text with the 14 standard fonts or custom fonts (TrueType, OpenType, subsets), shapes, SVG paths, JPEG and PNG images.
Forms are ready too: read, fill, create and flatten fields.

## The native library

A build hook (`hook/build.dart`) gets the Rust library. It tries these in order:

1. A path you set in your app `pubspec.yaml` (`hooks: user_defines: dox_pdf_lib: lib_path: ...`).
2. A ready-built library from the GitHub release, checked with sha256.
3. A build from source with `cargo`. This needs [Rust](https://rustup.rs).

Ready-built libraries exist for macOS (arm64, x64), Linux (x64, arm64) and Windows (x64).
On these systems you do not need Rust.

## Thanks

The API comes from [pdf-lib](https://github.com/Hopding/pdf-lib) by Andrew Dillon (MIT).
