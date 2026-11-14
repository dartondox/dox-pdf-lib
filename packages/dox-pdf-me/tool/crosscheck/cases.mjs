// The templates of the crosscheck. render.mjs draws them with pdfme, and
// writes them as cases.json for test/crosscheck_test.dart, which draws them
// with dox_pdf_me.
//
// The Dart test compares each schema box on its own (its ink box and its
// pixels, with limits per type), the bars of linear barcodes, and the whole
// page. `compare` changes that a little:
// - 'pixels': the default.
// - 'barcode': the human readable text of linear barcodes is OCR-B in
//   pdfme and Helvetica here, so more of the page may differ.
// - 'reencoded': images with an EXIF orientation. pdfme decodes, turns and
//   encodes them again (JPEG quality 90); we turn them with a transform. The
//   colors near the edges of the blocks differ a little.
// - 'lines': Thai, Lao, Khmer and Myanmar text. Every line must have the
//   same base letters at the same place (test/crosscheck_test.dart reads
//   them with pdftotext). The letters are shaped by other code (fontkit in
//   pdfme, HarfBuzz rules here): marks sit in other places, and fontkit
//   does not reorder some Myanmar vowels. So more pixels may differ.
// - 'matrix': 2D codes (QR, Data Matrix, PDF417). With zbarimg installed,
//   the codes of both sides are decoded and must give the same text.

import { saSentences } from './sa_text.mjs';
import { fieldCases } from './field_cases.mjs';
import { tableCases } from './table_cases.mjs';

const blank = (staticSchema) => ({
  width: 150,
  height: 100,
  padding: [5, 5, 5, 5],
  ...(staticSchema ? { staticSchema } : {}),
});

let id = 0;
const box = (type, x, y, width, height, props = {}) => ({
  name: `${type}${++id}`,
  type,
  position: { x, y },
  width,
  height,
  ...props,
});

const latin =
  'The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.';
const roboto = { data: { $default: true }, fallback: true };
const fonts = {
  Roboto: roboto,
  Lato: { data: { $file: 'Lato-Regular.ttf' } },
  NotoSansJP: { data: { $file: 'NotoSansJP-Regular.otf' } },
  NotoSansThai: { data: { $file: 'NotoSansThai-Regular.ttf' } },
  NotoSansLao: { data: { $file: 'NotoSansLao-Regular.ttf' } },
  NotoSansKhmer: { data: { $file: 'NotoSansKhmer-Regular.ttf' } },
  NotoSansMyanmar: { data: { $file: 'NotoSansMyanmar-Regular.ttf' } },
};

/** One page of schemas, with the input of each schema named in `values`. */
function page(schemas, values) {
  const input = {};
  schemas.forEach((s, i) => {
    if (values[i] !== undefined) input[s.name] = values[i];
  });
  return { schemas, input };
}

function single(name, schemas, values, extra = {}) {
  const p = page(schemas, values);
  return {
    name,
    compare: 'pixels',
    template: { basePdf: blank(), schemas: [p.schemas] },
    inputs: [p.input],
    ...extra,
  };
}

const textBasic = [
  box('text', 5, 5, 60, 10),
  box('text', 70, 5, 75, 10, { fontSize: 20, fontColor: '#1565c0' }),
  box('text', 5, 18, 45, 25, { alignment: 'center', backgroundColor: '#ffeecc' }),
  box('text', 52, 18, 45, 25, { alignment: 'right', verticalAlignment: 'middle' }),
  box('text', 100, 18, 45, 25, { alignment: 'justify', verticalAlignment: 'bottom' }),
  box('text', 5, 46, 45, 22, { lineHeight: 1.6, characterSpacing: 1.5, fontSize: 10 }),
  box('text', 52, 46, 45, 22, { underline: true, strikethrough: true, fontSize: 11 }),
  box('text', 100, 46, 45, 22, {
    borderColor: '#2e7d32',
    borderWidth: { top: 1, right: 0.5, bottom: 2, left: 3 },
    padding: { top: 2, right: 2, bottom: 2, left: 2 },
    fontSize: 10,
  }),
  box('text', 10, 74, 50, 12, { rotate: 30, backgroundColor: '#e0f7fa', underline: true }),
  box('text', 70, 72, 35, 20, { opacity: 0.5, fontColor: '#ff000080', fontSize: 16 }),
  box('text', 110, 72, 35, 20, { rotate: 270, alignment: 'center', fontSize: 9 }),
];

const textDynamic = [
  box('text', 5, 5, 60, 20, { dynamicFontSize: { min: 4, max: 40, fit: 'vertical' } }),
  box('text', 70, 5, 75, 20, { dynamicFontSize: { min: 4, max: 40, fit: 'vertical' } }),
  box('text', 5, 30, 60, 30, { dynamicFontSize: { min: 6, max: 30, fit: 'horizontal' } }),
  box('text', 70, 30, 75, 30, {
    dynamicFontSize: { min: 5, max: 25 },
    lineHeight: 1.3,
    characterSpacing: 0.5,
  }),
  box('text', 5, 65, 140, 30, {
    dynamicFontSize: { min: 3, max: 8, fit: 'vertical' },
    fontSize: 20,
    padding: { top: 3, left: 3, right: 3, bottom: 3 },
    borderColor: '#999999',
    borderWidth: { top: 0.3, right: 0.3, bottom: 0.3, left: 0.3 },
  }),
];

const textWrap = [
  box('text', 5, 5, 45, 40, { fontSize: 11 }),
  box('text', 55, 5, 45, 40, { fontSize: 11, alignment: 'right' }),
  box('text', 105, 5, 40, 40, { fontSize: 11, alignment: 'justify' }),
  box('text', 5, 50, 45, 45, { fontSize: 10 }),
  box('text', 55, 50, 90, 45, { fontSize: 10, lineHeight: 1.2 }),
];

const textFonts = [
  box('text', 5, 5, 140, 12, { fontName: 'Lato', fontSize: 14 }),
  box('text', 5, 20, 140, 25, { fontName: 'NotoSansJP', fontSize: 12 }),
  box('text', 5, 48, 140, 12, { fontName: 'NotoSansThai', fontSize: 14 }),
  box('text', 5, 63, 140, 30, { fontName: 'NotoSansJP', fontSize: 11, alignment: 'center' }),
];

