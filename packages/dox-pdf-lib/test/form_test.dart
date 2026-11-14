import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A hand-made form: a parent with /FT /V /DA and two kid widgets on two
/// pages, a check box with no /DA, a broken kid, and XFA data.
Uint8List _handMade() => buildPdf(<String>[
  '<< /Type /Catalog /Pages 2 0 R /AcroForm 5 0 R >>',
  '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Annots [7 0 R 9 0 R] >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Annots [8 0 R] >>',
  '<< /Fields [6 0 R 9 0 R 10 0 R 99 0 R 42] /XFA [(x) 11 0 R] >>',
  '<< /T (group) /FT /Tx /V (inherited) /DA (/Helv 10 Tf 1 0 0 rg) '
      '/Kids [7 0 R 8 0 R] >>',
  '<< /Type /Annot /Subtype /Widget /Parent 6 0 R /Rect [10 10 110 40] /P 3 0 R >>',
  '<< /Type /Annot /Subtype /Widget /Parent 6 0 R /Rect [10 10 110 40] >>',
  '<< /Type /Annot /Subtype /Widget /T (box) /FT /Btn /Rect [150 10 170 30] >>',
  '<< /T (nothing) /Kids [12 0 R] >>',
  '<< >>',
  '<< /T (lost) /Parent 10 0 R /Kids [10 0 R] >>',
]);

