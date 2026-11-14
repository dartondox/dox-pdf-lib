## Unreleased

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
