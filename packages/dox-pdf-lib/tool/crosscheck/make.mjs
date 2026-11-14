// Makes PDFs with pdf-lib, for the Dart tests to load:
//   node make.mjs <out dir>
// Writes made-by-pdf-lib.pdf (object streams, rotation, boxes, unicode
// info) and plain-xref.pdf (no object streams, many pages).
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { PDFDocument, PageSizes, degrees } from 'pdf-lib';

const dir = process.argv[2];

const a = await PDFDocument.create();
a.setTitle('Grüße 世界 😀');
a.setAuthor('Ann (pdf-lib)');
a.setSubject('crosscheck');
a.setKeywords(['one', 'two']);
a.setLanguage('de-DE');
a.setCreationDate(new Date(Date.UTC(2021, 4, 6, 7, 8, 9)));
a.setModificationDate(new Date(Date.UTC(2022, 0, 2, 3, 4, 5)));
const p1 = a.addPage(PageSizes.Letter);
p1.setRotation(degrees(270));
p1.setCropBox(10, 10, 500, 700);
p1.setTrimBox(20, 20, 400, 600);
p1.drawText('Hello from pdf-lib', { x: 50, y: 500 });
const p2 = a.addPage([300.5, 400.25]);
p2.setArtBox(1, 2, 3, 4);
p2.setBleedBox(5, 6, 7, 8);
writeFileSync(join(dir, 'made-by-pdf-lib.pdf'), await a.save());

const b = await PDFDocument.create();
for (let i = 0; i < 40; i++) b.addPage([100 + i, 200 + i]).drawText(`page ${i}`);
writeFileSync(join(dir, 'plain-xref.pdf'), await b.save({ useObjectStreams: false }));
