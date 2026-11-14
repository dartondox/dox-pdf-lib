// Table cases of the crosscheck. cases.mjs adds them to the other cases.
//
// `boxes` lists areas (mm) per page: test/table_crosscheck_test.dart
// compares each area alone (pixels and the box around the ink), so a small
// shift inside a table is not hidden by the white rest of the page. It
// always compares the whole page too.

const blank = (extra = {}) => ({ width: 150, height: 100, padding: [10, 10, 10, 10], ...extra });

const cellStyle = (extra = {}) => ({
  fontName: undefined,
  alignment: 'left',
  verticalAlignment: 'middle',
  fontSize: 13,
  lineHeight: 1,
  characterSpacing: 0,
  fontColor: '#000000',
  backgroundColor: '',
  borderColor: '#888888',
  borderWidth: { top: 0.1, right: 0.1, bottom: 0.1, left: 0.1 },
  padding: { top: 5, right: 5, bottom: 5, left: 5 },
  ...extra,
});

// pdfme's default table schema (propPanel.defaultSchema)
const table = (name, x, y, width, height, extra = {}) => ({
  name,
  type: 'table',
  position: { x, y },
  width,
  height,
  showHead: true,
  repeatHead: false,
  head: ['Name', 'City', 'Description'],
  headWidthPercentages: [30, 30, 40],
  tableStyles: { borderColor: '#000000', borderWidth: 0.3 },
  headStyles: cellStyle({
    fontColor: '#ffffff',
    backgroundColor: '#2980ba',
    borderColor: '',
    borderWidth: { top: 0, right: 0, bottom: 0, left: 0 },
  }),
  bodyStyles: cellStyle({ alternateBackgroundColor: '#f5f5f5' }),
  columnStyles: {},
  ...extra,
});

const people = [
  ['Alice', 'New York', 'Alice is a freelance web designer and developer'],
  ['Bob', 'Paris', 'Bob is a freelance illustrator and graphic designer'],
];

const rows = (n) =>
  Array.from({ length: n }, (_, i) => [
    `Row ${i + 1}`,
    i % 3 === 0 ? 'Tokyo' : 'Berlin',
    i % 4 === 0 ? 'A longer text that wraps over two lines in this cell' : `Item ${i * 7}`,
  ]);

const small = {
  name: 'table-small',
  compare: 'pixels',
  template: { basePdf: blank(), schemas: [[table('t', 10, 10, 130, 20)]] },
  inputs: [{ t: JSON.stringify(people) }],
  boxes: [[{ x: 10, y: 10, width: 130, height: 60 }]],
};

const styled = (() => {
  const a = table('styled', 10, 10, 90, 20, {
    head: ['Item', 'Qty', 'Price'],
    headWidthPercentages: [50, 20, 30],
    tableStyles: { borderColor: '#c62828', borderWidth: 0.8 },
    headStyles: cellStyle({
      fontSize: 11,
      fontColor: '#1b5e20',
      backgroundColor: '#c8e6c9',
      alignment: 'center',
      borderColor: '#1b5e20',
      borderWidth: { top: 0, right: 0.5, bottom: 1, left: 0 },
      padding: { top: 2, right: 2, bottom: 2, left: 2 },
    }),
    bodyStyles: cellStyle({
      fontSize: 9,
      lineHeight: 1.4,
      characterSpacing: 0.4,
      fontColor: '#0d47a1',
      backgroundColor: '#fff8e1',
      alternateBackgroundColor: '#e3f2fd',
      borderColor: '#6a1b9a',
      borderWidth: { top: 0.2, right: 0, bottom: 0.6, left: 0.3 },
      padding: { top: 1.5, right: 3, bottom: 2.5, left: 1 },
      verticalAlignment: 'top',
    }),
    columnStyles: { alignment: { 1: 'center', 2: 'right' }, verticalAlignment: { 2: 'bottom' } },
  });
  // no head, no alternate color: even rows lose the background (pdfme)
  const b = table('noHead', 105, 10, 40, 20, {
    showHead: false,
    head: ['A', 'B'],
    headWidthPercentages: [40, 60],
    bodyStyles: cellStyle({ fontSize: 8, backgroundColor: '#ffe0b2', padding: { top: 1, right: 1, bottom: 1, left: 1 } }),
  });
  // read-only: the content is the body
  const c = table('fixed', 105, 45, 40, 10, {
    readOnly: true,
    content: JSON.stringify([['Fixed', '1'], ['Rows', '2']]),
    head: ['Key', 'Val'],
    headWidthPercentages: [60, 40],
    headStyles: cellStyle({ fontSize: 8, backgroundColor: '#eeeeee', padding: { top: 1, right: 1, bottom: 1, left: 1 } }),
    bodyStyles: cellStyle({ fontSize: 8, padding: { top: 1, right: 1, bottom: 1, left: 1 } }),
  });
  // empty: only the head
  const d = table('empty', 105, 75, 40, 10, {
    head: ['Empty', 'Table'],
    headWidthPercentages: [50, 50],
    headStyles: cellStyle({ fontSize: 8, backgroundColor: '#b3e5fc', padding: { top: 1, right: 1, bottom: 1, left: 1 } }),
  });
  return {
    name: 'table-styled',
    compare: 'pixels',
    template: { basePdf: blank({ padding: [5, 5, 5, 5] }), schemas: [[a, b, c, d]] },
    inputs: [{
      styled: JSON.stringify([
        ['Apples, red and green, from the farm', '12', '3.40'],
        ['Pears', '4', '1.10'],
        ['Cherries in a long line that wraps', '250', '12.00'],
        ['Plums', '7', '2.30\nper kg'],
      ]),
      noHead: JSON.stringify([['one', 'first row'], ['two', 'second'], ['three', 'third row text'], ['four', '4']]),
    }],
    boxes: [[
      { x: 10, y: 10, width: 90, height: 85 },
      { x: 105, y: 10, width: 40, height: 33 },
      { x: 105, y: 45, width: 40, height: 28 },
    ], [
      { x: 105, y: 10, width: 40, height: 30 },
    ]],
  };
})();

