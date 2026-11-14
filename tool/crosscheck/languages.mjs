// The language matrix (test/language_test.dart) for the languages that
// fontkit lays out like HarfBuzz:
//   node languages.mjs <out dir> <font dir> <json>
// <json> is {name: {font, lines}}. For each language, writes
// theirs-<name>.pdf (the lines, then the lines as one wrapped paragraph,
// full font) and prints the widths of the lines at size 16 as JSON.
// Keep the drawing in sync with `_draw` in the Dart test.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import fontkit from '@pdf-lib/fontkit';
import { PDFDocument } from 'pdf-lib';

const [dir, fontDir, json] = process.argv.slice(2);
const out = {};
for (const [name, { font, lines }] of Object.entries(JSON.parse(json))) {
  const doc = await PDFDocument.create();
  doc.registerFontkit(fontkit);
  const f = await doc.embedFont(readFileSync(join(fontDir, font)));
  out[name] = lines.map((t) => f.widthOfTextAtSize(t, 16));
  const page = doc.addPage([500, 500]);
  let y = 460;
  for (const t of lines) {
    page.drawText(t, { x: 20, y, size: 16, font: f });
    y -= 30;
  }
  page.drawText(lines.join(' '), { x: 20, y, size: 14, font: f, maxWidth: 150, lineHeight: 22 });
  writeFileSync(join(dir, `theirs-${name}.pdf`), await doc.save());
}
console.log(JSON.stringify(out));
