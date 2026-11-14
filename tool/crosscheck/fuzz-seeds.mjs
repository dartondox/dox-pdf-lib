// Makes small seed PDFs for the `load` fuzz target (native/fuzz/corpus/load).
// Run: node tool/crosscheck/fuzz-seeds.mjs <out dir>
import { writeFileSync } from 'node:fs';
import { PDFDocument, StandardFonts, rgb, degrees } from 'pdf-lib';

const out = process.argv[2];
const png = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR4nGP4z8DwnwEIGBgYGBgYAAAyGgP9Z9VXGQAAAABJRU5ErkJggg==',
  'base64',
);

async function form() {
  const doc = await PDFDocument.create();
  const page = doc.addPage([300, 300]);
  const f = doc.getForm();
  const t = f.createTextField('a.name');
  t.setText('Hi');
  t.addToPage(page, { x: 10, y: 250, width: 120, height: 20 });
  const comb = f.createTextField('comb');
  comb.setMaxLength(5);
  comb.enableCombing();
  comb.addToPage(page, { x: 10, y: 220, width: 100, height: 20 });
  const c = f.createCheckBox('agree');
  c.addToPage(page, { x: 10, y: 190 });
  c.check();
  const r = f.createRadioGroup('color');
  r.addOptionToPage('red', page, { x: 10, y: 150 });
  r.addOptionToPage('blue', page, { x: 50, y: 150 });
  const d = f.createDropdown('country');
  d.addOptions(['Myanmar', 'Thailand']);
  d.addToPage(page, { x: 10, y: 100, width: 100, height: 20 });
  const o = f.createOptionList('many');
  o.addOptions(['a', 'b', 'c']);
  o.addToPage(page, { x: 150, y: 100, width: 100, height: 60 });
  return doc.save({ useObjectStreams: false });
}

async function drawing() {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const img = await doc.embedPng(png);
  const page = doc.addPage([200, 200]);
  page.setRotation(degrees(90));
  page.drawText('Hello', { x: 10, y: 150, font, size: 12, color: rgb(1, 0, 0) });
  page.drawImage(img, { x: 10, y: 10, width: 20, height: 20, opacity: 0.5 });
  page.drawSvgPath('M 0 0 L 50 50 Q 60 70 80 20 Z', { x: 20, y: 100 });
  await doc.attach(Buffer.from('hello'), 'a.txt', { mimeType: 'text/plain' });
  const src = await PDFDocument.create();
  src.addPage([100, 100]).drawText('embedded', { x: 5, y: 50 });
  const [e] = await doc.embedPdf(await src.save());
  page.drawPage(e, { x: 100, y: 100, xScale: 0.5, yScale: 0.5 });
  doc.setTitle('Seed ทดสอบ');
  return doc.save({ useObjectStreams: false });
}

async function streams() {
  const doc = await PDFDocument.create();
  for (let i = 0; i < 3; i++) doc.addPage([100 + i, 100]);
  doc.setAuthor('seed');
  return doc.save({ useObjectStreams: true });
}

writeFileSync(`${out}/seed-form.pdf`, await form());
writeFileSync(`${out}/seed-drawing.pdf`, await drawing());
writeFileSync(`${out}/seed-object-streams.pdf`, await streams());
