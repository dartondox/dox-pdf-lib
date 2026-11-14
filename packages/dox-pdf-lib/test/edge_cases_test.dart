// Edge cases across features: the life of a document, work at the same
// time, damaged files, very big input, and one template reused many times.
// The behavior of plain calls (bad index, bad name, ...) was compared with
// pdf-lib 1.17.1; the comments say what pdf-lib does.
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

Uint8List _font(String name) =>
    File('test/fixtures/fonts/$name').readAsBytesSync();

/// A small file with a bit of every feature: text in a custom font, an
/// image, a form, an attachment and an embedded page.
Future<Uint8List> _richPdf() async {
  PDFDocument doc = await PDFDocument.create();
  PDFFont thai = await doc.embedFont(_font('noto-sans-thai.ttf'), subset: true);
  PDFImage png = await doc.embedPng(
    File('test/fixtures/palette-trns.png').readAsBytesSync(),
  );
  PDFPage page = doc.addPage(PageSizes.A5);
  page.drawText('สวัสดี น้ำ', x: 20, y: 500, font: thai, size: 18);
  page.drawImage(png, x: 20, y: 300, width: 50, height: 50);
  PDFForm form = doc.getForm();
  form
      .createTextField('name')
      .addToPage(page, x: 20, y: 200, width: 150, height: 20);
  form
      .createCheckBox('ok')
      .addToPage(page, x: 20, y: 150, width: 15, height: 15);
  await doc.attach(Uint8List.fromList(<int>[1, 2, 3]), 'a.bin');
  PDFDocument src = await PDFDocument.create();
  src.addPage(<double>[100, 100]).drawText('src', x: 10, y: 50);
  PDFEmbeddedPage e = (await doc.embedPdf(await src.save())).first;
  page.drawPage(e, x: 200, y: 400, xScale: 0.5, yScale: 0.5);
  doc.setTitle('rich');
  return doc.save(useObjectStreams: false);
}

/// Loads [bytes] and checks the result is a usable document, or a typed
/// [PDFLibError]. Any other error (or a crash) fails the test.
Future<void> _loadOrTypedError(Uint8List bytes) async {
  PDFDocument doc;
  try {
    doc = await PDFDocument.load(bytes, ignoreEncryption: true);
  } on PDFLibError {
    return;
  }
  try {
    for (PDFPage p in doc.getPages()) {
      p.getSize();
      p.getRotation();
    }
    doc.getAttachments();
    try {
      for (PDFField f in doc.getForm().getFields()) {
        f.getName();
      }
    } on PDFLibError {
      // a broken form is a typed error, fine
    }
    Uint8List again = await doc.save();
    // what we write must load again
    (await PDFDocument.load(again)).dispose();
  } on PDFLibError {
    // a typed error on a broken file is fine
  } finally {
    doc.dispose();
  }
}

