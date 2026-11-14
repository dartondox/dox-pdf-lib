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
- `load(..., ignoreEncryption: true)`:
  - A file with only an owner password (it opens with no password) is decrypted. You can read its text and info. `isEncrypted` stays true. `save()` writes an unencrypted file.
  - A file with a user password throws `PDFParsingError`. Its objects can not be read without the password. pdf-lib still lists the pages.

Big files load and save on a native thread, so they do not block the event loop.

## Status

Ready now: documents, pages, page boxes and rotation, copy and merge, metadata.
Next: drawing (text, shapes, images), fonts, forms, attachments and embedded pages.

## The native library

A build hook (`hook/build.dart`) gets the Rust library. It tries these in order:

1. A path you set in your app `pubspec.yaml` (`hooks: user_defines: dox_pdf_lib: lib_path: ...`).
2. A ready-built library from the GitHub release, checked with sha256.
3. A build from source with `cargo`. This needs [Rust](https://rustup.rs).

Ready-built libraries exist for macOS (arm64, x64), Linux (x64, arm64) and Windows (x64).
On these systems you do not need Rust.

## Thanks

The API comes from [pdf-lib](https://github.com/Hopding/pdf-lib) by Andrew Dillon (MIT).
