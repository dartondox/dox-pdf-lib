## Unreleased

- New schema types, like in pdfme: `multiVariableText` (a text with
  `{name}` variables, the input is a JSON object of values), `signature`
  (drawn like an image) and `circleMark` (a circle line when the input is
  `'true'`). They are in `builtInPlugins`.
- PDF417 has the same modules as in pdfme. The `barcode` package picked
  other columns, rows and codewords, so the code was wider and lower than
  in pdfme and did not fill a box made for it. Now a port of the bwip-js
  (BWIPP) encoder makes the symbol.
- 2D codes (QR code, Data Matrix, PDF417) put their module edges on the
  same grid as bwip-js, so small codes look the same as in pdfme.
- QR codes have the same modules as in pdfme. bwip-js raises the error
  correction level when the data still fits the same size, picks the mask
  with its own scores and mixes number, letter and byte segments (never
  kanji). The `barcode` package did not, so the codes looked different.
  Now a port of the bwip-js (BWIPP) encoder makes the symbol.
- Barcode values that pass pdfme's check but that bwip-js refuses make
  `generate` throw a `BarcodeInputException` with the bwip-js message,
  like pdfme. Before, they drew a code or nothing. Eg. GS1 Data Matrix data
  that breaks the GS1 rules (unknown AI, too long, bad date or check
  digit, AIs that exclude or need each other), a lowercase NW-7 start or
  stop letter, too long Code 128, Japan Post or PDF417 data, and text with
  a lone UTF-16 surrogate (`URI malformed`).
- GS1 Data Matrix has the same modules and size as in pdfme. Letters now
  use C40, Text, X12 and EDIFACT like bwip-js, so a value with many letters
  is no longer one size bigger.
- Code 128 has the same bars as in pdfme. The `barcode` package started
  some texts (like `HELLO` or `12345`) in another code set. Text with
  letters like `é` works now.
- The bearer box of ITF-14 is black, like in pdfme. It had the bar color.
- Date formats: all date-fns tokens work, like `do` (`7th`), `PPP` (`May
  7th, 2024`), `Q`, `w` and `B`. Other tokens made the format fall back to
  the default format. `iiii` gives the full day name (it gave `Tue`).
  Seven or more `S` (like `ss.SSSSSSS`) made `generate` crash.
- The crosscheck with pdfme compares every schema box on its own: the ink
  box (place and size) and the pixels, with tight limits per type, and the
  bars of linear barcodes. It has many new variants of every type.

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