void main() {
  group('life of a document', () {
    test('every call after dispose throws StateError', () async {
      PDFDocument doc = await PDFDocument.create();
      PDFPage page = doc.addPage();
      PDFFont font = await doc.embedFont(StandardFonts.helvetica);
      doc.dispose();
      expect(() => doc.getPageCount(), throwsStateError);
      expect(() => doc.addPage(), throwsStateError);
      expect(() => doc.save(), throwsStateError);
      expect(() => doc.getTitle(), throwsStateError);
      expect(() => doc.getForm(), throwsStateError);
      expect(() => page.drawText('x', font: font), throwsStateError);
      expect(() => page.getSize(), throwsStateError);
      doc.dispose(); // twice is fine
    });

    test('saves at the same time give the same file', () async {
      PDFDocument doc = await PDFDocument.create(updateMetadata: false);
      // over 1 MiB, so save runs on a native thread
      Uint8List noise = Uint8List.fromList(
        List<int>.generate(1 << 21, (int i) => (i * 7919) & 0xff),
      );
      await doc.attach(noise, 'noise.bin');
      for (int i = 0; i < 20; i++) {
        doc.addPage().drawText('page $i', x: 50, y: 700);
      }
      List<Uint8List> out = await Future.wait(
        List<Future<Uint8List>>.generate(5, (_) => doc.save()),
      );
      for (Uint8List o in out) {
        expect(o, out.first);
      }
      PDFDocument back = await PDFDocument.load(out.first);
      expect(back.getPageCount(), 20);
      expect(back.getAttachments().single.data, noise);
    });

    test('save keeps the document as it was at the call', () async {
      PDFDocument doc = await PDFDocument.create();
      doc.addPage();
      Future<Uint8List> pending = doc.save();
      doc.addPage();
      doc.addPage();
      expect((await PDFDocument.load(await pending)).getPageCount(), 1);
      expect(doc.getPageCount(), 3);
    });

    test('disposing a source after copy and embed is safe', () async {
      PDFDocument src = await PDFDocument.load(await _richPdf());
      PDFDocument out = await PDFDocument.create();
      List<PDFPage> copied = await out.copyPages(src, <int>[0]);
      List<PDFEmbeddedPage> embedded = await out.embedPages(src.getPages());
      src.dispose();
      out.addPage(copied.first);
      out.addPage().drawPage(
        embedded.first,
        x: 0,
        y: 0,
        xScale: 0.5,
        yScale: 0.5,
      );
      PDFDocument back = await PDFDocument.load(await out.save());
      expect(back.getPageCount(), 2);
    });

    test('many documents one after another', () async {
      Stopwatch sw = Stopwatch()..start();
      for (int i = 0; i < 300; i++) {
        PDFDocument d = await PDFDocument.create();
        d.addPage().drawText('$i', x: 10, y: 10);
        await d.save();
        d.dispose();
      }
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('isolates use the library at the same time', () async {
      Uint8List thai = _font('noto-sans-thai.ttf');
      Uint8List latin = _font('noto-sans-test.ttf');
      List<int> counts = await Future.wait(
        List<Future<int>>.generate(4, (int n) {
          return Isolate.run(() async {
            int pages = 0;
            for (int i = 0; i < 10; i++) {
              PDFDocument d = await PDFDocument.create();
              // the same font bytes in every isolate: the shared font cache
              PDFFont f = await d.embedFont(
                n.isEven ? thai : latin,
                subset: true,
              );
              d.addPage().drawText(
                n.isEven ? 'ทดสอบ $i' : 'Test $i',
                x: 10,
                y: 10,
                font: f,
              );
              PDFDocument back = await PDFDocument.load(await d.save());
              pages += back.getPageCount();
              back.dispose();
              d.dispose();
            }
            return pages;
          });
        }),
      );
      expect(counts, <int>[10, 10, 10, 10]);
    });
  });

  group('damaged files', () {
    test('a cut file loads or gives a typed error', () async {
      Uint8List full = await _richPdf();
      // every cut point in steps, and every byte near the end (the xref)
      Set<int> cuts = <int>{
        for (int i = 0; i < full.length; i += max(1, full.length ~/ 300)) i,
        for (int i = max(0, full.length - 400); i < full.length; i++) i,
      };
      for (int cut in cuts) {
        await _loadOrTypedError(Uint8List.sublistView(full, 0, cut));
      }
    });

    test('a file with changed bytes loads or gives a typed error', () async {
      Uint8List full = await _richPdf();
      Random r = Random(42);
      for (int round = 0; round < 400; round++) {
        Uint8List b = Uint8List.fromList(full);
        int flips = 1 + r.nextInt(8);
        for (int i = 0; i < flips; i++) {
          b[r.nextInt(b.length)] = r.nextInt(256);
        }
        await _loadOrTypedError(b);
      }
    });

    test('a damaged font, PNG or JPEG gives a typed error', () async {
      List<(String, Future<Object> Function(PDFDocument, Uint8List))> kinds =
          <(String, Future<Object> Function(PDFDocument, Uint8List))>[
            (
              'fonts/noto-sans-test.ttf',
              (PDFDocument d, Uint8List b) => d.embedFont(b, subset: true),
            ),
            (
              'rgba-interlaced.png',
              (PDFDocument d, Uint8List b) => d.embedPng(b),
            ),
            ('cmyk.jpg', (PDFDocument d, Uint8List b) => d.embedJpg(b)),
          ];
      Random r = Random(7);
      for ((String, Future<Object> Function(PDFDocument, Uint8List)) k
          in kinds) {
        Uint8List full = File('test/fixtures/${k.$1}').readAsBytesSync();
        for (int round = 0; round < 60; round++) {
          Uint8List b = Uint8List.fromList(full);
          if (round.isEven) {
            b = Uint8List.sublistView(b, 0, r.nextInt(b.length));
          } else {
            for (int i = 0; i < 4; i++) {
              b[r.nextInt(b.length)] = r.nextInt(256);
            }
          }
          PDFDocument d = await PDFDocument.create();
          try {
            Object made = await k.$2(d, b);
            PDFPage p = d.addPage();
            if (made is PDFFont) {
              p.drawText('Hello น้ำ', font: made, x: 5, y: 5);
            }
            if (made is PDFImage) {
              p.drawImage(made, x: 5, y: 5);
            }
            await d.save();
          } on PDFLibError {
            // fine
          } finally {
            d.dispose();
          }
        }
      }
    });
  });

  test('empty and blank text with a custom font and maxWidth', () async {
    // found by fuzzing: empty text made a panic, and the panic left the
    // document broken for every later call
    PDFDocument doc = await PDFDocument.create();
    PDFFont f = await doc.embedFont(_font('noto-sans-test.ttf'), subset: true);
    PDFFont thai = await doc.embedFont(_font('noto-sans-thai.ttf'));
    for (String t in <String>['', '\n', ' ', '\n\n', '\r\n ', '​']) {
      for (PDFFont font in <PDFFont>[f, thai]) {
        PDFPage p = doc.addPage();
        p.drawText(t, font: font, maxWidth: 100);
        p.drawText(t, font: font, maxWidth: 100, wordBreaks: <String>['']);
        p.drawText(t, font: font);
        expect(
          font.widthOfTextAtSize(t.replaceAll(RegExp(r'[\r\n]'), ''), 12),
          greaterThanOrEqualTo(0),
        );
      }
    }
    PDFTextField field = doc.getForm().createTextField('empty');
    field.addToPage(doc.addPage(), font: thai);
    field.setText('');
    field.enableMultiline();
    expect((await PDFDocument.load(await doc.save())).getPageCount(), 13);
  });

  group('big input', () {
    test('long wrapped text is fast', () async {
      PDFDocument doc = await PDFDocument.create();
      PDFFont thai = await doc.embedFont(
        _font('noto-sans-thai.ttf'),
        subset: true,
      );
      String latin = List<String>.filled(20000, 'lorem ipsum').join(' ');
      String thaiText = List<String>.filled(5000, 'ภาษาไทยน้ำค่ำ').join();
      Stopwatch sw = Stopwatch()..start();
      doc.addPage().drawText(latin, maxWidth: 400, size: 8, x: 10, y: 800);
      doc.addPage().drawText(
        thaiText,
        maxWidth: 400,
        wordBreaks: <String>[''],
        font: thai,
        size: 8,
        x: 10,
        y: 800,
      );
      await doc.save();
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a long SVG path is fast', () async {
      PDFDocument doc = await PDFDocument.create();
      StringBuffer path = StringBuffer('M 0 0');
      for (int i = 0; i < 50000; i++) {
        path.write(' L ${i % 500} ${(i * 7) % 700}');
      }
      Stopwatch sw = Stopwatch()..start();
      doc.addPage().drawSvgPath(path.toString());
      await doc.save();
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });

  test('one template, many outputs', () async {
    // the pdfme shape: load a template once, embed its page into many files
    PDFDocument template = await PDFDocument.load(await _richPdf());
    Uint8List latin = _font('noto-sans-test.ttf');
    Stopwatch sw = Stopwatch()..start();
    for (int i = 0; i < 50; i++) {
      PDFDocument out = await PDFDocument.create();
      PDFEmbeddedPage base = (await out.embedPages(template.getPages())).first;
      PDFFont f = await out.embedFont(latin, subset: true);
      PDFPage p = out.addPage(<double>[base.width, base.height]);
      p.drawPage(base);
      f.widthOfTextAtSize('Invoice $i', 12);
      p.drawText('Invoice $i', x: 20, y: 20, font: f, size: 12);
      PDFDocument back = await PDFDocument.load(await out.save());
      expect(back.getPageCount(), 1);
      back.dispose();
      out.dispose();
    }
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    // the template is not changed by being used
    expect(template.getPageCount(), 1);
    expect(template.getTitle(), 'rich');
  });

  group('same as pdf-lib', () {
    // each line: pdf-lib 1.17.1 does the same (checked in node)
    test('plain call edge cases', () async {
      PDFDocument d = await PDFDocument.create();
      PDFPage page = d.addPage();
      expect(() => page.setRotation(degrees(45)), throwsA(isA<PDFLibError>()));
      page.setRotation(degrees(450));
      expect(page.getRotation().angle, 450);
      expect(() => rgb(2, 0, 0), throwsRangeError);
      page.drawText('');
      page.drawText('\n\r\n\n');
      page.drawText('x', size: 0);
      page.drawText('hello world foo', maxWidth: 0);
      page.drawText('hello', maxWidth: 0, wordBreaks: <String>['']);
      page.drawSvgPath('');
      expect(() => page.drawText('hi 😀'), throwsA(isA<PDFLibError>()));
      expect(d.addPage(<double>[0, 0]).getSize().width, 0);
      PDFFont helv = await d.embedFont(StandardFonts.helvetica);
      expect(helv.widthOfTextAtSize('', 12), 0);
      expect(() => d.getPage(99), throwsRangeError);
      expect(() => d.insertPage(-1), throwsRangeError);
      // pdf-lib fails with a TypeError here; a RangeError is clearer
      PDFDocument s = await PDFDocument.create();
      s.addPage();
      expect(() => d.copyPages(s, <int>[5]), throwsRangeError);
      d.setTitle('😀 ทดสอบ');
      expect(d.getTitle(), '😀 ทดสอบ');
    });

    test('form edge cases', () async {
      PDFDocument d = await PDFDocument.create();
      PDFForm f = d.getForm();
      f.createTextField('a.b');
      expect(
        () => f.createTextField('a'),
        throwsA(isA<FieldAlreadyExistsError>()),
      );
      expect(() => f.createTextField(''), throwsA(isA<PDFLibError>()));
      expect(() => f.createTextField('x..y'), throwsA(isA<PDFLibError>()));
      expect(() => f.getTextField('zz'), throwsA(isA<NoSuchFieldError>()));
      f.createCheckBox('c');
      expect(
        () => f.getTextField('c'),
        throwsA(isA<UnexpectedFieldTypeError>()),
      );
      PDFTextField t = f.createTextField('t')..setMaxLength(2);
      expect(() => t.setText('abc'), throwsA(isA<ExceededMaxLengthError>()));
      PDFTextField u = f.createTextField('u')..setText('abc');
      expect(() => u.setMaxLength(2), throwsA(isA<InvalidMaxLengthError>()));
      PDFRadioGroup r = f.createRadioGroup('r')
        ..addOptionToPage('a', d.addPage());
      expect(() => r.select('zz'), throwsA(isA<PDFLibError>()));
      PDFDropdown dd = f.createDropdown('dd')..addOptions(<String>['a']);
      dd.select('zz'); // not an option: a custom value, like pdf-lib
      expect(dd.getSelected(), <String>['zz']);
      f.flatten();
      f.flatten();
      expect(f.getFields(), isEmpty);
    });

    test('bad input files', () async {
      expect(PDFDocument.load(Uint8List(0)), throwsA(isA<PDFParsingError>()));
      // pdf-lib fails with a TypeError here
      expect(
        PDFDocument.load(Uint8List.fromList('%PDF-1.7\n'.codeUnits)),
        throwsA(isA<PDFParsingError>()),
      );
      PDFDocument d = await PDFDocument.create();
      Uint8List junk = Uint8List.fromList(<int>[1, 2, 3]);
      expect(d.embedFont(junk), throwsA(isA<PDFLibError>()));
      expect(d.embedPng(junk), throwsA(isA<PDFLibError>()));
      expect(d.embedJpg(junk), throwsA(isA<PDFLibError>()));
    });
  });
}