// 3 pages: the table goes on over pages, the head repeats, and the
// schemas below the table move down. The static header counts the pages.
const long = (() => {
  const statics = [
    { name: 'header', type: 'text', position: { x: 10, y: 3 }, width: 130, height: 6, readOnly: true, content: 'Page {currentPage} of {totalPages}', fontSize: 9, alignment: 'right' },
  ];
  const s = [
    { name: 'title', type: 'text', position: { x: 10, y: 10 }, width: 130, height: 8, fontSize: 14 },
    table('rows', 10, 20, 130, 30, {
      repeatHead: true,
      headStyles: cellStyle({ fontSize: 10, fontColor: '#ffffff', backgroundColor: '#2980ba', borderColor: '', borderWidth: { top: 0, right: 0, bottom: 0, left: 0 }, padding: { top: 2, right: 2, bottom: 2, left: 2 } }),
      bodyStyles: cellStyle({ fontSize: 9, alternateBackgroundColor: '#f5f5f5', padding: { top: 1.5, right: 2, bottom: 1.5, left: 2 } }),
    }),
    { name: 'note', type: 'text', position: { x: 10, y: 55 }, width: 130, height: 10, fontSize: 10, backgroundColor: '#fff59d' },
    { name: 'box', type: 'rectangle', position: { x: 10, y: 70 }, width: 60, height: 15, color: '#c5cae9', borderColor: '#283593', borderWidth: 0.5 },
  ];
  return {
    name: 'table-long',
    compare: 'pixels',
    template: { basePdf: blank({ staticSchema: statics }), schemas: [s] },
    inputs: [{ title: 'Long table', rows: JSON.stringify(rows(32)), note: 'Below the table' }],
    boxes: [],
  };
})();

// No repeatHead, two inputs (one short, one long), a second template page.
const longNoRepeat = (() => {
  const s = [
    table('list', 10, 50, 130, 20, {
      head: ['#', 'Text'],
      headWidthPercentages: [15, 85],
      headStyles: cellStyle({ fontSize: 9, backgroundColor: '#ffcc80', borderColor: '', borderWidth: { top: 0, right: 0, bottom: 0, left: 0 }, padding: { top: 1, right: 1, bottom: 1, left: 1 } }),
      bodyStyles: cellStyle({ fontSize: 9, alternateBackgroundColor: '#eeeeee', padding: { top: 1, right: 1, bottom: 1, left: 1 } }),
    }),
    { name: 'after', type: 'text', position: { x: 10, y: 75 }, width: 130, height: 8, fontSize: 10 },
  ];
  const p2 = [{ name: 'second', type: 'text', position: { x: 10, y: 10 }, width: 130, height: 10, fontSize: 12 }];
  const list = (n) => JSON.stringify(Array.from({ length: n }, (_, i) => [`${i + 1}`, `Entry number ${i + 1}`]));
  return {
    name: 'table-long-norepeat',
    compare: 'pixels',
    template: { basePdf: blank(), schemas: [s, p2] },
    inputs: [
      { list: list(3), after: 'After a short table', second: 'Page two' },
      { list: list(22), after: 'After a long table', second: 'Page two again' },
    ],
    boxes: [],
  };
})();

