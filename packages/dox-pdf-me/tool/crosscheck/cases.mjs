// The templates of the crosscheck. render.mjs draws them with pdfme, and
// writes them as cases.json for test/crosscheck_test.dart, which draws them
// with dox_pdf_me.
//
// `compare` says how the Dart test compares the pages:
// - 'pixels': the pages must look the same (a few edge pixels may differ).
// - 'barcode': like 'pixels', but with a larger tolerance for the human
//   readable text (OCR-B in pdfme, Helvetica here).
// - 'reencoded': images with an EXIF orientation. pdfme decodes, turns and
//   encodes them again (JPEG quality 90); we turn them with a transform. The
//   colors near the edges of the blocks differ a little.
// - 'lines': Thai, Lao, Khmer and Myanmar text. Every line must have the
//   same base letters at the same place (test/crosscheck_test.dart reads
//   them with pdftotext). The letters are shaped by other code (fontkit in
//   pdfme, HarfBuzz rules here): marks sit in other places, and fontkit
//   does not reorder some Myanmar vowels. So more pixels may differ.
// - 'pdf417': PDF417 codes. The modules are the same as bwip-js, so only
//   the edges of the bars may differ (vector here, SVG in pdfme).
// - 'matrix': 2D codes (QR, Data Matrix, PDF417). The modules can differ
//   (mask, encoding), so only the symbol box is compared, and the codes are
//   decoded with zbarimg when it is installed.

import { saSentences } from './sa_text.mjs';
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
  ], { compare: 'pdf417' }),
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

cases.push(...tableCases);
