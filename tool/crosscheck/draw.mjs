// Draws the crosscheck scene with pdf-lib, for test/draw_crosscheck_test.dart:
//   node draw.mjs <out dir> <fixtures dir>
// Writes theirs.pdf (the scene), base.pdf (a page with old content) and
// theirs-loaded.pdf (base.pdf loaded, then drawn on). Prints the font
// metrics as JSON. The Dart test draws the same with dox_pdf_lib and
// compares the rendered pages and the metrics.
// Keep it in sync with `_scene` in the Dart test.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  BlendMode,
  LineCapStyle,
  PDFDocument,
  StandardFonts,
  cmyk,
  degrees,
  grayscale,
  rgb,
  scale,
  popGraphicsState,
  pushGraphicsState,
  setFillingRgbColor,
  rectangle,
  fill,
} from 'pdf-lib';

const [dir, fixtures] = process.argv.slice(2);
// a copy: pdf-lib reads JPEG headers from `bytes.buffer`, and small Node
// buffers share one bigger buffer
const read = (f) => new Uint8Array(readFileSync(join(fixtures, f)));

export const samples = {
  WinAnsi: ['Hello World', 'AVATAR To. Wa', 'Grüße € „Quote“', ''],
  Symbol: ['αβγ ∑∞ ≠'],
  ZapfDingbats: ['✓✈❤ ➔'],
};

const fonts = Object.values(StandardFonts);
const doc = await PDFDocument.create();

const metrics = [];
for (const name of fonts) {
  const f = doc.embedStandardFont(name);
  const set =
    name === 'Symbol' ? samples.Symbol : name === 'ZapfDingbats' ? samples.ZapfDingbats : samples.WinAnsi;
  const cs = f.getCharacterSet();
  metrics.push({
    name: f.name,
    widths: set.map((t) => f.widthOfTextAtSize(t, 12.5)),
    height: f.heightAtSize(12.5),
    heightNoDescender: f.heightAtSize(12.5, { descender: false }),
    sizeAtHeight: f.sizeAtHeight(20),
    charset: [cs.length, cs[0], cs[cs.length - 1]],
    encoded: f.encodeText(set[0]).toString(),
  });
}

const times = await doc.embedFont(StandardFonts.TimesRomanBold);
const courier = await doc.embedFont(StandardFonts.Courier);
const symbol = await doc.embedFont(StandardFonts.Symbol);
const zapf = await doc.embedFont(StandardFonts.ZapfDingbats);

// page 1: text and shapes
const p1 = doc.addPage([600, 800]);
p1.drawText('Hello pdf-lib', { x: 50, y: 750 });
p1.drawText('Times bold, rotated', {
  x: 50, y: 700, font: times, size: 20, color: rgb(0.2, 0.4, 0.6), rotate: degrees(10),
});
p1.drawText(
  'Courier wraps this long line of text at the max width.\nA new line, and more words to wrap again here.',
  { x: 50, y: 640, font: courier, size: 12, lineHeight: 14, maxWidth: 220 },
);
p1.drawText('Skewed, half opacity, multiply', {
  x: 320, y: 640, size: 14, opacity: 0.5, blendMode: BlendMode.Multiply, xSkew: degrees(15), ySkew: degrees(5),
});
p1.drawText('A-B-C-D-E-F-G-H-I-J-K', {
  x: 320, y: 600, size: 14, maxWidth: 80, wordBreaks: ['-'], color: cmyk(0.1, 0.8, 0.2, 0.1),
});
p1.drawText(samples.Symbol[0], { x: 320, y: 520, font: symbol, size: 18 });
p1.drawText(samples.ZapfDingbats[0], { x: 450, y: 520, font: zapf, size: 18, color: grayscale(0.3) });
p1.drawRectangle({
  x: 50, y: 400, width: 200, height: 100, color: cmyk(0.5, 0.1, 0, 0.1), borderColor: rgb(1, 0, 0),
  borderWidth: 3, borderDashArray: [5, 3], rotate: degrees(5), opacity: 0.7, borderOpacity: 0.5,
});
p1.drawSquare({ x: 300, y: 400, size: 60, color: grayscale(0.5) });
p1.drawRectangle({ x: 380, y: 400, width: 50, height: 30, borderColor: rgb(0, 0.5, 0), borderWidth: 2, xSkew: degrees(20) });
p1.drawEllipse({ x: 500, y: 450, xScale: 60, yScale: 30, borderColor: rgb(1, 0, 0), borderWidth: 2, rotate: degrees(20) });
p1.drawCircle({ x: 500, y: 330, size: 40, color: rgb(0, 0.6, 0), borderColor: rgb(0, 0, 0), borderWidth: 1, opacity: 0.8 });
p1.drawEllipse({ x: 400, y: 330, xScale: 30, yScale: 50, color: rgb(0.9, 0.6, 0) });
p1.drawLine({
  start: { x: 50, y: 360 }, end: { x: 300, y: 330 }, thickness: 4, color: rgb(0, 0, 1),
  lineCap: LineCapStyle.Round, dashArray: [10, 5], opacity: 0.6,
});
p1.drawLine({ start: { x: 50, y: 340 }, end: { x: 300, y: 310 } });
p1.drawSvgPath('M 0,20 L 100,160 Q 130,200 150,120 C 190,-40 200,200 300,150 L 400,90', {
  x: 50, y: 300, scale: 0.5, borderColor: rgb(0.5, 0, 0.5), borderWidth: 3,
});
p1.drawSvgPath('M10 80 C 40 10, 65 10, 95 80 S 150 150, 180 80 Z m 20 0 a 25 25 0 1 0 50 0 a 25 25 0 0 1 -50 0', {
  x: 250, y: 300, color: rgb(0.2, 0.7, 0.9), borderColor: rgb(0, 0, 0), borderWidth: 1, rotate: degrees(-5),
});
p1.drawSvgPath('M10 10 h 80 v 80 h -80 Z M30 30 t 20 10 t 20 -10 T 70 60', { x: 450, y: 250, color: rgb(1, 0.8, 0) });
p1.pushOperators(pushGraphicsState(), setFillingRgbColor(0.9, 0.1, 0.1), rectangle(520, 40, 50, 30), fill(), popGraphicsState());

