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
- `embedFont` takes `StandardFonts` only for now. Custom font files come later.

## Status

Ready now: documents, pages, page boxes and rotation, copy and merge, metadata.
Next: drawing (text, shapes, images), fonts, forms, attachments and embedded pages.
Drawing is ready too: text with the 14 standard fonts, shapes, SVG paths, JPEG and PNG images.

## The native library

A build hook (`hook/build.dart`) gets the Rust library. It tries these in order:

1. A path you set in your app `pubspec.yaml` (`hooks: user_defines: dox_pdf_lib: lib_path: ...`).
2. A ready-built library from the GitHub release, checked with sha256.
3. A build from source with `cargo`. This needs [Rust](https://rustup.rs).

Ready-built libraries exist for macOS (arm64, x64), Linux (x64, arm64) and Windows (x64).
On these systems you do not need Rust.

## Thanks

The API comes from [pdf-lib](https://github.com/Hopding/pdf-lib) by Andrew Dillon (MIT).
