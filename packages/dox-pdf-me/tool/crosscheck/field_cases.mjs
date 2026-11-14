// Crosscheck cases for signature, circleMark and multiVariableText.
// cases.mjs adds them to the cases. They have `fields: true`, so
// test/field_crosscheck_test.dart also compares each schema box on its own
// (the pixels in the box and the box of the ink), not only the whole page.
//
// Keep at least 2 mm between the boxes: a field is compared in its box
// plus 1 mm.

const page = { width: 210, height: 297, padding: [5, 5, 5, 5] };

let id = 0;
const box = (type, x, y, width, height, props = {}) => ({
  name: `${type}${++id}`,
  type,
  position: { x, y },
  width,
  height,
  ...props,
});

function fieldCase(name, rows, extra = {}) {
  const input = {};
  for (const [schema, value] of rows) {
    if (value !== undefined) input[schema.name] = value;
  }
  return {
    name,
    compare: 'pixels',
    fields: true,
    template: { basePdf: page, schemas: [rows.map(([s]) => s)] },
    inputs: [input],
    ...extra,
  };
}

const png = { $file: 'image.png', prefix: 'data:image/png;base64,' };
const jpg = { $file: 'image.jpg', prefix: 'data:image/jpeg;base64,' };

const signature = fieldCase('field-signature', [
  [box('signature', 10, 10, 62.5, 37.5), png],
  [box('signature', 80, 10, 40, 40), jpg],
  [box('signature', 130, 10, 60, 20, { rotate: 30 }), png],
  [box('signature', 10, 60, 45, 25, { opacity: 0.5 }), png],
  [box('signature', 70, 60, 30, 50, { rotate: 90 }), jpg],
  [box('signature', 120, 70, 60, 30, { objectFit: 'cover' }), png],
  [box('signature', 10, 120, 40, 20), ''],
  [box('signature', 60, 120, 40, 20), undefined],
  [box('signature', 110, 120, 20, 60, { objectPosition: 'left top' }), png],
]);

const circleMarks = fieldCase('field-circle-mark', [
  [box('circleMark', 10, 10, 10, 10, { color: '#000000', borderWidth: 1 }), 'true'],
  [box('circleMark', 30, 10, 30, 15, { color: '#d32f2f', borderWidth: 0.5 }), 'true'],
  [box('circleMark', 70, 10, 20, 20, { color: '#1565c0', borderWidth: 3, opacity: 0.5 }), 'true'],
  [box('circleMark', 100, 10, 40, 15, { color: '#2e7d32', borderWidth: 1.5, rotate: 45 }), 'true'],
  [box('circleMark', 155, 10, 30, 20, { color: '#ff000080', borderWidth: 2 }), 'true'],
  [box('circleMark', 10, 45, 15, 15, { color: '#f0a', borderWidth: 1 }), 'true'],
  [box('circleMark', 35, 45, 25, 12, { color: '#123456', borderWidth: 2, rotate: 90 }), 'true'],
  [box('circleMark', 70, 45, 15, 15, { color: '#000000', borderWidth: 1 }), 'false'],
  [box('circleMark', 95, 45, 15, 15, { color: '#000000', borderWidth: 1 }), ''],
  [box('circleMark', 120, 45, 15, 15, { color: 'red', borderWidth: 1 }), 'true'],
  [box('circleMark', 145, 45, 15, 15, { color: '#000000', borderWidth: 0 }), 'true'],
  [box('circleMark', 170, 45, 6, 6, { color: '#000000', borderWidth: 10 }), 'true'],
  [box('circleMark', 10, 75, 15, 15, { color: '#000000', borderWidth: 1 }), 'TRUE'],
  [box('circleMark', 35, 100, 60, 30, { color: '#6a1b9a', borderWidth: 4, rotate: 300, opacity: 0.7 }), 'true'],
  [box('circleMark', 110, 75, 15, 15, { borderWidth: 1 }), 'true'],
  [box('circleMark', 140, 75, 20, 20, { color: '#000000', borderWidth: 1 }), undefined],
]);

const mvt = (x, y, width, height, text, variables, props = {}) =>
  box('multiVariableText', x, y, width, height, { text, variables, ...props });

const vars = (o) => JSON.stringify(o);

