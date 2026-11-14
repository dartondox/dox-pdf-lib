// Renders the crosscheck cases with the real pdfme generator.
//
//   node render.mjs <out dir> <file dir> [<file dir> ...]
//
// Writes <out dir>/<case name>.pdf for every case of cases.mjs, and the
// cases as <out dir>/cases.json. test/crosscheck_test.dart makes the same
// files with dox_pdf_me and compares the pages.
//
// In a case, `{"$file": "name"}` is the base64 of a file from one of the
// file dirs, and `{"$default": true}` is pdfme's default font (Roboto).
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { generate } from '@pdfme/generator';
import { getDefaultFont } from '@pdfme/common';
import * as schemas from '@pdfme/schemas';
import { cases } from './cases.mjs';

const [outDir, ...fileDirs] = process.argv.slice(2);

const plugins = {
  text: schemas.text,
  image: schemas.image,
  svg: schemas.svg,
  line: schemas.line,
  rectangle: schemas.rectangle,
  ellipse: schemas.ellipse,
  ...schemas.barcodes,
  date: schemas.date,
  time: schemas.time,
  dateTime: schemas.dateTime,
  checkbox: schemas.checkbox,
  radioGroup: schemas.radioGroup,
  select: schemas.select,
  table: schemas.table,
};

function readFile(name) {
  for (const dir of fileDirs) {
    const path = join(dir, name);
    if (existsSync(path)) return readFileSync(path);
  }
  throw new Error(`file not found: ${name}`);
}

function resolve(value) {
  if (Array.isArray(value)) return value.map(resolve);
  if (value && typeof value === 'object') {
    if ('$file' in value) {
      const b64 = readFile(value.$file).toString('base64');
      return value.prefix ? value.prefix + b64 : b64;
    }
    if ('$default' in value) return getDefaultFont().Roboto.data;
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, resolve(v)]));
  }
  return value;
}

// ONLY=<prefix>: render only the cases whose name starts with it
const only = process.env.ONLY;
const picked = only ? cases.filter((c) => c.name.startsWith(only)) : cases;

writeFileSync(join(outDir, 'cases.json'), JSON.stringify(picked, null, 1));
for (const c of picked) {
  const pdf = await generate({
    template: resolve(c.template),
    inputs: resolve(c.inputs),
    options: resolve(c.options ?? {}),
    plugins,
  });
  writeFileSync(join(outDir, `${c.name}.pdf`), pdf);
}
console.log(`rendered ${picked.length} cases`);