const shapes = [
  box('line', 5, 5, 60, 1, { color: '#000000' }),
  box('line', 70, 8, 70, 2, { color: '#d32f2f80', rotate: 20 }),
  box('rectangle', 5, 15, 40, 25, { color: '#bbdefb', borderColor: '#0d47a1', borderWidth: 1 }),
  box('rectangle', 50, 15, 40, 25, { color: '', borderColor: '#000000', borderWidth: 0.5, radius: 5 }),
  box('rectangle', 100, 15, 40, 25, { color: '#c8e6c9', rotate: 45, opacity: 0.6 }),
  box('ellipse', 5, 50, 40, 25, { color: '#ffe0b2', borderColor: '#e65100', borderWidth: 2 }),
  box('ellipse', 55, 50, 30, 30, { color: '#f8bbd0', rotate: 30 }),
  box('ellipse', 100, 50, 40, 20, { borderColor: '#4a148c', borderWidth: 1, rotate: 60 }),
  box('rectangle', 5, 82, 60, 12, { color: '#00000040', borderColor: '#ff0000', borderWidth: 0.8, radius: 3 }),
];

const png = { $file: 'image.png', prefix: 'data:image/png;base64,' };
const jpg = { $file: 'image.jpg', prefix: 'data:image/jpeg;base64,' };
const images = [
  box('image', 5, 5, 40, 40),
  box('image', 50, 5, 40, 40, { objectFit: 'cover' }),
  box('image', 95, 5, 50, 20, { objectPosition: 'left top' }),
  box('image', 95, 28, 50, 20, { objectPosition: 'right bottom' }),
  box('image', 5, 52, 30, 40, { rotate: 25 }),
  box('image', 45, 52, 40, 40, { objectFit: 'cover', rotate: 15, opacity: 0.7 }),
  box('image', 95, 52, 50, 40, { objectPosition: 'center top' }),
];

// EXIF orientation 3, 6 and 8 (JPEG) and 6 (PNG): pdfme turns the pixels
const exif = (name, type) => ({ $file: name, prefix: `data:image/${type};base64,` });
const oriented = [
  box('image', 5, 5, 30, 40),
  box('image', 40, 5, 30, 40),
  box('image', 75, 5, 30, 40),
  box('image', 110, 5, 35, 40),
  box('image', 5, 55, 60, 35, { objectFit: 'cover', rotate: 20 }),
  box('image', 75, 55, 60, 35, { objectPosition: 'right bottom', opacity: 0.6 }),
];

const svgSample =
  '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="60" viewBox="0 0 100 60">' +
  '<rect x="2" y="2" width="96" height="56" fill="#fff3e0" stroke="#e65100" stroke-width="2"/>' +
  '<circle cx="25" cy="30" r="15" fill="#42a5f5"/>' +
  '<ellipse cx="60" cy="30" rx="12" ry="20" fill="none" stroke="#2e7d32" stroke-width="3"/>' +
  '<line x1="75" y1="10" x2="95" y2="50" stroke="#000" stroke-width="2" stroke-linecap="round"/>' +
  '<polygon points="80,50 90,35 98,50" fill="#ab47bc" fill-opacity="0.6"/>' +
  '<g transform="translate(5 45) rotate(-10)"><path d="M0 0 L15 0 Q20 5 15 10 Z" fill="#d81b60"/></g>' +
  '</svg>';
const svgs = [
  box('svg', 5, 5, 60, 36),
  box('svg', 75, 5, 70, 36),
  box('svg', 20, 50, 50, 30, { rotate: 20 }),
  box('svg', 90, 50, 30, 40),
];

const checks = [
  box('checkbox', 5, 5, 10, 10, { color: '#000000' }),
  box('checkbox', 20, 5, 10, 10, { color: '#1565c0' }),
  box('checkbox', 35, 5, 10, 10, { color: '#d32f2f' }),
  box('checkbox', 50, 5, 10, 10),
  box('radioGroup', 5, 25, 10, 10, { color: '#000000', group: 'g1' }),
  box('radioGroup', 20, 25, 10, 10, { color: '#2e7d32', group: 'g1' }),
  box('radioGroup', 35, 25, 10, 10, { color: '#6a1b9a', group: 'g1' }),
  box('checkbox', 70, 5, 20, 12, { color: '#000000' }),
];

const dates = [
  box('date', 5, 5, 60, 10, { format: 'yyyy/MM/dd' }),
  box('date', 70, 5, 75, 10, { format: 'EEEE, MMMM d, yyyy', alignment: 'right' }),
  box('date', 5, 20, 60, 10, {}),
  box('time', 70, 20, 75, 10, { format: 'HH:mm' }),
  box('time', 5, 35, 60, 10, { format: 'hh:mm aa', backgroundColor: '#eeeeee' }),
  box('dateTime', 70, 35, 75, 10, { format: 'yyyy-MM-dd HH:mm' }),
  box('dateTime', 5, 50, 60, 10, {}),
  box('date', 70, 50, 75, 10, { locale: 'ja' }),
  box('date', 5, 65, 60, 12, { format: 'dd.MM.yyyy', fontSize: 18, alignment: 'center' }),
  box('select', 70, 65, 75, 12, { options: ['One', 'Two'], fontSize: 14 }),
];

const ean = (type, value, x, y, extra = {}) =>
  box(type, x, y, 40, 20, { barColor: '#000000', backgroundColor: '#ffffff', ...extra });
const barcodes1d = [
  ean('ean13', '2112345678900', 5, 5),
  ean('ean8', '02345673', 50, 5),
  ean('upca', '416000336108', 95, 5),
  ean('upce', '00123457', 5, 30),
  ean('code39', 'THIS IS CODE 39', 50, 30),
  ean('nw7', 'A0123456789B', 95, 30),
  ean('itf14', '04601234567893', 5, 55),
  ean('code128', 'This is Code 128!', 50, 55),
  box('japanpost', 95, 55, 50, 12, {}),
  ean('ean13', '2112345678900', 5, 80, { includetext: false, height: 15 }),
  ean('code128', 'Dox 123', 50, 80, { barColor: '#1565c0', textColor: '#d32f2f', backgroundColor: '#fff9c4', height: 15 }),
  ean('code39', 'ROTATED', 100, 78, { rotate: 90, width: 30, height: 15 }),
];
const barcodeValues = [
  '2112345678900', '02345673', '416000336108', '00123457', 'THIS IS CODE 39',
  'A0123456789B', '04601234567893', 'This is Code 128!', '6540123789-A-K-Z',
  '2112345678900', 'Dox 123', 'ROTATED',
];