// A PDF base: no new pages, the table draws its full height.
const onBasePdf = {
  name: 'table-base-pdf',
  compare: 'pixels',
  template: {
    basePdf: { $file: 'base.pdf', prefix: 'data:application/pdf;base64,' },
    schemas: [[
      table('t', 15, 20, 110, 15, {
        headStyles: cellStyle({ fontSize: 10, fontColor: '#ffffff', backgroundColor: '#2980ba', borderColor: '', borderWidth: { top: 0, right: 0, bottom: 0, left: 0 }, padding: { top: 2, right: 2, bottom: 2, left: 2 } }),
        bodyStyles: cellStyle({ fontSize: 9, alternateBackgroundColor: '#f5f5f5', padding: { top: 2, right: 2, bottom: 2, left: 2 } }),
      }),
      { name: 'under', type: 'text', position: { x: 15, y: 40 }, width: 100, height: 8, fontSize: 10, fontColor: '#c62828' },
    ]],
  },
  inputs: [{ t: JSON.stringify(rows(6)), under: 'This text does not move' }],
  boxes: [[{ x: 15, y: 20, width: 110, height: 70 }], [{ x: 0, y: 0, width: 50, height: 50 }]],
};

const fonts = {
  Roboto: { data: { $default: true }, fallback: true },
  NotoSansThai: { data: { $file: 'NotoSansThai-Regular.ttf' } },
  NotoSansMyanmar: { data: { $file: 'NotoSansMyanmar-Regular.ttf' } },
};

// Thai and Myanmar cell text with a custom font per section.
const scripts = {
  name: 'table-fonts',
  compare: 'lines',
  options: { font: fonts },
  template: {
    basePdf: blank(),
    schemas: [[
      table('thai', 10, 10, 130, 20, {
        head: ['ภาษา', 'ข้อความ'],
        headWidthPercentages: [25, 75],
        headStyles: cellStyle({ fontName: 'NotoSansThai', fontSize: 10, backgroundColor: '#dcedc8', padding: { top: 1, right: 2, bottom: 1, left: 2 } }),
        bodyStyles: cellStyle({ fontName: 'NotoSansThai', fontSize: 10, padding: { top: 1, right: 2, bottom: 1, left: 2 } }),
      }),
      table('myanmar', 10, 55, 130, 20, {
        head: ['Language', 'Text'],
        headWidthPercentages: [25, 75],
        headStyles: cellStyle({ fontSize: 10, backgroundColor: '#ffe0b2', padding: { top: 1, right: 2, bottom: 1, left: 2 } }),
        bodyStyles: cellStyle({ fontName: 'NotoSansMyanmar', fontSize: 10, padding: { top: 1, right: 2, bottom: 1, left: 2 } }),
      }),
    ]],
  },
  inputs: [{
    thai: JSON.stringify([
      ['ไทย', 'สวัสดีครับ ภาษาไทย'],
      ['ยาว', 'ภาษาไทยเป็นภาษาที่มีระดับเสียงของคำแน่นอนหรือวรรณยุกต์เช่นเดียวกับภาษาจีน และออกเสียงแยกคำต่อคำ'],
    ]),
    myanmar: JSON.stringify([
      ['မြန်မာ', 'မင်္ဂလာပါ'],
      ['စာ', 'မြန်မာဘာသာစကား'],
    ]),
  }],
  boxes: [[{ x: 10, y: 10, width: 130, height: 40 }, { x: 10, y: 55, width: 130, height: 35 }]],
};

// Edge cases: a schema above the top padding (it moves down to the
// padding), a table whose head alone would end a page (it moves with the
// first row), a row taller than a page, and rotate and opacity (pdfme
// does not use them for tables).
const edge = (() => {
  const s = [
    { name: 'top', type: 'text', position: { x: 10, y: 2 }, width: 60, height: 6, fontSize: 9 },
    table('turned', 80, 12, 60, 10, {
      rotate: 30,
      opacity: 0.3,
      head: ['A', 'B'],
      headWidthPercentages: [50, 50],
      headStyles: cellStyle({ fontSize: 8, backgroundColor: '#90caf9', padding: { top: 1, right: 1, bottom: 1, left: 1 } }),
      bodyStyles: cellStyle({ fontSize: 8, alternateBackgroundColor: '#f5f5f5', padding: { top: 1, right: 1, bottom: 1, left: 1 } }),
    }),
    table('late', 10, 78, 130, 10, {
      repeatHead: true,
      head: ['Head', 'Moves'],
      headWidthPercentages: [30, 70],
      headStyles: cellStyle({ fontSize: 9, backgroundColor: '#a5d6a7', padding: { top: 2, right: 1, bottom: 2, left: 1 } }),
      bodyStyles: cellStyle({ fontSize: 9, padding: { top: 2, right: 1, bottom: 2, left: 1 } }),
    }),
  ];
  const tall = Array.from({ length: 26 }, (_, i) => `line ${i + 1}`).join('\n');
  return {
    name: 'table-edge',
    compare: 'pixels',
    template: { basePdf: blank(), schemas: [s] },
    inputs: [{
      top: 'Above the padding',
      turned: JSON.stringify([['1', 'x'], ['2', 'y']]),
      late: JSON.stringify([['short', 'one'], ['tall', tall], ['end', 'last']]),
    }],
    boxes: [],
  };
})();

