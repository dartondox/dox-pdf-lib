// Writes native/src/fonts.bin: the metrics of the 14 standard fonts and
// their encodings, from @pdf-lib/standard-fonts (the data pdf-lib uses), so
// text widths match pdf-lib exactly. Run it after npm ci:
//   node tool/crosscheck/gen_fonts.mjs
//
// Format (little endian), read by native/src/font.rs:
//   3 encodings (WinAnsi, Symbol, ZapfDingbats):
//     u16 n, then n x (u32 unicode, u8 code, u16 glyph id)
//   14 fonts (StandardFonts order):
//     u8 encoding, u8 name length, name, i16 x 4 bbox, i16 ascender,
//     i16 descender (0 when the font has none),
//     u16 n, n x (u16 glyph id, u16 width),
//     u16 n, n x (u16 left glyph id, u16 right glyph id, i16 kern)
// Glyph ids are indexes into a list of the glyph names of the encodings.
import { writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { Font, Encodings } = require('@pdf-lib/standard-fonts');

const fonts = [
  'Courier', 'Courier-Bold', 'Courier-Oblique', 'Courier-BoldOblique',
  'Helvetica', 'Helvetica-Bold', 'Helvetica-Oblique', 'Helvetica-BoldOblique',
  'Times-Roman', 'Times-Bold', 'Times-Italic', 'Times-BoldItalic',
  'Symbol', 'ZapfDingbats',
];
const encodings = [Encodings.WinAnsi, Encodings.Symbol, Encodings.ZapfDingbats];

const out = [];
const u8 = (v) => out.push(v & 0xff);
const u16 = (v) => out.push(v & 0xff, (v >> 8) & 0xff);
const i16 = (v) => u16(v < 0 ? v + 0x10000 : v);
const u32 = (v) => { u16(v & 0xffff); u16(v >>> 16); };

const ids = new Map();
const id = (name) => {
  if (!ids.has(name)) ids.set(name, ids.size);
  return ids.get(name);
};

for (const e of encodings) {
  u16(e.supportedCodePoints.length);
  for (const cp of e.supportedCodePoints) {
    const [code, name] = e.unicodeMappings[cp];
    u32(cp);
    u8(code);
    u16(id(name));
  }
}

for (const name of fonts) {
  const f = Font.load(name);
  u8(name === 'Symbol' ? 1 : name === 'ZapfDingbats' ? 2 : 0);
  u8(f.FontName.length);
  for (const c of f.FontName) u8(c.charCodeAt(0));
  f.FontBBox.forEach(i16);
  i16(f.Ascender ?? 0);
  i16(f.Descender ?? 0);
  const widths = f.CharMetrics.filter((m) => ids.has(m.N));
  u16(widths.length);
  for (const m of widths) {
    u16(ids.get(m.N));
    u16(m.WX);
  }
  const kerns = f.KernPairs.filter(([a, b]) => ids.has(a) && ids.has(b));
  u16(kerns.length);
  for (const [a, b, w] of kerns) {
    u16(ids.get(a));
    u16(ids.get(b));
    i16(w);
  }
}

const file = fileURLToPath(new URL('../../native/src/fonts.bin', import.meta.url));
writeFileSync(file, Uint8Array.from(out));
console.log(`${file}: ${out.length} bytes, ${ids.size} glyphs`);