const barcodes2d = [
  box('qrcode', 5, 5, 30, 30, { barColor: '#000000', backgroundColor: '#ffffff' }),
  box('qrcode', 45, 5, 40, 30, { barColor: '#0d47a1' }),
  box('gs1datamatrix', 95, 5, 30, 30, {}),
  box('pdf417', 5, 45, 80, 30, {}),
  box('qrcode', 100, 50, 25, 25, { rotate: 30 }),
];

// PDF417 keeps its natural width : height in the box (like pdfme): a tall
// box, a wide box and a small one
const pdf417s = [
  box('pdf417', 5, 5, 40, 90, {}),
  box('pdf417', 50, 5, 95, 25, {}),
  box('pdf417', 50, 35, 60, 40, { barColor: '#1565c0', backgroundColor: '#fff9c4' }),
  box('pdf417', 115, 35, 30, 55, { rotate: 90 }),
];

const multi = (() => {
  const p1 = [
    box('text', 10, 10, 120, 12, { fontSize: 16, required: true }),
    box('qrcode', 10, 30, 30, 30, {}),
    box('rectangle', 50, 30, 60, 30, { color: '#e3f2fd', borderColor: '#1565c0', borderWidth: 1 }),
  ];
  const p2 = [
    box('text', 10, 10, 120, 40, {}),
    box('text', 10, 55, 120, 12, { readOnly: true, content: 'Hello {customer}, total {amount}', fontColor: '#2e7d32' }),
  ];
  const statics = [
    { name: 'header', type: 'text', position: { x: 5, y: 2 }, width: 140, height: 6, readOnly: true, content: 'Page {currentPage} of {totalPages}', fontSize: 9, alignment: 'right' },
    { name: 'footerLine', type: 'line', position: { x: 5, y: 95 }, width: 140, height: 0.4, color: '#999999', readOnly: true },
  ];
  return {
    name: 'multi-page',
    compare: 'matrix',
    template: { basePdf: blank(statics), schemas: [p1, p2] },
    inputs: [
      { [p1[0].name]: 'First copy', [p1[1].name]: 'https://pdfme.com', [p2[0].name]: latin, customer: 'Ann', amount: '12.50' },
      { [p1[0].name]: 'Second copy', [p1[1].name]: 'dox', [p2[0].name]: 'Short text', customer: 'Bob', amount: '7' },
    ],
  };
})();

const basePdf = (() => {
  const p1 = [
    box('text', 15, 15, 100, 10, { fontSize: 14, fontColor: '#c62828' }),
    box('rectangle', 15, 30, 40, 20, { color: '#fff59d' }),
  ];
  const p2 = [
    box('text', 5, 5, 80, 10, { fontSize: 12 }),
    box('ellipse', 10, 20, 30, 20, { borderColor: '#000000', borderWidth: 0.5 }),
  ];
  return {
    name: 'base-pdf',
    compare: 'pixels',
    template: { basePdf: { $file: 'base.pdf', prefix: 'data:application/pdf;base64,' }, schemas: [p1, p2] },
    inputs: [
      { [p1[0].name]: 'On the base PDF', [p2[0].name]: 'Crop box page' },
      { [p1[0].name]: 'Second input', [p2[0].name]: '' },
    ],
  };
})();

const empty = (() => {
  const s = [
    box('text', 5, 5, 60, 10, { backgroundColor: '#ffcdd2' }),
    box('image', 70, 5, 30, 30),
    box('checkbox', 5, 20, 10, 10, { color: '#000000' }),
    box('radioGroup', 20, 20, 10, 10, { color: '#000000' }),
    box('rectangle', 5, 40, 30, 15, { color: '#c5cae9' }),
    box('date', 40, 40, 40, 10, { format: 'yyyy/MM/dd' }),
    box('qrcode', 90, 40, 20, 20, {}),
    box('text', 5, 60, 80, 10, { readOnly: true, content: 'Static {missing} text' }),
    { ...box('text', 5, 75, 60, 10, {}), name: '' },
  ];
  return {
    name: 'empty-inputs',
    compare: 'pixels',
    template: { basePdf: blank(), schemas: [s] },
    inputs: [{ [s[0].name]: '', [s[1].name]: '' }, {}],
  };
})();

// Thai, Lao, Khmer and Myanmar paragraphs in narrow boxes: the lines must
// break between the same words as pdfme (Intl.Segmenter word dictionaries).
const saBoxes = (font, fontSize) => [
  box('text', 5, 5, 30, 90, { fontName: font, fontSize }),
  box('text', 40, 5, 22, 90, { fontName: font, fontSize, alignment: 'center' }),
  box('text', 67, 5, 38, 42, { fontName: font, fontSize: fontSize + 2, alignment: 'right' }),
  box('text', 67, 52, 38, 43, { fontName: font, dynamicFontSize: { min: 6, max: 30, fit: 'vertical' } }),
  box('text', 110, 5, 35, 42, { fontName: font, dynamicFontSize: { min: 5, max: 20, fit: 'horizontal' } }),
  box('text', 110, 52, 35, 43, { fontName: font, fontSize, lineHeight: 1.4, characterSpacing: 0.3 }),
];
const saCase = (name, font, fontSize, sentences, boxes = saBoxes(font, fontSize)) =>
  single(name, boxes, [
    sentences.join(' '),
    sentences.slice(2, 9).join(''),
    sentences.slice(0, 4).join(''),
    sentences.slice(4, 7).join(''),
    sentences[2],
    sentences.join(' '),
  ], { compare: 'lines', options: { font: fonts } });
// Only sentences the Noto font can draw: the fonts have no Latin letters
// and digits (missing letters are drawn differently, see README). And
// pdfme's fontkit throws on some Khmer words with Noto Sans Khmer (eg.
// ខ្ញុំ, ភ្នំ, ម៉ោង: a GPOS anchor is null), so those are left out too.
const drawable = (language) =>
  saSentences[language].filter((s) => !/[0-9A-Za-z,]|ខ្ញុំ|ភ្នំ|ម៉ោង/.test(s));

const japanese = 'こんにちは、世界。日本語のテキストを折り返します（括弧）。これは長い文です。';
const thai = 'สวัสดีครับ ภาษาไทย';

