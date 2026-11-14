## Unreleased

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
- PDF417 has the same modules as in pdfme. The `barcode` package picked
  other columns, rows and codewords, so the code was wider and lower than
  in pdfme and did not fill a box made for it. Now a port of the bwip-js
  (BWIPP) encoder makes the symbol.
- 2D codes (QR code, Data Matrix, PDF417) put their module edges on the
  same grid as bwip-js, so small codes look the same as in pdfme.

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