// Image cells: `columnStyles.cellType` "image". The head of an image
// column stays text. `fixed` rows are imageHeight (20 by default), also
// for an empty or broken image; `auto` rows follow the image ratio.
const png = { $file: 'image.png', prefix: 'data:image/png;base64,' };
const jpg = { $file: 'image.jpg', prefix: 'data:image/jpeg;base64,' };
const turned = { $file: 'image-o6.jpg', prefix: 'data:image/jpeg;base64,' };
const imageStyles = {
  headStyles: cellStyle({ fontSize: 9, backgroundColor: '#b39ddb', padding: { top: 1, right: 1, bottom: 1, left: 1 } }),
  bodyStyles: cellStyle({ fontSize: 9, alternateBackgroundColor: '#f5f5f5', padding: { top: 2, right: 3, bottom: 1, left: 2 } }),
};

const images = {
  name: 'table-images',
  compare: 'pixels',
  template: {
    basePdf: blank({ padding: [5, 5, 5, 5] }),
    schemas: [[
      table('fixed', 5, 5, 85, 20, {
        head: ['Photo', 'Name', 'Auto'],
        headWidthPercentages: [35, 30, 35],
        ...imageStyles,
        columnStyles: {
          cellType: { 0: 'image', 2: 'image' },
          imageHeightMode: { 2: 'auto' },
          imageHeight: { 0: 12 },
          alignment: { 0: 'center', 2: 'right' },
          verticalAlignment: { 0: 'top', 2: 'bottom' },
        },
      }),
      table('defaults', 95, 5, 50, 20, {
        head: ['Image', 'Text'],
        headWidthPercentages: [50, 50],
        ...imageStyles,
        columnStyles: { cellType: { 0: 'image', 1: 'text' } },
      }),
    ]],
  },
  inputs: [{
    // mixed rows: images, an empty cell, a broken image, a GIF data URL
    fixed: [
      [png, 'PNG', jpg],
      [jpg, 'JPEG', png],
      ['', 'empty', ''],
      ['data:image/png;base64,iVBORw0KGgo=', 'broken', 'data:image/gif;base64,R0lGODlhAQABAAAAACw='],
      [turned, 'EXIF 6', turned],
    ],
    defaults: [[png, 'default 20 mm'], ['not an image', 'text value']],
  }],
  boxes: [[{ x: 5, y: 5, width: 85, height: 90 }, { x: 95, y: 5, width: 50, height: 90 }]],
};

// A long table with image rows goes on over pages; auto images on a
// blank page are capped to fit one page below the head.
const longImages = (() => {
  const rows = Array.from({ length: 9 }, (_, i) => [i % 2 ? jpg : png, `Row ${i + 1}`, i === 4 ? turned : '']);
  return {
    name: 'table-images-long',
    compare: 'pixels',
    template: {
      basePdf: blank(),
      schemas: [[
        { name: 'title', type: 'text', position: { x: 10, y: 10 }, width: 130, height: 8, fontSize: 12 },
        table('rows', 10, 20, 130, 20, {
          repeatHead: true,
          head: ['Image', 'Text', 'Tall auto'],
          headWidthPercentages: [30, 30, 40],
          ...imageStyles,
          columnStyles: { cellType: { 0: 'image', 2: 'image' }, imageHeightMode: { 2: 'auto' }, imageHeight: { 0: 15 } },
        }),
        { name: 'after', type: 'text', position: { x: 10, y: 45 }, width: 130, height: 8, fontSize: 10, backgroundColor: '#fff59d' },
      ]],
    },
    inputs: [{ title: 'Images over pages', rows, after: 'Below the image table' }],
    boxes: [],
  };
})();

export const tableCases = [small, styled, long, longNoRepeat, onBasePdf, scripts, edge, images, longImages];
