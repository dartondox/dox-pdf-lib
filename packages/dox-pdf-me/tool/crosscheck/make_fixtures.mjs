// Makes the small fixture files of the crosscheck (run once; the files are
// committed in test/fixtures/crosscheck):
//   node make_fixtures.mjs <out dir>
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { deflateSync } from 'node:zlib';
import jpeg from 'jpeg-js';
import { PDFDocument, StandardFonts, rgb } from '@pdfme/pdf-lib';

const out = process.argv[2];

// a 24x16 RGBA PNG: a color gradient with a half transparent stripe
function crc32(buf) {
  let c, crc = 0xffffffff;
  for (const b of buf) {
    c = (crc ^ b) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
const w = 24, h = 16;
const raw = [];
for (let y = 0; y < h; y++) {
  raw.push(0);
  for (let x = 0; x < w; x++) {
    raw.push(Math.round((x / (w - 1)) * 255), Math.round((y / (h - 1)) * 255), 160, y >= 6 && y < 10 ? 128 : 255);
  }
}
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(w, 0);
ihdr.writeUInt32BE(h, 4);
ihdr[8] = 8; ihdr[9] = 6;
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', deflateSync(Buffer.from(raw))),
  chunk('IEND', Buffer.alloc(0)),
]);
writeFileSync(join(out, 'image.png'), png);

// a 16x24 JPEG (portrait): blocks of color
const jw = 16, jh = 24;
const data = Buffer.alloc(jw * jh * 4);
for (let y = 0; y < jh; y++) for (let x = 0; x < jw; x++) {
  const i = (y * jw + x) * 4;
  data[i] = y < 12 ? 220 : 30; data[i + 1] = x < 8 ? 40 : 200; data[i + 2] = 90; data[i + 3] = 255;
}
writeFileSync(join(out, 'image.jpg'), jpeg.encode({ data, width: jw, height: jh }, 90).data);

// a 2 page base PDF; page 2 has a crop box that does not start at 0,0
const doc = await PDFDocument.create();
const font = await doc.embedFont(StandardFonts.Helvetica);
const p1 = doc.addPage([400, 300]);
p1.drawRectangle({ x: 20, y: 20, width: 360, height: 260, borderColor: rgb(0.2, 0.4, 0.8), borderWidth: 3 });
p1.drawText('Base page 1', { x: 30, y: 250, size: 18, font, color: rgb(0.2, 0.4, 0.8) });
const p2 = doc.addPage([400, 300]);
p2.drawRectangle({ x: 0, y: 0, width: 400, height: 300, color: rgb(0.95, 0.9, 0.8) });
p2.drawText('Base page 2', { x: 60, y: 220, size: 18, font, color: rgb(0.6, 0.2, 0.2) });
p2.setCropBox(40, 30, 320, 240);
writeFileSync(join(out, 'base.pdf'), await doc.save({ useObjectStreams: false }));

// copies with an EXIF orientation: JPEG 3, 6 and 8 (APP1), PNG 6 (eXIf)
function tiff(orientation) {
  const t = Buffer.alloc(26);
  t.write('MM', 0, 'ascii');
  t.writeUInt16BE(42, 2);
  t.writeUInt32BE(8, 4);
  t.writeUInt16BE(1, 8);
  t.writeUInt16BE(0x0112, 10);
  t.writeUInt16BE(3, 12);
  t.writeUInt32BE(1, 14);
  t.writeUInt16BE(orientation, 18);
  t.writeUInt32BE(0, 22);
  return t;
}
const plainJpg = readFileSync(join(out, 'image.jpg'));
for (const o of [3, 6, 8]) {
  const payload = Buffer.concat([Buffer.from('Exif\0\0', 'binary'), tiff(o)]);
  const len = Buffer.alloc(2);
  len.writeUInt16BE(payload.length + 2);
  const app1 = Buffer.concat([Buffer.from([0xff, 0xe1]), len, payload]);
  writeFileSync(join(out, `image-o${o}.jpg`), Buffer.concat([plainJpg.subarray(0, 2), app1, plainJpg.subarray(2)]));
}
const iend = png.length - 12;
writeFileSync(join(out, 'image-o6.png'), Buffer.concat([png.subarray(0, iend), chunk('eXIf', tiff(6)), png.subarray(iend)]));