export const cases = [
  single('text-basic', textBasic, [
    'Hello, pdfme!',
    'Big blue text',
    latin,
    latin,
    latin,
    'Line height and character spacing.\nSecond line.',
    'Underline and strike through',
    'Border and padding around this text.',
    'Rotated text',
    'Half transparent',
    'Turned 270',
  ]),
  single('text-dynamic', textDynamic, [
    'Fits',
    latin,
    'Horizontal fit text',
    `${latin} ${latin}`,
    `${latin}\n${latin}\n${latin}`,
  ]),
  single('text-wrap', textWrap, [
    'Well-known state-of-the-art words, and a verylongwordthatdoesnotfitinthebox at the end.',
    'Trailing spaces   \n  Leading spaces\r\nCRLF line\rCR line',
    latin,
    'Tabs\tand\tmore.\n\nEmpty line above. 1.5 and 3,000.50 numbers stay together.',
    'A sentence with a few words, wrapped at the box edge, with (brackets) and "quotes".',
  ]),
  single('text-fonts', textFonts, [
    'Lato: The quick brown fox jumps over the lazy dog.',
    japanese,
    thai,
    `${japanese}\n${latin}`,
  ], { options: { font: fonts } }),
  saCase('text-thai', 'NotoSansThai', 11, drawable('thai')),
  saCase('text-lao', 'NotoSansLao', 11, drawable('lao')),
  saCase('text-khmer', 'NotoSansKhmer', 10, drawable('khmer')),
  // Myanmar: fontkit (pdfme) and HarfBuzz give other widths for some
// clusters, so a vertical fit picks another size. That box has a fixed size.
  saCase('text-myanmar', 'NotoSansMyanmar', 9, drawable('myanmar'),
    saBoxes('NotoSansMyanmar', 9).map((b, i) => (i === 3 ? { ...b, dynamicFontSize: undefined, fontSize: 12 } : b))),
  single('shapes', shapes, []),
  single('image', images, [png, jpg, png, jpg, png, jpg, png]),
  single('image-orientation', oriented, [
    exif('image-o3.jpg', 'jpeg'),
    exif('image-o6.jpg', 'jpeg'),
    exif('image-o8.jpg', 'jpeg'),
    exif('image-o6.png', 'png'),
    exif('image-o6.jpg', 'jpeg'),
    exif('image-o8.jpg', 'jpeg'),
  ], { compare: 'reencoded' }),
  single('svg', svgs, [svgSample, svgSample, svgSample, svgSample]),
  single('checkbox-radio', checks, ['true', 'false', 'true', 'true', 'true', 'false', '', 'true']),
  single('date-time', dates, [
    '2024/05/07',
    '2024/05/07',
    '2024/12/31',
    '13:45',
    '09:05',
    '2024/05/07 18:30',
    '2024/01/02 07:08',
    '2024/05/07',
    '2023/11/30',
    'Two',
  ]),
  single('barcodes-1d', barcodes1d, barcodeValues, { compare: 'barcode' }),
  single('barcodes-2d', barcodes2d, [
    'https://github.com/dartondox/dox-pdf-lib',
    'dox_pdf_me',
    '(01)09521234543213',
    'This is PDF417! Made by dox_pdf_me.',
    'rotated',
  ], { compare: 'matrix' }),
  single('pdf417', pdf417s, [
    'This is PDF417!',
    'The quick brown fox jumps over the lazy dog. 1234567890123456',
    'https://github.com/dartondox/dox-pdf-lib',
    'Ünïcödé € 日本',
  ], { compare: 'matrix' }),
  multi,
  basePdf,
  empty,
];

// Old pdfme format: each page is a map of name to schema.
cases.push({
  name: 'legacy-format',
  compare: 'pixels',
  template: {
    basePdf: blank(),
    schemas: [{ title: { type: 'text', position: { x: 10, y: 10 }, width: 100, height: 10, fontSize: 18 } }],
  },
  inputs: [{ title: 'Legacy template' }],
});

// signature, circleMark and multiVariableText (field_cases.mjs)
cases.push(...fieldCases);

// ---------------------------------------------------------------------
// Variants of every schema type: tall, wide and tiny boxes, rotation,
// opacity, colors, alignment, fonts, empty values. The test compares each
// box on its own (its ink box and its pixels), with limits per type.

/** A case of several pages; each page is [schemas, values]. */
function pages(name, list, extra = {}) {
  const ps = list.map(([s, v]) => page(s, v));
  return {
    name,
    compare: 'pixels',
    template: { basePdf: blank(), schemas: ps.map((p) => p.schemas) },
    inputs: [Object.assign({}, ...ps.map((p) => p.input))],
    ...extra,
  };
}

const longText = `${latin} ${latin} ${latin}`;
const variantText = [
  [
    [
      box('text', 5, 5, 12, 4, {}),
      box('text', 20, 5, 18, 90, { fontSize: 10 }),
      box('text', 42, 5, 103, 7, { fontSize: 8, alignment: 'center' }),
      box('text', 42, 15, 45, 30, { rotate: 45, alignment: 'center', verticalAlignment: 'middle' }),
      box('text', 95, 15, 50, 14, { rotate: 90, fontSize: 9 }),
      box('text', 95, 32, 50, 14, { rotate: 180, alignment: 'right', backgroundColor: '#e3f2fd' }),
      box('text', 42, 52, 50, 20, { opacity: 0.3, fontSize: 18, fontColor: '#c62828' }),
      box('text', 95, 52, 50, 20, { fontColor: '#1565c040', fontSize: 16, verticalAlignment: 'bottom' }),
      box('text', 42, 76, 50, 19, { characterSpacing: 3, fontSize: 9, lineHeight: 1.5, verticalAlignment: 'middle' }),
      box('text', 95, 76, 50, 19, { fontName: 'Lato', fontSize: 12, alignment: 'right', verticalAlignment: 'bottom', lineHeight: 0.8 }),
    ],
    ['Tiny box overflow', longText, 'A wide and low box', 'Turned 45 degrees', 'Turned 90', 'Upside down',
      'Opacity 0.3', 'Alpha color', 'Spacing 3 with line height 1.5', 'Lato right\nbottom'],
  ],
  [
    [
      box('text', 5, 5, 40, 20, { borderColor: '#000000', borderWidth: { top: 3, right: 3, bottom: 3, left: 3 }, padding: { top: 4, right: 4, bottom: 4, left: 4 }, fontSize: 9 }),
      box('text', 50, 5, 40, 20, { backgroundColor: '#fff3e080', borderColor: '#e65100', borderWidth: { top: 0, right: 0, bottom: 0.5, left: 0 }, verticalAlignment: 'middle', alignment: 'center' }),
      box('text', 95, 5, 50, 20, { padding: { top: 0, right: 10, bottom: 0, left: 10 }, alignment: 'justify', fontSize: 8 }),
      box('text', 5, 30, 40, 20, {}),
      box('text', 50, 30, 40, 20, { backgroundColor: '#ffcdd2' }),
      box('text', 95, 30, 50, 20, { dynamicFontSize: { min: 4, max: 60, fit: 'horizontal' }, rotate: 90 }),
      box('text', 5, 55, 40, 40, { dynamicFontSize: { min: 4, max: 60, fit: 'vertical' }, verticalAlignment: 'middle', alignment: 'center' }),
      box('text', 50, 55, 40, 40, { fontSize: 40, alignment: 'center', verticalAlignment: 'middle' }),
      box('text', 95, 55, 50, 40, { fontName: 'Lato', underline: true, strikethrough: true, rotate: 180, fontSize: 14 }),
    ],
    ['Thick border and padding', 'Bottom border', `${latin} ${latin}`, '', ' ', 'Fit me', 'Fit me vertical', 'Big',
      'Lato underline and strike'],
  ],
];