const mvtCase = fieldCase('field-mvt', [
  [mvt(10, 10, 90, 10, 'Hello {name}, welcome to {city}!', ['name', 'city']),
    vars({ name: 'Ann', city: 'Paris' })],
  [mvt(110, 10, 90, 10, 'Hello {name}, welcome to {city}!', ['name', 'city']),
    vars({ name: 'Ann' })],
  [mvt(10, 25, 90, 10, 'Hello {name}!', ['name']), ''],
  [mvt(110, 25, 90, 10, 'Hello {name}! {unknown} {other stuff} end', ['name']),
    vars({ name: 'Bob', other: 'no' })],
  [mvt(10, 40, 90, 10, 'Price: {price} {p2} {p3} {p4}', ['price']),
    vars({ price: '$& / $$ / $` / $\' / $1', p2: 1.5, p3: true, p4: null })],
  [mvt(110, 40, 90, 25, 'Dear {name},\nYour order {order} is ready.\nThank you!', ['name', 'order'], {
    alignment: 'center',
    verticalAlignment: 'middle',
    fontColor: '#1565c0',
    backgroundColor: '#fff3e0',
    lineHeight: 1.3,
  }), vars({ name: 'Carol', order: '#1234' })],
  [mvt(10, 55, 90, 25, '{greeting} {name}. {long}', ['greeting', 'name', 'long'], {
    dynamicFontSize: { min: 4, max: 30, fit: 'vertical' },
  }), vars({ greeting: 'Hi', name: 'Dan', long: 'The quick brown fox jumps over the lazy dog.' })],
  [mvt(110, 72, 90, 12, 'Total: {total} for {name}', ['total', 'name'], {
    dynamicFontSize: { min: 5, max: 40, fit: 'horizontal' },
  }), vars({ total: '1,234.50', name: 'Eve' })],
  [mvt(10, 95, 40, 15, 'Turned {word}', ['word'], { rotate: 90, fontSize: 14 }), vars({ word: 'ninety' })],
  [mvt(60, 90, 40, 15, 'Half {word}', ['word'], { opacity: 0.5, fontSize: 16, underline: true }),
    vars({ word: 'see-through' })],
  [mvt(110, 92, 90, 15, 'Lato {name} {kanji}', ['name', 'kanji'], { fontName: 'Lato', fontSize: 15 }),
    vars({ name: 'Frank', kanji: 'x' })],
  [mvt(10, 125, 90, 15, '{jp}', ['jp'], { fontName: 'NotoSansJP', fontSize: 12 }),
    vars({ jp: 'こんにちは、{name}さん' })],
  [mvt(110, 115, 90, 10, 'Read only {name} in {city}', ['name', 'city'], {
    readOnly: true,
    content: vars({ name: 'Grace', city: 'Rome' }),
  }), undefined],
  [mvt(10, 145, 90, 10, 'Snapshot {name}', ['name'], {
    readOnly: true,
    contentSnapshot: true,
    content: 'Already filled text',
  }), undefined],
  [mvt(110, 130, 90, 10, 'No variables here {x}', [], {}), ''],
  // a raw string: JSON.stringify would sort the number keys first
  [mvt(10, 160, 90, 10, 'Order {a} / {b} / {1}', ['a', 'b']),
    '{"b":"B","a":"{b}","2":"two","1":"{2}"}'],
  [mvt(110, 145, 90, 10, 'Static {only}', [], { readOnly: true }), undefined],
  [mvt(10, 175, 90, 10, '', ['name']), vars({ name: 'Hidden' })],
  [mvt(110, 160, 90, 10, 'Strike {name}', ['name'], { strikethrough: true, characterSpacing: 1 }),
    vars({ name: 'out' })],
  [mvt(10, 190, 60, 30, '{a}\n{b}\n{c}', ['a', 'b', 'c'], {
    verticalAlignment: 'bottom',
    alignment: 'right',
    borderColor: '#000000',
    borderWidth: 0.5,
    padding: 2,
  }), vars({ a: 'first line', b: '', c: 'third line' })],
  [mvt(110, 175, 90, 30, 'Justify {text}', ['text'], { alignment: 'justify' }),
    vars({ text: 'The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.' })],
  [mvt(80, 225, 50, 20, '{name} small box with a long text that wraps', ['name'], {
    dynamicFontSize: { min: 3, max: 20, fit: 'vertical' },
    rotate: 30,
  }), vars({ name: 'Turned' })],
], { options: { font: {
  Roboto: { data: { $default: true }, fallback: true },
  Lato: { data: { $file: 'Lato-Regular.ttf' } },
  NotoSansJP: { data: { $file: 'NotoSansJP-Regular.otf' } },
} } });

export const fieldCases = [signature, circleMarks, mvtCase];
