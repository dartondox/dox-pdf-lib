## Unreleased

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