// page 2: images, page state
const p2 = doc.addPage([600, 800]);
const images = [];
for (const f of ['rgb.jpg', 'gray.jpg', 'cmyk.jpg']) images.push(await doc.embedJpg(read(f)));
for (const f of ['rgba-interlaced.png', 'rgb16.png', 'gray16.png', 'gray1.png', 'palette-trns.png']) {
  images.push(await doc.embedPng(read(f)));
}
p2.drawRectangle({ x: 0, y: 500, width: 600, height: 300, color: rgb(0.8, 0.9, 0.8) });
images.forEach((img, i) => {
  const { width, height } = img.scale(2);
  p2.drawImage(img, { x: 20 + (i % 4) * 140, y: 700 - Math.floor(i / 4) * 120, width, height });
});
p2.drawImage(images[0], { x: 300, y: 300, width: 120, height: 90, rotate: degrees(30), opacity: 0.5 });
p2.drawImage(images[3], { x: 100, y: 300, ...images[3].scaleToFit(100, 200), xSkew: degrees(10) });
p2.moveTo(50, 200);
p2.setFont(times);
p2.setFontSize(18);
p2.setFontColor(rgb(0.6, 0, 0));
p2.setLineHeight(22);
p2.drawText('Page state text\nsecond line');
p2.moveDown(60);
p2.moveRight(10);
p2.drawText('Moved');
p2.translateContent(20, -20);
p2.drawText('After translate', { x: 300, y: 150 });

// page 3: scale
const p3 = doc.addPage([400, 400]);
p3.drawRectangle({ x: 50, y: 50, width: 300, height: 300, color: rgb(0.3, 0.3, 0.9) });
p3.drawText('Scaled page', { x: 60, y: 200, size: 30, color: rgb(1, 1, 1) });
p3.scale(1.5, 0.75);

writeFileSync(join(dir, 'theirs.pdf'), await doc.save());

// old content that leaves a transform set: drawing on it must not be scaled
const base = await PDFDocument.create();
const bp = base.addPage([300, 300]);
bp.pushOperators(scale(0.5, 0.5));
bp.drawRectangle({ x: 0, y: 0, width: 300, height: 300, color: rgb(0.9, 0.9, 0.5) });
const baseBytes = await base.save();
writeFileSync(join(dir, 'base.pdf'), baseBytes);
const loaded = await PDFDocument.load(baseBytes);
const lp = loaded.getPage(0);
lp.drawText('On a loaded page', { x: 20, y: 250, size: 20 });
lp.drawCircle({ x: 150, y: 150, size: 50, color: rgb(1, 0, 0) });
writeFileSync(join(dir, 'theirs-loaded.pdf'), await loaded.save());
console.log(JSON.stringify(metrics));
