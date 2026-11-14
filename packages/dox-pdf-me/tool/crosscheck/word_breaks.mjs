// Makes test/fixtures/sa_word_breaks.json: the Thai, Lao, Khmer and
// Myanmar word breaks of the sentences of sa_text.mjs, found the way pdfme
// finds them (collectSaDictionaryBreaks in packages/schemas/src/text/wrap.ts):
// each run of SA letters goes to Intl.Segmenter, and the segment ends
// inside the run are the breaks.
//
//   node word_breaks.mjs ../../test/fixtures/sa_word_breaks.json
//
// Needs `npm ci` here (pdfme's line break table). The ICU version of
// Node.js picks the word dictionaries, so the script runs only on the
// pinned Node.js major and writes the versions it used.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { saSentences } from './sa_text.mjs';

const pinnedMajor = 24;
if (Number(process.versions.node.split('.')[0]) !== pinnedMajor) {
  console.error(`use Node.js ${pinnedMajor}, not ${process.versions.node}`);
  process.exit(1);
}

// pdfme's line break class table (not exported, so read from its bundle)
const dist = join(import.meta.dirname, 'node_modules/@pdfme/schemas/dist');
const marker = 'LINE_BREAK_RANGE_DATA = new Uint32Array([';
const bundle = readdirSync(dist)
  .filter((f) => f.endsWith('.js'))
  .map((f) => readFileSync(join(dist, f), 'utf8'))
  .find((s) => s.includes(marker));
const start = bundle.indexOf(marker) + marker.length;
const ranges = bundle.slice(start, bundle.indexOf(']', start)).split(',').map(Number);
const SA = 39;
function isSaCodePoint(codePoint) {
  let low = 0;
  let high = ranges.length / 3 - 1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    if (codePoint < ranges[mid * 3]) high = mid - 1;
    else if (codePoint > ranges[mid * 3 + 1]) low = mid + 1;
    else return ranges[mid * 3 + 2] === SA;
  }
  return false;
}

// the same code as pdfme's collectSaDictionaryBreaks
const segmenter = new Intl.Segmenter(undefined, { granularity: 'word' });
function saBreaks(text) {
  const breaks = [];
  let index = 0;
  while (index < text.length) {
    const codePoint = text.codePointAt(index);
    const unitLength = codePoint > 0xffff ? 2 : 1;
    if (!isSaCodePoint(codePoint)) {
      index += unitLength;
      continue;
    }
    const start = index;
    index += unitLength;
    while (index < text.length) {
      const next = text.codePointAt(index);
      if (!isSaCodePoint(next)) break;
      index += next > 0xffff ? 2 : 1;
    }
    let offset = start;
    for (const { segment } of segmenter.segment(text.slice(start, index))) {
      offset += segment.length;
      if (offset > start && offset < index) breaks.push(offset);
    }
  }
  return breaks;
}

const cases = [];
for (const [language, sentences] of Object.entries(saSentences)) {
  for (const text of sentences) cases.push({ language, text, breaks: saBreaks(text) });
}

// one sentence per line, so a diff shows the sentence that changed
const head = {
  node: process.versions.node,
  icu: process.versions.icu,
  unicode: process.versions.unicode,
};
const json = JSON.stringify({ ...head, cases: [] }, null, 1).replace(
  '"cases": []',
  `"cases": [\n${cases.map((c) => `  ${JSON.stringify(c)}`).join(',\n')}\n ]`,
);
writeFileSync(process.argv[2], json + '\n');
console.log(`wrote ${cases.length} sentences`);
