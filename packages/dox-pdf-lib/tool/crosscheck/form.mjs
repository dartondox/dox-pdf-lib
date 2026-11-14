// Forms with pdf-lib, for test/form_crosscheck_test.dart:
//   node form.mjs make <dir>        forms.pdf (filled) and forms-flat.pdf
//   node form.mjs read <a.pdf>...   the fields as JSON, one line per file
//   node form.mjs fill <in> <out>   fills like the test, then flattens
// Keep `scene` and `fill` the same as in the Dart test.
import { readFileSync, writeFileSync } from 'node:fs';
import {
  PDFDocument,
  PDFTextField,
  PDFCheckBox,
  PDFRadioGroup,
  PDFDropdown,
  PDFOptionList,
  TextAlignment,
  degrees,
  rgb,
} from 'pdf-lib';

const scene = async () => {
  const doc = await PDFDocument.create({ updateMetadata: false });
  const p1 = doc.addPage([600, 800]);
  const p2 = doc.addPage([600, 800]);
  const form = doc.getForm();

  const name = form.createTextField('person.name');
  name.addToPage(p1, { x: 50, y: 700, width: 200, height: 30 });
  name.addToPage(p2, { x: 50, y: 700, width: 300, height: 40 });
  name.setText('Jane Doe');

  const notes = form.createTextField('person.notes');
  notes.enableMultiline();
  notes.addToPage(p1, { x: 50, y: 560, width: 250, height: 100 });
  notes.setText('Line one wraps over the width of the box\nSecond line');

  const code = form.createTextField('code');
  code.setMaxLength(6);
  code.enableCombing();
  code.addToPage(p1, { x: 50, y: 500, width: 180, height: 30 });
  code.setText('AB12CD');

  const amount = form.createTextField('amount');
  amount.addToPage(p1, {
    x: 50,
    y: 440,
    width: 150,
    height: 30,
    textColor: rgb(0, 0, 0.6),
    backgroundColor: rgb(0.95, 0.95, 0.8),
  });
  amount.setAlignment(TextAlignment.Right);
  amount.setFontSize(14);
  amount.setText('42.50');

  const rot = form.createTextField('rot');
  rot.addToPage(p1, { x: 300, y: 250, width: 100, height: 30, rotate: degrees(90) });
  rot.setText('Up');

  const agree = form.createCheckBox('agree');
  agree.addToPage(p1, { x: 320, y: 700, width: 30, height: 30 });
  agree.check();
  const news = form.createCheckBox('news');
  news.addToPage(p1, { x: 380, y: 700, width: 30, height: 30, borderColor: rgb(1, 0, 0) });

  const color = form.createRadioGroup('color');
  color.addOptionToPage('red', p1, { x: 320, y: 620, width: 30, height: 30 });
  color.addOptionToPage('green', p1, { x: 380, y: 620, width: 30, height: 30 });
  color.addOptionToPage('blue', p1, { x: 440, y: 620, width: 30, height: 30 });
  color.select('green');

  const country = form.createDropdown('country');
  country.addOptions(['Japan', 'Myanmar', 'Thailand']);
  country.addToPage(p1, { x: 320, y: 540, width: 200, height: 30 });
  country.select('Myanmar');

  const langs = form.createOptionList('langs');
  langs.setOptions(['Dart', 'Rust', 'TypeScript', 'Go']);
  langs.addToPage(p1, { x: 320, y: 400, width: 200, height: 100 });
  langs.select(['Rust', 'Go']);

  const submit = form.createButton('submit');
  submit.addToPage('Submit', p1, { x: 50, y: 350, width: 120, height: 40 });

  return doc;
};

const fill = (form) => {
  form.getTextField('person.name').setText('Filled by dox');
  form.getTextField('code').setText('XY');
  form.getCheckBox('agree').uncheck();
  form.getCheckBox('news').check();
  form.getRadioGroup('color').select('blue');
  form.getDropdown('country').select('Thailand');
  form.getOptionList('langs').select('Dart');
};

const describe = (doc) =>
  doc
    .getForm()
    .getFields()
    .map((f) => {
      const out = { name: f.getName(), type: f.constructor.name, value: null };
      if (f instanceof PDFTextField) out.value = f.getText() ?? null;
      if (f instanceof PDFCheckBox) out.value = f.isChecked();
      if (f instanceof PDFRadioGroup) {
        out.value = f.getSelected() ?? null;
        out.options = f.getOptions();
      }
      if (f instanceof PDFDropdown || f instanceof PDFOptionList) {
        out.value = f.getSelected();
        out.options = f.getOptions();
      }
      out.widgets = f.acroField.getWidgets().length;
      return out;
    });

const [mode, ...args] = process.argv.slice(2);
if (mode === 'make') {
  const [dir] = args;
  let doc = await scene();
  writeFileSync(`${dir}/forms.pdf`, await doc.save());
  doc = await scene();
  doc.getForm().flatten();
  writeFileSync(`${dir}/forms-flat.pdf`, await doc.save());
} else if (mode === 'read') {
  for (const file of args) {
    const doc = await PDFDocument.load(readFileSync(file), { updateMetadata: false });
    console.log(JSON.stringify(describe(doc)));
  }
} else if (mode === 'fill') {
  const [input, output] = args;
  const doc = await PDFDocument.load(readFileSync(input), { updateMetadata: false });
  const form = doc.getForm();
  fill(form);
  form.flatten();
  writeFileSync(output, await doc.save());
} else {
  throw new Error(`unknown mode ${mode}`);
}