void main() {
  test('create every field type, read them back', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage();
    PDFForm form = doc.getForm();
    form.createTextField('a.b.text').addToPage(page);
    form.createCheckBox('a.check').addToPage(page, y: 100);
    form.createRadioGroup('radio')
      ..addOptionToPage('x', page, y: 200)
      ..addOptionToPage('y', page, x: 60, y: 200);
    form.createDropdown('drop').addToPage(page, y: 300);
    form.createOptionList('list').addToPage(page, y: 400);
    form.createButton('button').addToPage('Go', page, y: 550);

    PDFDocument again = await PDFDocument.load(await doc.save());
    List<PDFField> fields = again.getForm().getFields();
    expect(
      <String>[for (PDFField f in fields) f.getName()],
      <String>['a.b.text', 'a.check', 'radio', 'drop', 'list', 'button'],
    );
    expect(fields[0], isA<PDFTextField>());
    expect(fields[1], isA<PDFCheckBox>());
    expect(fields[2], isA<PDFRadioGroup>());
    expect(fields[3], isA<PDFDropdown>());
    expect(fields[4], isA<PDFOptionList>());
    expect(fields[5], isA<PDFButton>());
    expect(again.getForm().getRadioGroup('radio').getOptions(), <String>[
      'x',
      'y',
    ]);
  });

  test('errors have the pdf-lib names', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage();
    PDFForm form = doc.getForm();
    PDFTextField text = form.createTextField('t')..addToPage(page);
    expect(
      () => form.createTextField('t'),
      throwsA(isA<FieldAlreadyExistsError>()),
    );
    expect(() => form.getField('nope'), throwsA(isA<NoSuchFieldError>()));
    expect(
      () => form.getCheckBox('t'),
      throwsA(isA<UnexpectedFieldTypeError>()),
    );
    expect(form.getFieldMaybe('nope'), isNull);
    expect(() => form.createTextField('a..b'), throwsA(isA<PDFLibError>()));
    text.setMaxLength(3);
    expect(() => text.setText('long'), throwsA(isA<ExceededMaxLengthError>()));
    text.setText('abc');
    expect(() => text.setMaxLength(2), throwsA(isA<InvalidMaxLengthError>()));
    expect(() => text.setFontSize(-1), throwsA(isA<PDFLibError>()));

    PDFDropdown drop = form.createDropdown('d')..setOptions(<String>['a', 'b']);
    drop.select('custom'); // makes the dropdown editable, like pdf-lib
    expect(drop.isEditable(), isTrue);
    expect(drop.getSelected(), <String>['custom']);
    PDFOptionList list = form.createOptionList('l')
      ..setOptions(<String>['a', 'b']);
    expect(() => list.select('c'), throwsA(isA<PDFLibError>()));
    list.select(<String>['a', 'b']);
    expect(list.isMultiselect(), isTrue);
  });

  test('text field flags and values', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFForm form = doc.getForm();
    PDFTextField t = form.createTextField('t');
    expect(t.getText(), isNull);
    t.setText('hi');
    expect(t.getText(), 'hi');
    t.setText(null);
    expect(t.getText(), isNull);
    expect(t.isCombed(), isFalse);
    t.setMaxLength(4);
    t.enableCombing();
    expect(t.isCombed(), isTrue);
    t.enableMultiline();
    expect(t.isCombed(), isFalse);
    t.enableReadOnly();
    t.enableRequired();
    t.disableExporting();
    expect(
      (t.isReadOnly(), t.isRequired(), t.isExported()),
      (true, true, false),
    );
    t.setAlignment(TextAlignment.center);
    expect(t.getAlignment(), TextAlignment.center);
    t.enableRichFormatting();
    expect(() => t.getText(), throwsA(isA<RichTextFieldReadError>()));
  });

  test(
    'a hand-made form: inherited values, several pages, broken parts',
    () async {
      PDFDocument doc = await PDFDocument.load(_handMade());
      PDFForm form = doc.getForm();
      // getForm removes the XFA data, like pdf-lib
      expect(form.hasXFA(), isFalse);
      List<PDFField> fields = form.getFields();
      expect(
        <String>[for (PDFField f in fields) f.getName()],
        <String>['group', 'box'],
      );
      PDFTextField group = form.getTextField('group');
      expect(group.getText(), 'inherited');
      List<PDFWidgetAnnotation> widgets = group.acroField.getWidgets();
      expect(widgets, hasLength(2));
      // the second widget has no /P: found by the /Annots of page 2
      expect(widgets[1].P(), doc.getPage(1).ref);
      expect(doc.findPageForAnnotationRef(widgets[1].ref), doc.getPage(1));

      group.setText('new');
      form.getCheckBox('box').check();
      form.flatten();
      expect(form.getFields(), isEmpty);
      for (PDFPage p in doc.getPages()) {
        expect(p.getSize().width, 300);
      }
      PDFDocument again = await PDFDocument.load(await doc.save());
      expect(again.getForm().getFields(), isEmpty);
    },
  );

  test('save updates appearances only after getForm', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage();
    doc.getForm().createTextField('t')
      ..addToPage(page)
      ..setText('x');
    PDFTextField t = doc.getForm().getTextField('t');
    expect(t.needsAppearancesUpdate(), isTrue);
    await doc.save(updateFieldAppearances: false);
    expect(t.needsAppearancesUpdate(), isTrue);
    await doc.save();
    expect(t.needsAppearancesUpdate(), isFalse);
  });

  test('remove a field takes its widgets off the page', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFPage page = doc.addPage();
    PDFForm form = doc.getForm();
    PDFTextField t = form.createTextField('p.t')..addToPage(page);
    form.createTextField('keep').addToPage(page, y: 100);
    form.removeField(t);
    expect(
      <String>[for (PDFField f in form.getFields()) f.getName()],
      <String>['keep'],
    );
    PDFDocument again = await PDFDocument.load(await doc.save());
    expect(again.getForm().getFields(), hasLength(1));
  });

  test('fill and flatten a big form is fast', () async {
    PDFDocument doc = await PDFDocument.create();
    PDFForm form = doc.getForm();
    for (int p = 0; p < 20; p++) {
      PDFPage page = doc.addPage();
      for (int i = 0; i < 25; i++) {
        form
            .createTextField('p$p.f$i')
            .addToPage(page, y: i * 30.0, height: 20);
      }
    }
    Uint8List template = await doc.save();
    Stopwatch sw = Stopwatch()..start();
    PDFDocument filled = await PDFDocument.load(template);
    PDFForm f = filled.getForm();
    for (int p = 0; p < 20; p++) {
      for (int i = 0; i < 25; i++) {
        f.getTextField('p$p.f$i').setText('value $p $i');
      }
    }
    f.flatten();
    await filled.save();
    sw.stop();
    // 500 fields; a few hundred ms even on a slow CI machine
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });
}
