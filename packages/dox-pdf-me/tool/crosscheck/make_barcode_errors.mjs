// Makes test/fixtures/barcodes/barcode_errors.json: values that pass pdfme's
// check of a barcode type, and the error pdfme's generate fails with (null
// when it works). Run after `npm ci`:
//   node make_barcode_errors.mjs ../../test/fixtures/barcodes/barcode_errors.json
import { writeFileSync } from 'node:fs';
import { generate } from '@pdfme/generator';
import * as schemas from '@pdfme/schemas';

const gtin = '(01)09521234543213';
const cases = [
  // GS1: AIs and their values
  ['gs1datamatrix', `${gtin}(10)ABCDEFGHIJKLMNOPQRSTU`],
  ['gs1datamatrix', `${gtin}(21)ABCDEFGHIJKLMNOPQRST`],
  ['gs1datamatrix', `${gtin}(99)abc def`],
  ['gs1datamatrix', `${gtin}(10)a~b`],
  ['gs1datamatrix', `${gtin}(11)241399`],
  ['gs1datamatrix', `${gtin}(11)240230`],
  ['gs1datamatrix', `${gtin}(11)240229`],
  ['gs1datamatrix', `${gtin}(15)250229`],
  ['gs1datamatrix', `${gtin}(17)251300`],
  ['gs1datamatrix', `${gtin}(17)251200`],
  ['gs1datamatrix', `${gtin}(7006)240231`],
  ['gs1datamatrix', `${gtin}(4324)2401012560`],
  ['gs1datamatrix', `${gtin}(4324)2401012359`],
  ['gs1datamatrix', `${gtin}(777)1`],
  ['gs1datamatrix', `${gtin}(10)A(10)B`],
  ['gs1datamatrix', `${gtin}(10)A(10)A`],
  ['gs1datamatrix', `${gtin}(02)09521234543213`],
  ['gs1datamatrix', `${gtin}(00)095212345432134567`],
  ['gs1datamatrix', `${gtin}(00)095212345432134568`],
  ['gs1datamatrix', `${gtin}(3103)000123(3102)000456`],
  ['gs1datamatrix', `${gtin}(3103)000123(3203)000456`],
  ['gs1datamatrix', `${gtin}(422)528`],
  ['gs1datamatrix', `${gtin}(422)999`],
  ['gs1datamatrix', `${gtin}(422)52`],
  ['gs1datamatrix', `${gtin}(8008)24010112`],
  ['gs1datamatrix', `${gtin}(8008)240101`],
  ['gs1datamatrix', `${gtin}(8008)2401011`],
  ['gs1datamatrix', `${gtin}(3910)9781`],
  ['gs1datamatrix', `${gtin}(3910)978123`],
  ['gs1datamatrix', `${gtin}(8007)DE89370400440532013000`],
  ['gs1datamatrix', `${gtin}(8007)DE89370400440532013001`],
  ['gs1datamatrix', `${gtin}(8007)XX89370400440532013000`],
  ['gs1datamatrix', `${gtin}(8013)1987654Ad4X4bL5ttr2310c2K`],
  ['gs1datamatrix', `${gtin}(8013)1987654Ad4X4bL5ttr2310c2X`],
  ['gs1datamatrix', `${gtin}(7023)1234abcd`],
  ['gs1datamatrix', `${gtin}(8030)ABC=`],
  ['gs1datamatrix', `${gtin}(8030)AB=`],
  ['gs1datamatrix', `${gtin}(8030)A+B`],
  ['gs1datamatrix', `${gtin}(4321)2`],
  ['gs1datamatrix', `${gtin}(7240)abc`],
  ['gs1datamatrix', `${gtin}(8011)0123`],
  ['gs1datamatrix', `${gtin}(8026)095212345432130102`],
  ['gs1datamatrix', `${gtin}(8026)095212345432130302`],
  ['gs1datamatrix', `${gtin}(4330)000123+`],
  ['gs1datamatrix', `${gtin}(7041)ABC`],
  ['gs1datamatrix', `${gtin}(4307)ZZ`],
  ['gs1datamatrix', `${gtin}(4307)DE`],
  ['gs1datamatrix', `${gtin}(8112)00123451234561`],
  ['gs1datamatrix', `${gtin}(8112)1012345`],
  ['gs1datamatrix', `${gtin}(8110)106141411234562891011`],
  ['gs1datamatrix', `${gtin}(10)ABC123(21)XYZ`],
  // a later part's problem wins over a linter problem of an earlier part
  ['gs1datamatrix', `${gtin}(423)4440299`],
  ['gs1datamatrix', `${gtin}(7007)295964732`],
  ['gs1datamatrix', `${gtin}(8008)2890095988`],
  ['gs1datamatrix', 'x(01)09521234543213'],
  ['gs1datamatrix', `${gtin}()`],
  ['gs1datamatrix', `${gtin}(10`],
  ['gs1datamatrix', `${gtin}(10)é`],
  // other types
  ['qrcode', '\ud800abc'],
  ['qrcode', 'abc\udc00'],
  ['qrcode', '😀 ok'],
  ['code128', '\ud800'],
  ['pdf417', 'a\udfffb'],
  ['nw7', 'a123b'],
  ['nw7', 'A123d'],
  ['nw7', 'A123B'],
  ['code128', 'x'.repeat(500)],
  ['code128', 'x'.repeat(501)],
  ['code128', 'é'.repeat(251)],
  ['japanpost', '1234567' + '1'.repeat(13)],
  ['japanpost', '1234567' + '1'.repeat(14)],
  ['japanpost', '1234567ABCDEFG'],
  ['pdf417', '漢'.repeat(905)],
  ['pdf417', '漢'.repeat(1000)],
  ['pdf417', 'x'.repeat(1000)],
  ['upce', '00634045'],
  ['upce', '00634044'],
  ['upce', '0481683'],
  ['upce', '04816839'],
  ['code39', 'CODE\t39'],
  ['code39', 'CODE\n39'],
  ['code39', 'CODE\u00a039'],
  ['code39', 'CODE 39'],
];

const out = [];
for (const [type, value] of cases) {
  let message = null;
  try {
    await generate({
      template: {
        basePdf: { width: 100, height: 100, padding: [0, 0, 0, 0] },
        schemas: [[{ name: 'a', type, position: { x: 5, y: 5 }, width: 50, height: 30 }]],
      },
      inputs: [{ a: value }],
      plugins: { [type]: schemas.barcodes[type] },
    });
  } catch (e) {
    message = e.message;
  }
  out.push({ type, value, message });
}
writeFileSync(process.argv[2], JSON.stringify(out, null, 1));
console.log(out.filter((c) => c.message).length, 'of', out.length, 'fail');