const variantShapes = [
  box('line', 5, 5, 40, 0.2, { color: '#000000' }),
  box('line', 50, 5, 40, 3, { color: '#1565c0' }),
  box('line', 95, 10, 40, 1, { color: '#2e7d32', rotate: 90 }),
  box('line', 5, 15, 40, 1, { color: '#000000', rotate: 45 }),
  box('line', 50, 15, 40, 2, { color: '#d32f2f', rotate: 180, opacity: 0.4 }),
  box('line', 110, 5, 30, 0.5, { color: '' }),
  box('rectangle', 5, 30, 20, 30, { color: '#bbdefb', borderColor: '#0d47a1', borderWidth: 3 }),
  box('rectangle', 30, 30, 30, 10, { color: '#c8e6c9', radius: 20 }),
  box('rectangle', 30, 45, 30, 15, { color: '', borderColor: '#000000', borderWidth: 0 }),
  box('rectangle', 65, 30, 30, 15, { color: '#ffe0b2', borderColor: '#e65100', borderWidth: 1, rotate: 90 }),
  box('rectangle', 100, 30, 40, 15, { color: '#f8bbd0', borderColor: '#880e4f', borderWidth: 2, radius: 4, rotate: 180, opacity: 0.5 }),
  box('rectangle', 65, 50, 2, 2, { color: '#000000' }),
  box('rectangle', 75, 50, 20, 10, { color: '#00000000', borderColor: '#ff000080', borderWidth: 1 }),
  box('ellipse', 5, 65, 20, 30, { color: '#e1bee7', borderColor: '#4a148c', borderWidth: 3 }),
  box('ellipse', 30, 70, 40, 15, { color: '#b2dfdb', rotate: 90 }),
  box('ellipse', 75, 65, 30, 20, { borderColor: '#000000', borderWidth: 0.3, rotate: 45, opacity: 0.5 }),
  box('ellipse', 110, 65, 35, 30, { color: '#fff59d80' }),
  box('ellipse', 110, 50, 3, 3, { color: '#000000' }),
];

const fitSpots = ['left top', 'center top', 'right top', 'left center', 'center center', 'right center', 'left bottom', 'center bottom', 'right bottom'];
const variantImages = [
  [
    [
      ...fitSpots.map((p, i) => box('image', 5 + (i % 3) * 25, 5 + Math.floor(i / 3) * 12, 22, 9, { objectPosition: p })),
      ...fitSpots.map((p, i) => box('image', 80 + (i % 3) * 22, 5 + Math.floor(i / 3) * 30, 10, 27, { objectPosition: p })),
      box('image', 5, 45, 30, 20, { objectFit: 'cover' }),
      box('image', 40, 45, 10, 40, { objectFit: 'cover' }),
      box('image', 5, 70, 30, 20, { objectFit: 'cover', rotate: 90 }),
      box('image', 55, 50, 15, 3, {}),
    ],
    [...fitSpots.map(() => png), ...fitSpots.map(() => jpg), jpg, png, png, png],
  ],
  [
    [
      box('image', 5, 5, 40, 25, { rotate: 90 }),
      box('image', 55, 5, 40, 25, { rotate: 180, objectPosition: 'left top' }),
      box('image', 105, 5, 40, 25, { rotate: 45, objectFit: 'cover' }),
      box('image', 5, 50, 40, 40, { opacity: 0.3 }),
      box('image', 55, 50, 20, 40, { rotate: 270, objectPosition: 'right bottom' }),
      box('image', 85, 50, 3, 3, {}),
      box('image', 95, 50, 50, 40, { objectFit: 'cover', objectPosition: 'left top', rotate: 180 }),
    ],
    [jpg, png, jpg, png, jpg, png, png],
  ],
];

const svgNoViewBox =
  '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">' +
  '<rect x="0" y="0" width="40" height="20" fill="#90caf9"/><circle cx="10" cy="10" r="8" fill="#0d47a1"/></svg>';
const svgAspect = (par) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20" preserveAspectRatio="${par}">` +
  '<rect x="0" y="0" width="40" height="20" fill="#ffcc80"/><circle cx="10" cy="10" r="8" fill="#e65100"/>' +
  '<rect x="25" y="2" width="12" height="16" rx="4" fill="#4e342e"/></svg>';
const svgStroke =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-10 -10 120 120">' +
  '<path d="M0 0 C 50 100, 50 -50, 100 50" fill="none" stroke="#1b5e20" stroke-width="6" stroke-dasharray="12 6"/>' +
  '<polyline points="0,100 50,80 100,100" fill="none" stroke="#000" stroke-width="4"/>' +
  '<g opacity="0.5" transform="scale(0.5) translate(20 120)"><rect width="60" height="40" fill="#c62828"/></g>' +
  '<line x1="0" y1="100" x2="100" y2="0" stroke="rgb(30,60,200)" stroke-width="3" stroke-linecap="square"/>' +
  '<circle cx="80" cy="80" r="15" fill="#ffeb3b" stroke="#f57f17" stroke-width="2" fill-opacity="0.7"/></svg>';
