// Forms with dox_pdf_lib and with pdf-lib (tool/crosscheck/form.mjs):
// - the same form made by both is read the same by pdf-lib;
// - a form made by pdf-lib, filled here, reads back right in pdf-lib;
// - flattened outputs render the same (pdftoppm, small tolerance).
// Needs `npm ci` in tool/crosscheck and pdftoppm; skipped without them.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

import 'support.dart';

const String _dir = 'tool/crosscheck';

bool get _hasNode => Directory('$_dir/node_modules/pdf-lib').existsSync();

bool get _hasPdftoppm {
  try {
    return Process.runSync('pdftoppm', <String>['-v']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// The scene of form.mjs.
Future<PDFDocument> _scene() async {
  PDFDocument doc = await PDFDocument.create(updateMetadata: false);
  PDFPage p1 = doc.addPage(<double>[600, 800]);
  PDFPage p2 = doc.addPage(<double>[600, 800]);
  PDFForm form = doc.getForm();

  PDFTextField name = form.createTextField('person.name');
  name.addToPage(p1, x: 50, y: 700, width: 200, height: 30);
  name.addToPage(p2, x: 50, y: 700, width: 300, height: 40);
  name.setText('Jane Doe');

  PDFTextField notes = form.createTextField('person.notes');
  notes.enableMultiline();
  notes.addToPage(p1, x: 50, y: 560, width: 250, height: 100);
  notes.setText('Line one wraps over the width of the box\nSecond line');

  PDFTextField code = form.createTextField('code');
  code.setMaxLength(6);
  code.enableCombing();
  code.addToPage(p1, x: 50, y: 500, width: 180, height: 30);
  code.setText('AB12CD');

  PDFTextField amount = form.createTextField('amount');
  amount.addToPage(
    p1,
    x: 50,
    y: 440,
    width: 150,
    height: 30,
    textColor: rgb(0, 0, 0.6),
    backgroundColor: rgb(0.95, 0.95, 0.8),
  );
  amount.setAlignment(TextAlignment.right);
  amount.setFontSize(14);
  amount.setText('42.50');

  PDFTextField rot = form.createTextField('rot');
  rot.addToPage(
    p1,
    x: 300,
    y: 250,
    width: 100,
    height: 30,
    rotate: degrees(90),
  );
  rot.setText('Up');

  PDFCheckBox agree = form.createCheckBox('agree');
  agree.addToPage(p1, x: 320, y: 700, width: 30, height: 30);
  agree.check();
  PDFCheckBox news = form.createCheckBox('news');
  news.addToPage(
    p1,
    x: 380,
    y: 700,
    width: 30,
    height: 30,
    borderColor: rgb(1, 0, 0),
  );

  PDFRadioGroup color = form.createRadioGroup('color');
  color.addOptionToPage('red', p1, x: 320, y: 620, width: 30, height: 30);
  color.addOptionToPage('green', p1, x: 380, y: 620, width: 30, height: 30);
  color.addOptionToPage('blue', p1, x: 440, y: 620, width: 30, height: 30);
  color.select('green');

  PDFDropdown country = form.createDropdown('country');
  country.addOptions(<String>['Japan', 'Myanmar', 'Thailand']);
  country.addToPage(p1, x: 320, y: 540, width: 200, height: 30);
  country.select('Myanmar');

  PDFOptionList langs = form.createOptionList('langs');
  langs.setOptions(<String>['Dart', 'Rust', 'TypeScript', 'Go']);
  langs.addToPage(p1, x: 320, y: 400, width: 200, height: 100);
  langs.select(<String>['Rust', 'Go']);

  PDFButton submit = form.createButton('submit');
  submit.addToPage('Submit', p1, x: 50, y: 350, width: 120, height: 40);
  return doc;
}

/// The `fill` of form.mjs.
void _fill(PDFForm form) {
  form.getTextField('person.name').setText('Filled by dox');
  form.getTextField('code').setText('XY');
  form.getCheckBox('agree').uncheck();
  form.getCheckBox('news').check();
  form.getRadioGroup('color').select('blue');
  form.getDropdown('country').select('Thailand');
  form.getOptionList('langs').select('Dart');
}

/// What we read, in the shape of `describe` in form.mjs.
List<Map<String, Object?>> _describe(PDFDocument doc) => <Map<String, Object?>>[
  for (PDFField f in doc.getForm().getFields())
    <String, Object?>{
      'name': f.getName(),
      'type': f.runtimeType.toString(),
      'value': switch (f) {
        PDFTextField t => t.getText(),
        PDFCheckBox c => c.isChecked(),
        PDFRadioGroup r => r.getSelected(),
        PDFDropdown d => d.getSelected(),
        PDFOptionList o => o.getSelected(),
        _ => null,
      },
      if (f is PDFRadioGroup) 'options': f.getOptions(),
      if (f is PDFDropdown) 'options': f.getOptions(),
      if (f is PDFOptionList) 'options': f.getOptions(),
      'widgets': f.acroField.getWidgets().length,
    },
];

Future<List<Object?>> _readWithPdfLib(List<String> files) async {
  ProcessResult r = await Process.run('node', <String>[
    '$_dir/form.mjs',
    'read',
    ...files,
  ]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return <Object?>[
    for (String line in LineSplitter.split(r.stdout as String))
      jsonDecode(line),
  ];
}

/// A PPM image (`P6`) from pdftoppm.
class _Ppm {
  _Ppm(Uint8List data) {
    int pos = 0;
    List<int> values = <int>[];
    while (values.length < 3) {
      while (data[pos] <= 32) {
        pos++;
      }
      if (data[pos] == 0x50) {
        pos += 2;
        continue;
      }
      int start = pos;
      while (data[pos] > 32) {
        pos++;
      }
      values.add(int.parse(ascii.decode(data.sublist(start, pos))));
    }
    width = values[0];
    height = values[1];
    pixels = Uint8List.sublistView(data, pos + 1);
  }

  late final int width;
  late final int height;
  late final Uint8List pixels;
}

Future<List<_Ppm>> _render(String pdf) async {
  String dir = '$pdf.img';
  Directory(dir).createSync();
  ProcessResult r = await Process.run('pdftoppm', <String>[
    '-r',
    '50',
    pdf,
    '$dir/p',
  ]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  List<File> files = Directory(dir).listSync().whereType<File>().toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  return <_Ppm>[for (File f in files) _Ppm(f.readAsBytesSync())];
}

Future<void> _sameRender(String ours, String theirs) async {
  List<_Ppm> a = await _render(ours);
  List<_Ppm> b = await _render(theirs);
  expect(a.length, b.length);
  for (int page = 0; page < a.length; page++) {
    expect((a[page].width, a[page].height), (b[page].width, b[page].height));
    int differ = 0;
    Uint8List x = a[page].pixels;
    Uint8List y = b[page].pixels;
    for (int i = 0; i < x.length; i += 3) {
      int d = 0;
      for (int c = 0; c < 3; c++) {
        int v = (x[i + c] - y[i + c]).abs();
        if (v > d) d = v;
      }
      if (d > 40) differ++;
    }
    expect(
      differ,
      lessThanOrEqualTo(20),
      reason: '$ours page ${page + 1}: $differ of ${x.length ~/ 3} differ',
    );
  }
}

void main() {
  late Directory tmp;
  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('dox_pdf_form');
    if (_hasNode) {
      ProcessResult r = await Process.run('node', <String>[
        '$_dir/form.mjs',
        'make',
        tmp.path,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  String skipNode = 'needs npm ci in tool/crosscheck';
  String skipRender = 'needs npm ci in tool/crosscheck and pdftoppm';

  test('the same form reads the same in pdf-lib and here', () async {
    PDFDocument doc = await _scene();
    String ours = '${tmp.path}/ours.pdf';
    File(ours).writeAsBytesSync(await doc.save());
    List<Object?> read = await _readWithPdfLib(<String>[
      ours,
      '${tmp.path}/forms.pdf',
    ]);
    // pdf-lib reads our form as it reads its own
    expect(read[0], read[1]);
    // and we read pdf-lib's form the same way
    PDFDocument theirs = await PDFDocument.load(
      File('${tmp.path}/forms.pdf').readAsBytesSync(),
    );
    expect(jsonDecode(jsonEncode(_describe(theirs))), read[1]);
  }, skip: _hasNode ? false : skipNode);

  test('a pdf-lib form filled here reads back in pdf-lib', () async {
    PDFDocument doc = await PDFDocument.load(
      File('${tmp.path}/forms.pdf').readAsBytesSync(),
    );
    _fill(doc.getForm());
    String out = '${tmp.path}/filled.pdf';
    File(out).writeAsBytesSync(await doc.save());
    List<Object?> read = await _readWithPdfLib(<String>[out]);
    Map<String, Object?> byName = <String, Object?>{
      for (Object? f in read[0]! as List<Object?>)
        (f! as Map<String, Object?>)['name']! as String:
            (f as Map<String, Object?>)['value'],
    };
    expect(byName['person.name'], 'Filled by dox');
    expect(byName['code'], 'XY');
    expect(byName['agree'], false);
    expect(byName['news'], true);
    expect(byName['color'], 'blue');
    expect(byName['country'], <Object?>['Thailand']);
    expect(byName['langs'], <Object?>['Dart']);
    // unrelated fields keep their values
    expect(byName['amount'], '42.50');
    expect(byName['person.notes'], startsWith('Line one'));
  }, skip: _hasNode ? false : skipNode);

  test('flattened forms render like pdf-lib', () async {
    PDFDocument doc = await _scene();
    doc.getForm().flatten();
    String ours = '${tmp.path}/ours-flat.pdf';
    File(ours).writeAsBytesSync(await doc.save());
    await _sameRender(ours, '${tmp.path}/forms-flat.pdf');
    expect(await _readWithPdfLib(<String>[ours]), <Object?>[<Object?>[]]);
  }, skip: _hasNode && _hasPdftoppm ? false : skipRender);

  test('load, fill and flatten renders like pdf-lib', () async {
    String theirs = '${tmp.path}/theirs-filled-flat.pdf';
    ProcessResult r = await Process.run('node', <String>[
      '$_dir/form.mjs',
      'fill',
      '${tmp.path}/forms.pdf',
      theirs,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    PDFDocument doc = await PDFDocument.load(
      File('${tmp.path}/forms.pdf').readAsBytesSync(),
      updateMetadata: false,
    );
    PDFForm form = doc.getForm();
    _fill(form);
    form.flatten();
    String ours = '${tmp.path}/ours-filled-flat.pdf';
    File(ours).writeAsBytesSync(await doc.save());
    await _sameRender(ours, theirs);
  }, skip: _hasNode && _hasPdftoppm ? false : skipRender);

  test('export / display options: /V gets the export value', () async {
    Uint8List pdf = buildPdf(<String>[
      '<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Annots [5 0 R] >>',
      '<< /Fields [5 0 R] >>',
      '<< /Type /Annot /Subtype /Widget /T (country) /FT /Ch /Ff 131072 '
          '/Opt [[(CA) (Canada)] [(MM) (Myanmar)]] /Rect [10 10 200 40] '
          '/P 3 0 R /DA (/Helv 0 Tf 0 g) >>',
    ]);
    PDFDocument doc = await PDFDocument.load(pdf);
    PDFDropdown d = doc.getForm().getDropdown('country');
    d.select('Canada');
    expect(d.getSelected(), <String>['Canada']);
    d.select('MM'); // an export value works too
    expect(d.getSelected(), <String>['Myanmar']);
    expect(d.isEditable(), isFalse);
    d.select('Canada');
    String out = '${tmp.path}/export.pdf';
    File(out).writeAsBytesSync(await doc.save());
    List<Object?> read = await _readWithPdfLib(<String>[out]);
    Map<String, Object?> field =
        (read[0]! as List<Object?>).first! as Map<String, Object?>;
    // pdf-lib returns /V as it is: the export value
    expect(field['value'], <Object?>['CA']);
    expect(field['options'], <Object?>['Canada', 'Myanmar']);
  }, skip: _hasNode ? false : skipNode);
}
