// Prints the attachments that pdf-lib reads from PDF files, as JSON lines
// (one per file): node attachments.mjs a.pdf b.pdf
// pdf-lib has no getter, so this reads /Names /EmbeddedFiles by hand.
import { readFileSync } from 'node:fs';
import {
  PDFDocument,
  PDFName,
  PDFDict,
  PDFArray,
  PDFHexString,
  PDFString,
  decodePDFRawStream,
} from 'pdf-lib';

const text = (v) => (v instanceof PDFHexString || v instanceof PDFString ? v.decodeText() : null);

for (const file of process.argv.slice(2)) {
  const doc = await PDFDocument.load(readFileSync(file), { updateMetadata: false });
  const names = doc.catalog.lookupMaybe(PDFName.of('Names'), PDFDict);
  const tree = names?.lookupMaybe(PDFName.of('EmbeddedFiles'), PDFDict);
  const list = tree?.lookupMaybe(PDFName.of('Names'), PDFArray);
  const out = [];
  for (let i = 0; list && i < list.size(); i += 2) {
    const spec = list.lookup(i + 1, PDFDict);
    const stream = spec.lookup(PDFName.of('EF'), PDFDict).lookup(PDFName.of('F'));
    const params = stream.dict.lookupMaybe(PDFName.of('Params'), PDFDict);
    out.push({
      key: text(list.lookup(i)),
      name: text(spec.lookup(PDFName.of('UF'))),
      data: Buffer.from(decodePDFRawStream(stream).decode()).toString('base64'),
      mimeType: stream.dict.lookupMaybe(PDFName.of('Subtype'), PDFName)?.decodeText() ?? null,
      description: text(spec.lookup(PDFName.of('Desc'))),
      creationDate: text(params?.lookup(PDFName.of('CreationDate'))),
      modificationDate: text(params?.lookup(PDFName.of('ModDate'))),
      afRelationship: spec.lookupMaybe(PDFName.of('AFRelationship'), PDFName)?.decodeText() ?? null,
    });
  }
  const af = doc.catalog.lookupMaybe(PDFName.of('AF'), PDFArray);
  console.log(JSON.stringify({ files: out, af: af ? af.size() : 0 }));
}
