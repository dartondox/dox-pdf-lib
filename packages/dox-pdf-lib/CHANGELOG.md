## Unreleased

- The ready-built Linux libraries do not need `libgcc_s.so.1`. They need only glibc 2.34 or newer, as before. A `FROM scratch` Docker image with the Dart `/runtime/` files does not need a copy of `libgcc_s.so.1` for this package. The release build now links the Linux libraries with `cargo zigbuild`, and CI does a check of each library.

## 0.0.3

- New: PDF/X and PDF/A. `setConformance(standard, iccProfile: ..., outputConditionIdentifier: ...)` sets up a document for PDF/X-1a, PDF/X-3, PDF/X-4, PDF/A-1b, PDF/A-2b, PDF/A-2u, PDF/A-3b or PDF/A-3u: the output intent now, and at save the PDF version, the file `/ID`, XMP metadata in sync with the document info, and the PDF/X info keys. `checkConformance(standard)` lists what is still wrong in your content (fonts not embedded, transparency, colors, page boxes, annotations, actions, attachments, ...), with the page and a plain message. The default save is not changed. See "PDF/X and PDF/A" in the README.
- New: `addOutputIntent`, `setXmpMetadata`, `getXmpMetadata` and `createXmpMetadata`.
- New: custom document info keys: `setCustomMetadata`, `getCustomMetadata`, `getCustomMetadataKeys`, `removeCustomMetadata`. And `setTrapped` / `getTrapped`.
- Fix: in a debug build of the native library, the Thai, Lao, Khmer and Myanmar dictionaries did not load, so `dictionaryWordBreaks` found no breaks inside those words. The code found the dictionary by the address of a constant, and a debug build can copy a constant. It now finds it by name. The release library was not affected.
- New fuzz target `conformance` (ICC profile header and XMP text). The `load` target also runs `checkConformance`.

## 0.0.2

- Fix: `embedPng` with a broken palette (its length is not a multiple of 3) now throws an "Invalid PNG" error. Before, the png crate panicked inside (the panic was caught, but the message was an internal error). Found by the image fuzz target.
- New: `dictionaryWordBreaks(text)` gives the word breaks inside Thai, Lao, Khmer and Myanmar text, the same as `Intl.Segmenter` of Node.js and browsers (ICU word lists and break rules). It is an extra, not part of pdf-lib. The native library is about 1 MB bigger.
- New: `THIRD_PARTY_NOTICES` with the licenses of the code and data in the native library (ICU, ICU4X and all Rust crates). It is in the package and in each GitHub release.
- The ready-built libraries now come from the GitHub release with the tag `dox_pdf_lib-v<version>` (it was `v<version>`). The repo is now a workspace with more packages, and each package has its own tags.

## 0.0.1

- First version. The core of the pdf-lib API, with a Rust core (lopdf):
  - `PDFDocument.create`, `load` (with `ignoreEncryption` and `updateMetadata`), `save` (with `useObjectStreams` and `addDefaultPage`), `saveAsBase64`.
  - Pages: `addPage`, `insertPage`, `removePage`, `getPages`, `getPage`, `getPageCount`, `getPageIndices`, `copyPages` (merge PDFs).
  - `PDFPage`: size, rotation and the media, crop, bleed, trim and art boxes.
  - Metadata: title, author, subject, keywords, creator, producer, creation and modification date, language.
  - `PageSizes`, `degrees`, `radians`, `rgb`, `cmyk`, `grayscale`.
  - Errors with the pdf-lib names, eg. `EncryptedPDFError`.
- Drawing, like pdf-lib:
  - `StandardFonts`, `embedFont` / `embedStandardFont`, `PDFFont` (`widthOfTextAtSize`, `heightAtSize`, `sizeAtHeight`, `getCharacterSet`, `encodeText`). Widths match pdf-lib exactly.
  - `PDFPage.drawText` (with `maxWidth` and `wordBreaks`), `drawRectangle`, `drawSquare`, `drawEllipse`, `drawCircle`, `drawLine`, `drawSvgPath`, `drawImage`, opacity and blend modes.
  - Page text state: `setFont`, `setFontSize`, `setFontColor`, `setLineHeight`, `moveTo` and friends, `resetPosition`. Page changes: `translateContent`, `scale`, `scaleContent`, `scaleAnnotations`.
  - `embedJpg` and `embedPng` (palette, gray, 16-bit, interlaced, alpha), `PDFImage` (`scale`, `scaleToFit`, `size`).
  - `pushOperators` with the pdf-lib operator helpers (`moveTo`, `lineTo`, `setFillingColor`, ...).
- Attachments: `attach` (bytes or base64, with `mimeType`, `description`, `creationDate`, `modificationDate`, `afRelationship`). The name tree is kept sorted. Extra: `getAttachments` reads them back.
- Embedded pages: `embedPdf`, `embedPage`, `embedPages`, `PDFEmbeddedPage` (`width`, `height`, `scale`, `size`) and `page.drawPage` (`x`, `y`, `xScale`, `yScale`, `width`, `height`, `rotate`, `xSkew`, `ySkew`, `opacity`, `blendMode`). The same source page embedded twice gives the same XObject.
- Forms, like pdf-lib:
  - `getForm`, `PDFForm` (`getFields`, `getField`, `getTextField` and the other getters, `create...` for every field type, `removeField`, `flatten`, `updateFieldAppearances`, `getDefaultFont`, XFA).
  - `PDFTextField`, `PDFCheckBox`, `PDFRadioGroup`, `PDFDropdown`, `PDFOptionList`, `PDFButton`, `PDFSignature` with the pdf-lib methods and flags, and `addToPage`.
  - Appearance streams like pdf-lib's default providers. `save` updates them.
- Custom fonts, like pdf-lib with @pdf-lib/fontkit: `embedFont` with TrueType and OpenType (CFF) files, `subset`, `customName` and `features`. Text layout and metrics match fontkit (checked against pdf-lib in `test/font_crosscheck_test.dart`). No `registerFontkit` is needed. Complex scripts (Thai, Myanmar, Khmer, Arabic, Hindi, ...) are laid out and placed like HarfBuzz, with `/ActualText` for copy and paste. Custom fonts also work in form fields. Right-to-left text with numbers and Latin words follows the Unicode bidi algorithm. A font file is read once per process and shared by documents.
