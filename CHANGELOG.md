## Unreleased

- First version. The core of the pdf-lib API, with a Rust core (lopdf):
  - `PDFDocument.create`, `load` (with `ignoreEncryption` and `updateMetadata`), `save` (with `useObjectStreams` and `addDefaultPage`), `saveAsBase64`.
  - Pages: `addPage`, `insertPage`, `removePage`, `getPages`, `getPage`, `getPageCount`, `getPageIndices`, `copyPages` (merge PDFs).
  - `PDFPage`: size, rotation and the media, crop, bleed, trim and art boxes.
  - Metadata: title, author, subject, keywords, creator, producer, creation and modification date, language.
  - `PageSizes`, `degrees`, `radians`, `rgb`, `cmyk`, `grayscale`.
  - Errors with the pdf-lib names, eg. `EncryptedPDFError`.
