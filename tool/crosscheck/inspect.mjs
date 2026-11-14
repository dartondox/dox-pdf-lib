// Prints what pdf-lib reads from PDF files, as JSON lines (one per file):
//   node inspect.mjs a.pdf b.pdf
// Loaded with updateMetadata: false, so the info is as in the file.
import { readFileSync } from 'node:fs';
import { PDFDocument, PDFName } from 'pdf-lib';

const iso = (d) => (d === undefined ? null : d.toISOString());
const box = (b) => [b.x, b.y, b.width, b.height];

for (const file of process.argv.slice(2)) {
  const doc = await PDFDocument.load(readFileSync(file), {
    updateMetadata: false,
    ignoreEncryption: true,
  });
  const lang = doc.catalog.lookup(PDFName.of('Lang'));
  console.log(
    JSON.stringify({
      pageCount: doc.getPageCount(),
      pages: doc.getPages().map((p) => ({
        size: [p.getWidth(), p.getHeight()],
        rotation: p.getRotation().angle,
        mediaBox: box(p.getMediaBox()),
        cropBox: box(p.getCropBox()),
        bleedBox: box(p.getBleedBox()),
        trimBox: box(p.getTrimBox()),
        artBox: box(p.getArtBox()),
      })),
      title: doc.getTitle() ?? null,
      author: doc.getAuthor() ?? null,
      subject: doc.getSubject() ?? null,
      keywords: doc.getKeywords() ?? null,
      creator: doc.getCreator() ?? null,
      producer: doc.getProducer() ?? null,
      creationDate: iso(doc.getCreationDate()),
      modificationDate: iso(doc.getModificationDate()),
      language: lang ? lang.decodeText() : null,
    }),
  );
}
