// Embeds custom fonts with pdf-lib + @pdf-lib/fontkit, for
// test/font_crosscheck_test.dart:
//   node fonts.mjs <out dir> <font dir>
// For each font in `fonts` and subset off / on, writes
// theirs-<font>-<subset>.pdf and prints the font metrics as JSON.
// Keep it in sync with the Dart test (`_samples`, `_scene`, `_metrics`).
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import fontkit from '@pdf-lib/fontkit';
import { PDFDocument, rgb } from 'pdf-lib';

const [dir, fontDir] = process.argv.slice(2);

export const fonts = ['Lato-Regular.ttf', 'SourceSans3-Regular.otf', 'NotoSansJP-Regular.otf'];

const latin = [
  'Hello World',
  'office fi ffl AVATAR Wa To. Ta Ty',
  'Grüße € „Quote“ naïve façade',
  'é a‍b x­z   ‑',
  '0123456789 ½ 1/2 ©®™',
  '',
];
const japanese = ['日本語のテキスト、カタカナ。', '漢字とひらがな ABC 123', '𠮷野家 ｱｲｳ'];
// only Japanese for the CJK font, see `_paragraph` in the Dart test
const paragraph = (font) =>
  font.startsWith('NotoSansJP')
    ? japanese.join(' ')
    : 'Wrapped text in a custom font, office files and fine ligatures here. ' + latin.join(' ');
export const samples = (font) => (font.startsWith('NotoSansJP') ? [...latin, ...japanese] : latin);

const out = [];
for (const name of fonts) {
  for (const subset of [false, true]) {
    const doc = await PDFDocument.create();
    doc.registerFontkit(fontkit);
    const f = await doc.embedFont(readFileSync(join(fontDir, name)), { subset });
    const set = samples(name);
    const cs = f.getCharacterSet();
    out.push({
      font: name,
      subset,
      name: f.name,
      widths: set.map((t) => f.widthOfTextAtSize(t, 12.5)),
      height: f.heightAtSize(12.5),
      heightNoDescender: f.heightAtSize(12.5, { descender: false }),
      sizeAtHeight: f.sizeAtHeight(20),
      charset: [cs.length, cs[0], cs[cs.length - 1]],
      encoded: set.map((t) => f.encodeText(t).toString()),
    });
    const page = doc.addPage([600, 800]);
    let y = 760;
    for (const t of set) {
      page.drawText(t, { x: 30, y, size: 18, font: f });
      y -= 30;
    }
    page.drawText(paragraph(name), {
      x: 30,
      y,
      size: 14,
      font: f,
      maxWidth: 400,
      lineHeight: 18,
      color: rgb(0.1, 0.3, 0.6),
    });
    writeFileSync(join(dir, `theirs-${name}-${subset}.pdf`), await doc.save());
  }
}
console.log(JSON.stringify(out));