const variantSvgs = [
  [
    [
      box('svg', 5, 5, 40, 20),
      box('svg', 50, 5, 60, 20),
      box('svg', 115, 5, 30, 40),
      box('svg', 5, 30, 60, 20),
      box('svg', 70, 30, 40, 40),
      box('svg', 5, 55, 60, 20),
      box('svg', 5, 80, 30, 15),
      box('svg', 115, 50, 30, 45),
      box('svg', 40, 78, 60, 17),
    ],
    [svgNoViewBox, svgNoViewBox, svgAspect('xMidYMid meet'), svgAspect('xMidYMid meet'), svgStroke,
      svgAspect('none'), svgAspect('xMinYMin meet'), svgAspect('xMaxYMax meet'), svgAspect('xMidYMid slice')],
  ],
  [
    [
      box('svg', 5, 5, 40, 30, { rotate: 90 }),
      box('svg', 55, 5, 40, 30, { rotate: 180 }),
      box('svg', 105, 5, 40, 30, { rotate: 45 }),
      box('svg', 5, 55, 40, 30, { opacity: 0.3 }),
      box('svg', 55, 55, 5, 5),
      box('svg', 70, 55, 30, 30),
    ],
    [svgSample, svgSample, svgStroke, svgSample, svgSample, '<svg>not closed'],
  ],
];

const bars1d = [
  ['ean13', '4006381333931'], ['ean8', '96385074'], ['upca', '03600029145'], ['upce', '01234565'],
  ['code39', 'AB-12.$/+%'], ['code128', 'Abc 123 xyz'], ['nw7', 'C12:34$5D'], ['itf14', '1540014128876'],
  ['japanpost', '1350023-2-1-1'],
];
const variant1d = bars1d.map(([type, value]) => [
  [
    box(type, 5, 5, 20, 40, {}),
    box(type, 30, 5, 115, 12, {}),
    box(type, 30, 20, 20, 6, {}),
    box(type, 55, 20, 40, 20, { includetext: false }),
    box(type, 100, 22, 40, 18, { rotate: 180, barColor: '#1565c0', textColor: '#d32f2f', backgroundColor: '#fff9c4' }),
    box(type, 5, 55, 40, 20, { rotate: 90 }),
    box(type, 50, 50, 40, 20, { rotate: 45, opacity: 0.5 }),
    box(type, 100, 50, 40, 20, { barColor: '#00000080', backgroundColor: '#90caf980' }),
    box(type, 50, 78, 40, 18, { backgroundColor: '', textColor: '#2e7d32' }),
    box(type, 100, 78, 40, 18, { barColor: '#ff0000' }),
  ],
  [value, value, value, value, value, value, value, value, value, 'bad value!'],
]);

const variant2d = [
  [
    [
      box('qrcode', 5, 5, 50, 20, {}),
      box('qrcode', 60, 5, 15, 45, {}),
      box('qrcode', 80, 5, 30, 30, { rotate: 90, barColor: '#1565c0', backgroundColor: '#fff9c4' }),
      box('qrcode', 115, 5, 30, 30, { rotate: 45, opacity: 0.5 }),
      box('qrcode', 5, 30, 5, 5, {}),
      box('qrcode', 15, 30, 40, 40, { barColor: '#00000080', backgroundColor: '#ff000040' }),
      box('gs1datamatrix', 80, 40, 60, 20, {}),
      box('gs1datamatrix', 60, 55, 15, 40, { rotate: 180 }),
      box('gs1datamatrix', 80, 65, 25, 25, { rotate: 90, barColor: '#2e7d32' }),
      box('pdf417', 5, 75, 50, 20, { rotate: 180, opacity: 0.6 }),
      box('pdf417', 110, 65, 35, 30, { rotate: 45 }),
    ],
    ['https://pdfme.com', 'tall', 'turned 90', 'turned 45', 'tiny', 'alpha colors', '(01)09521234543213',
      '(01)04912345123459', '(01)09521234543213', 'PDF417 turned 180', 'PDF417 45'],
  ],
];

const variantDates = [
  [
    [
      box('date', 5, 5, 45, 10, { locale: 'de' }),
      box('date', 55, 5, 45, 10, { format: 'EEEE d MMMM yyyy', fontSize: 9 }),
      box('date', 105, 5, 40, 10, { locale: 'ja', format: 'yyyy年M月d日', fontName: 'NotoSansJP' }),
      box('dateTime', 5, 20, 45, 10, { locale: 'en' }),
      box('dateTime', 55, 20, 45, 10, { locale: 'zh' }),
      box('time', 105, 20, 40, 10, { format: 'h:mm a' }),
      box('date', 5, 35, 45, 20, { fontSize: 20, alignment: 'center', backgroundColor: '#e8f5e9', characterSpacing: 2 }),
      box('date', 55, 35, 45, 20, { rotate: 90, fontColor: '#c62828' }),
      box('dateTime', 105, 35, 40, 20, { rotate: 180, alignment: 'right', fontName: 'Lato' }),
      box('date', 5, 60, 45, 6, { fontSize: 8, format: 'MMM do, yy' }),
      box('time', 55, 60, 45, 10, { format: 'HH:mm:ss', opacity: 0.4 }),
      box('date', 105, 60, 40, 10, { format: '', locale: 'fr' }),
      box('date', 5, 75, 45, 10, { format: 'PPP' }),
      box('time', 55, 75, 45, 10, {}),
      box('dateTime', 105, 75, 40, 10, { format: "yyyy-MM-dd'T'HH:mm" }),
    ],
    ['2024/05/07', '2024/02/29', '2025/01/09', '2024/05/07 18:30', '2024/12/31 23:59', '07:05',
      '2024/05/07', '2024/05/07', '2024/05/07 00:00', '2024/03/01', '13:45', '2024/05/07',
      '2024/05/07', '', '2024/05/07 09:08'],
  ],
];

const variantChecks = [
  [
    [
      box('checkbox', 5, 5, 20, 10, { color: '#000000' }),
      box('checkbox', 30, 5, 10, 20, { color: '#000000' }),
      box('checkbox', 45, 5, 3, 3, { color: '#000000' }),
      box('checkbox', 55, 5, 12, 12, { color: '#1565c0', rotate: 45 }),
      box('checkbox', 75, 5, 12, 12, { color: '#000000', rotate: 90, opacity: 0.3 }),
      box('checkbox', 95, 5, 12, 12, {}),
      box('checkbox', 115, 5, 20, 10, { color: '#d32f2f' }),
      box('radioGroup', 5, 35, 20, 10, { color: '#000000' }),
      box('radioGroup', 30, 35, 10, 20, { color: '#000000' }),
      box('radioGroup', 45, 35, 3, 3, { color: '#000000' }),
      box('radioGroup', 55, 35, 12, 12, { color: '#6a1b9a', rotate: 30 }),
      box('radioGroup', 75, 35, 12, 12, { color: '#00000080' }),
      box('radioGroup', 95, 35, 12, 12, {}),
      box('radioGroup', 115, 35, 20, 10, { color: '#2e7d32' }),
      box('checkbox', 5, 65, 30, 30, { color: '#000000' }),
      box('radioGroup', 40, 65, 30, 30, { color: '#000000' }),
    ],
    ['true', 'true', 'true', 'true', 'true', 'true', 'false', 'true', 'true', 'true', 'true', 'true', 'true', 'TRUE', 'true', 'true'],
  ],
];

