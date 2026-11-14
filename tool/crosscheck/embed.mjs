// Makes the embed and attachment files with pdf-lib, for the Dart tests:
//   node embed.mjs <out dir>
// Writes embed-source.pdf (a page with two content streams) and
// embed-pdflib.pdf (that page embedded and drawn 3 times, plus an
// attachment). test/crosscheck_test.dart makes the same with dox_pdf_lib.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { PDFDocument, BlendMode, AFRelationship, degrees, rgb } from 'pdf-lib';

const dir = process.argv[2];

const first = await PDFDocument.create();
const p = first.addPage([300, 200]);
p.drawRectangle({ x: 10, y: 10, width: 280, height: 180, color: rgb(0.9, 0.2, 0.2) });
p.drawText('Embed me', { x: 30, y: 120, size: 36 });
// load again and draw more: the page gets a second content stream
const source = await PDFDocument.load(await first.save());
source.getPage(0).drawCircle({ x: 240, y: 60, size: 40, color: rgb(0.1, 0.3, 0.9) });
const sourceBytes = await source.save();
writeFileSync(join(dir, 'embed-source.pdf'), sourceBytes);

const doc = await PDFDocument.create();
const [whole] = await doc.embedPdf(readFileSync(join(dir, 'embed-source.pdf')));
const src = await PDFDocument.load(sourceBytes);
const clipped = await doc.embedPage(src.getPage(0), { left: 20, bottom: 100, right: 220, top: 180 });
const page = doc.addPage([500, 500]);
page.drawPage(whole, { x: 20, y: 20, xScale: 0.5, yScale: 0.5 });
page.drawPage(whole, { x: 300, y: 100, rotate: degrees(30), opacity: 0.5, blendMode: BlendMode.Multiply });
page.drawPage(clipped, { x: 20, y: 300, width: 400, height: 160, xSkew: degrees(10) });
await doc.attach(new TextEncoder().encode('hello from pdf-lib'), 'hello.txt', {
  mimeType: 'text/plain',
  description: 'Grüße',
  creationDate: new Date(Date.UTC(2020, 0, 2, 3, 4, 5)),
  modificationDate: new Date(Date.UTC(2021, 0, 2, 3, 4, 5)),
  afRelationship: AFRelationship.Data,
});
writeFileSync(join(dir, 'embed-pdflib.pdf'), await doc.save());

// embed-order.pdf: drawPage, drawText, drawPage on one page must draw in
// that order (the text is over the first page and under the second)
const order = await PDFDocument.create();
const [o] = await order.embedPdf(sourceBytes);
const op = order.addPage([400, 300]);
op.drawPage(o, { x: 0, y: 0 });
op.drawText('Over', { x: 20, y: 60, size: 90, color: rgb(0, 0.6, 0) });
op.drawPage(o, { x: 150, y: 40, xScale: 0.5, yScale: 0.5 });
writeFileSync(join(dir, 'embed-order.pdf'), await order.save());

// embed-redo.pdf: a template page embedded, then drawn on, then embedded
// again: the second embed has the new text
const redo = await PDFDocument.create();
const template = await PDFDocument.load(sourceBytes);
await redo.embedPage(template.getPage(0));
template.getPage(0).drawText('Changed', { x: 20, y: 20, size: 40, color: rgb(0, 0, 0.5) });
// pdf-lib embeds the font of drawText at save; without this the copy
// points at a font object that is not there yet
await template.flush();
const again = await redo.embedPage(template.getPage(0));
redo.addPage([300, 200]).drawPage(again);
writeFileSync(join(dir, 'embed-redo.pdf'), await redo.save());
