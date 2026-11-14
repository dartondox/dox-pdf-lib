// Numbers of pdfme (`@pdfme/common` constants.ts). They are not exact
// inverses of each other, like in pdfme.

/// Millimetres to points. pdfme uses 2.8346, not 72 / 25.4.
const double mmToPtRatio = 2.8346;

/// Points to millimetres. pdfme uses 0.3528.
const double ptToMmRatio = 0.3528;

/// Pixels (96 dpi) to millimetres.
const double pxToMmRatio = 0.26458333333333;

double mm2pt(num mm) => mm * mmToPtRatio;

double pt2mm(num pt) => pt * ptToMmRatio;

double px2mm(num px) => px * pxToMmRatio;

/// The name of the font used when the options have no fonts.
const String defaultFontName = 'Roboto';

/// The default author, creator and producer of the PDF, like pdfme.
const String toolName = 'pdfme (https://pdfme.com/)';