const variantSelect = [
  [
    [
      box('select', 5, 5, 45, 10, { options: ['A', 'B'] }),
      box('select', 55, 5, 45, 15, { options: ['A', 'B'], alignment: 'center', verticalAlignment: 'middle', backgroundColor: '#e1f5fe' }),
      box('select', 105, 5, 40, 20, { options: ['A'], alignment: 'right', verticalAlignment: 'bottom', fontName: 'Lato', fontSize: 16 }),
      box('select', 5, 30, 45, 20, { options: ['A'], rotate: 90, fontColor: '#2e7d32' }),
      box('select', 55, 30, 45, 10, { options: ['A'], opacity: 0.4, characterSpacing: 2 }),
      box('select', 105, 30, 40, 10, { options: ['A'] }),
    ],
    ['Option A', 'Option B centered', 'Right', 'Turned', 'Faint', ''],
  ],
];

const variantText2 = [
  [
    [
      box('text', 5, 5, 45, 25, { rotate: 45, backgroundColor: '#ffe0b2', borderColor: '#e65100', borderWidth: { top: 1, right: 2, bottom: 1, left: 2 }, padding: { top: 2, right: 2, bottom: 2, left: 2 }, fontSize: 9 }),
      box('text', 55, 5, 40, 25, { verticalAlignment: 'middle', alignment: 'right', characterSpacing: 1, fontSize: 9 }),
      box('text', 100, 5, 45, 25, { lineHeight: 0, fontSize: 10 }),
      box('text', 5, 35, 45, 25, { dynamicFontSize: { min: 3, max: 30, fit: 'horizontal' }, verticalAlignment: 'bottom' }),
      box('text', 55, 35, 40, 25, { fontName: 'NotoSansJP', rotate: 90, fontSize: 10, alignment: 'center' }),
      box('text', 100, 35, 45, 25, { fontSize: 4, alignment: 'justify' }),
      box('text', 5, 65, 45, 30, { fontColor: '', underline: true, alignment: 'center', lineHeight: 2 }),
      box('text', 55, 65, 40, 30, { strikethrough: true, rotate: 270, fontSize: 11, opacity: 0.7, backgroundColor: '#c5cae980' }),
      box('text', 100, 65, 45, 30, { dynamicFontSize: { min: 8, max: 12, fit: 'vertical' }, alignment: 'justify', characterSpacing: 0.4 }),
    ],
    ['Rotated with border, padding and background', 'Middle right\nwith spacing', 'Line height zero\nsecond\nthird',
      'Short\nAnd a much longer line', '日本語のテキスト。折り返し。', longText,
      'Default color\nlines', 'Strike turned 270 and faint', longText],
  ],
];

const variantShapes2 = [
  box('rectangle', 5, 5, 40, 20, { color: '#b3e5fc', borderColor: '#01579b', borderWidth: 2, radius: 6, rotate: 45 }),
  box('rectangle', 55, 5, 30, 20, { color: '#dcedc8', borderWidth: 2 }),
  box('rectangle', 95, 5, 20, 20, { borderColor: '#000000', borderWidth: 15 }),
  box('rectangle', 120, 5, 25, 20, { color: '#ffcdd2', borderColor: '#b71c1c80', borderWidth: 3, opacity: 0.5 }),
  box('ellipse', 5, 40, 30, 20, { color: '#d1c4e9', borderColor: '#311b92', borderWidth: 12 }),
  box('ellipse', 45, 35, 40, 25, { color: '#fff9c4', borderColor: '#f57f17', borderWidth: 1.5, rotate: 135 }),
  box('ellipse', 95, 35, 50, 8, { color: '#b2ebf2', rotate: 180 }),
  box('line', 95, 50, 50, 4, { color: '#4caf5080', opacity: 0.5 }),
  box('line', 5, 70, 60, 0.3, { color: '#000000', rotate: 30 }),
  box('line', 75, 65, 0.5, 30, { color: '#000000' }),
  box('line', 85, 75, 60, 10, { color: '#90a4ae', rotate: 10 }),
];

const variant1d2 = [
  [
    [
      box('ean13', 5, 5, 40, 20, {}),
      box('ean8', 50, 5, 40, 20, {}),
      box('upca', 95, 5, 40, 20, {}),
      box('upce', 5, 30, 40, 20, {}),
      box('itf14', 50, 30, 40, 20, {}),
      box('japanpost', 95, 30, 50, 10, { includetext: false }),
      box('japanpost', 95, 43, 50, 12, { barColor: '#1565c0', textColor: '#d32f2f', rotate: 180 }),
      box('code128', 5, 55, 60, 20, {}),
      box('code128', 70, 60, 75, 15, {}),
      box('code39', 5, 80, 60, 15, { opacity: 0.4, backgroundColor: '#ffeb3b' }),
      box('nw7', 70, 80, 75, 15, { textColor: '#00000080', barColor: '#2e7d3280' }),
    ],
    ['490123456789', '1234567', '01234567890', '0123456', '1234567890123', '1000013-ABC-12', '1000013-ABC-12',
      '[]{}!@#$%^&*()_+=~`|\;:,.<>?/"\'', '0123456789012345678901234567', 'CODE-39 $/+%.', 'A1234567890D'],
  ],
];

const variant2d2 = [
  [
    [
      box('qrcode', 5, 5, 40, 40, {}),
      box('qrcode', 50, 5, 40, 40, { backgroundColor: '' }),
      box('pdf417', 95, 5, 50, 40, {}),
      box('pdf417', 5, 50, 140, 15, {}),
      box('pdf417', 5, 70, 10, 25, {}),
      box('gs1datamatrix', 20, 70, 20, 25, { backgroundColor: '#e0e0e0' }),
      box('gs1datamatrix', 45, 70, 20, 20, {}),
      box('pdf417', 70, 70, 75, 25, { barColor: '#00000080', opacity: 0.7 }),
    ],
    ['日本語のQRコード — UTF-8 ✓', 'x'.repeat(300), 'a'.repeat(400), '1234567890'.repeat(12),
      'short', '(01)95012345678903(3103)000123', '(01)00012345678905(10)ABC123', '日本語 PDF417 ✓ €'],
  ],
];

const variantColors = [
  box('text', 5, 5, 45, 10, { fontColor: '#f00', backgroundColor: '#ccf' }),
  box('text', 55, 5, 45, 10, { fontColor: '#00f8', backgroundColor: '#0f04' }),
  box('text', 105, 5, 40, 10, { fontColor: '#123456', backgroundColor: '#fff0' }),
  box('rectangle', 5, 20, 30, 15, { color: '#f80', borderColor: '#08f', borderWidth: 1 }),
  box('ellipse', 40, 20, 30, 15, { color: '#0f08', borderColor: '#f008', borderWidth: 1 }),
  box('line', 75, 25, 30, 2, { color: '#f0f' }),
  box('checkbox', 110, 20, 12, 12, { color: '#f00' }),
  box('radioGroup', 128, 20, 12, 12, { color: '#00f8' }),
  box('ean13', 5, 40, 40, 20, { barColor: '#f00', textColor: '#00f', backgroundColor: 'ff0' }),
  box('code128', 50, 40, 45, 20, { barColor: '#0000ff80', backgroundColor: 'ffff0080' }),
  box('qrcode', 100, 40, 20, 20, { barColor: '#080', backgroundColor: '#ffeeee' }),
  box('pdf417', 125, 40, 20, 20, { barColor: '#008', backgroundColor: '#0000' }),
  box('date', 5, 65, 45, 10, { fontColor: '#a0a', backgroundColor: '#ffe' }),
  box('select', 55, 65, 45, 10, { options: ['A'], fontColor: '#0a0a', backgroundColor: '#eee' }),
  box('image', 105, 65, 40, 30, {}),
  box('svg', 5, 80, 40, 15, {}),
];

const a4 = (() => {
  const s = [
    box('text', 20, 20, 170, 20, { fontSize: 24, alignment: 'center' }),
    box('qrcode', 20, 50, 40, 40, {}),
    box('image', 70, 50, 120, 80, { objectFit: 'cover' }),
    box('rectangle', 20, 140, 170, 100, { color: '', borderColor: '#000000', borderWidth: 0.5, radius: 3 }),
    box('text', 25, 145, 160, 90, { fontSize: 12, lineHeight: 1.4, alignment: 'justify' }),
    box('line', 20, 270, 170, 0.5, { color: '#000000' }),
    box('ean13', 140, 275, 50, 18, {}),
  ];
  return {
    name: 'variant-page-a4',
    compare: 'pixels',
    template: { basePdf: { width: 210, height: 297, padding: [10, 10, 10, 10] }, schemas: [s] },
    inputs: [
      { [s[0].name]: 'Invoice', [s[1].name]: 'https://pdfme.com', [s[2].name]: { $file: 'image.jpg' }, [s[4].name]: `${latin}\n\n${longText}`, [s[6].name]: '4006381333931' },
      { [s[0].name]: 'Second', [s[1].name]: 'x', [s[2].name]: png, [s[4].name]: 'short', [s[6].name]: '' },
    ],
  };
})();

const landscape = (() => {
  const statics = [
    { name: 'stamp', type: 'text', position: { x: 200, y: 5 }, width: 90, height: 10, readOnly: true, content: 'Page {currentPage}/{totalPages}', alignment: 'right', fontSize: 10 },
    { name: 'frame', type: 'rectangle', position: { x: 5, y: 5 }, width: 287, height: 200, color: '', borderColor: '#999999', borderWidth: 0.4, readOnly: true },
  ];
  const s = [
    box('text', 20, 30, 250, 30, { fontSize: 30, verticalAlignment: 'middle', alignment: 'center', rotate: 180 }),
    box('svg', 20, 70, 100, 60, { rotate: 90 }),
    box('pdf417', 150, 80, 120, 50, {}),
  ];
  return {
    name: 'variant-page-landscape',
    compare: 'pixels',
    template: { basePdf: { width: 297, height: 210, padding: [0, 0, 0, 0], staticSchema: statics }, schemas: [s, s.slice(0, 1)] },
    inputs: [{ [s[0].name]: 'Landscape upside down', [s[1].name]: svgSample, [s[2].name]: 'Landscape PDF417' }],
  };
})();

// Japanese QR codes: bwip-js never uses kanji mode (it sends UTF-8 bytes),
// so a reader must get the same text back.
const japaneseQr = ['ありがとうございます', 'お問い合わせはこちらまで', '愛知県名古屋市中区栄', 'こここここ', '東京都千代田区丸の内1-1-1'];
const qrJapanese = single(
  'qr-japanese',
  japaneseQr.map((_, i) => box('qrcode', 5 + (i % 3) * 48, 5 + Math.floor(i / 3) * 48, 40, 40, {})),
  japaneseQr,
  { compare: 'matrix', decoded: japaneseQr.map((t) => `QR-Code:${t}`) },
);

cases.push(
  pages('variant-text', variantText, { options: { font: fonts } }),
  single('variant-shapes', variantShapes, []),
  pages('variant-image', variantImages),
  pages('variant-svg', variantSvgs),
  pages('variant-1d', variant1d, { compare: 'barcode' }),
  pages('variant-2d', variant2d, { compare: 'matrix' }),
  pages('variant-date', variantDates, { options: { font: fonts } }),
  pages('variant-check', variantChecks),
  pages('variant-select', variantSelect, { options: { font: fonts } }),
  pages('variant-text-2', variantText2, { options: { font: fonts } }),
  single('variant-shapes-2', variantShapes2, []),
  pages('variant-1d-2', variant1d2, { compare: 'barcode' }),
  pages('variant-2d-2', variant2d2, { compare: 'matrix' }),
  single('variant-colors', variantColors, ['3 digit', '4 digit', 'transparent bg', '', '', '', 'true', 'true', '4006381333931', 'Alpha', 'qr', 'pdf', '2024/05/07', 'A', { $file: 'image.png' }, svgSample]),
  a4,
  landscape,
  qrJapanese,
);

// tables (table_cases.mjs)
cases.push(...tableCases);
