import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('encrypted with a user password', () async {
    Uint8List bytes = File('test/fixtures/encrypted-user-password.pdf')
        .readAsBytesSync();
    await expectLater(
      PDFDocument.load(bytes),
      throwsA(isA<EncryptedPDFError>()),
    );
    // lopdf can not read the objects without the password
    await expectLater(
      PDFDocument.load(bytes, ignoreEncryption: true),
      throwsA(isA<PDFParsingError>()),
    );
  });

  test('encrypted with an owner password only', () async {
    Uint8List bytes = File('test/fixtures/encrypted-owner-only.pdf')
        .readAsBytesSync();
    await expectLater(
      PDFDocument.load(bytes),
      throwsA(isA<EncryptedPDFError>()),
    );
    PDFDocument doc = await PDFDocument.load(
      bytes,
      ignoreEncryption: true,
      updateMetadata: false,
    );
    expect(doc.getPageCount(), 2);
    // the empty user password opens it, so the info can be read
    expect(doc.getAuthor(), 'Ann (pdf-lib)');
  });

  // a page tree with two levels; MediaBox and Rotate come from the parent
  Uint8List nested() => buildPdf(<String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 3 '
        '/MediaBox [0 0 500 500] /Rotate 90 >>',
    '<< /Type /Pages /Parent 2 0 R /Kids [5 0 R 6 0 R] /Count 2 '
        '/MediaBox [0 0 300 300] >>',
    '<< /Type /Page /Parent 2 0 R >>',
    '<< /Type /Page /Parent 3 0 R /Rotate 0 >>',
    '<< /Type /Page /Parent 3 0 R /MediaBox [0 0 100.5 200] >>',
  ]);

  test('inherited values in a nested page tree', () async {
    PDFDocument doc = await PDFDocument.load(nested());
    expect(
      <Object>[
        for (PDFPage p in doc.getPages())
          <Object>[p.getWidth(), p.getRotation().angle],
      ],
      <Object>[
        <Object>[300.0, 0.0],
        <Object>[100.5, 90.0],
        <Object>[500.0, 90.0],
      ],
    );
  });

  test('insert and remove in a nested page tree', () async {
    PDFDocument doc = await PDFDocument.load(nested());
    doc.insertPage(1, <double>[1, 1]);
    doc.removePage(0);
    doc.removePage(1); // empties the inner node, which is removed too
    PDFDocument again = await PDFDocument.load(await doc.save());
    expect(
      <double>[for (PDFPage p in again.getPages()) p.getWidth()],
      <double>[1, 500],
    );
  });

  test('copy from a nested tree keeps inherited values', () async {
    PDFDocument src = await PDFDocument.load(nested());
    PDFDocument dst = await PDFDocument.create();
    for (PDFPage p in await dst.copyPages(src, src.getPageIndices())) {
      dst.addPage(p);
    }
    PDFDocument again = await PDFDocument.load(await dst.save());
    expect(again.getPage(2).getWidth(), 500);
    expect(again.getPage(2).getRotation().angle, 90);
    expect(again.getPage(0).getRotation().angle, 0);
  });

  test('a page tree that lost all its pages is an error', () async {
    // the only kid points at an object that is not in the file
    await expectLater(
      PDFDocument.load(
        buildPdf(<String>[
          '<< /Type /Catalog /Pages 2 0 R >>',
          '<< /Type /Pages /Kids [9 0 R] /Count 1 >>',
        ]),
      ),
      throwsA(isA<PDFParsingError>()),
    );
    // an empty tree is fine
    PDFDocument empty = await PDFDocument.load(
      buildPdf(<String>[
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [] /Count 0 >>',
      ]),
    );
    expect(empty.getPageCount(), 0);
  });

  test('a loop in the page tree does not hang', () async {
    PDFDocument doc = await PDFDocument.load(
      buildPdf(<String>[
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [2 0 R 3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] >>',
      ]),
    );
    expect(doc.getPageCount(), 1);
  });

  test('a file with an incremental update', () async {
    Uint8List base = buildPdf(<String>[
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] >>',
    ]);
    String text = String.fromCharCodes(base);
    int prev = int.parse(
      RegExp(r'startxref\n(\d+)').firstMatch(text)!.group(1)!,
    );
    String update =
        '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 20 20] >>\n'
        'endobj\n';
    int offset = base.length;
    int xref = offset + update.length;
    String tail =
        '${update}xref\n3 1\n${offset.toString().padLeft(10, '0')} 00000 n \n'
        'trailer\n<< /Size 4 /Root 1 0 R /Prev $prev >>\n'
        'startxref\n$xref\n%%EOF\n';
    PDFDocument doc = await PDFDocument.load(
      Uint8List.fromList(<int>[...base, ...tail.codeUnits]),
    );
    expect(doc.getPage(0).getWidth(), 20);
  });

  test('a big file loads and saves off the event loop', () async {
    // about 12 MB: 200 pages with a 60 KB content stream each
    String content = 'BT /F1 12 Tf 10 10 Td (x) Tj ET\n' * 1900;
    List<String> objects = <String>[
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [${<String>[for (int i = 0; i < 200; i++) '${3 + i * 2} 0 R'].join(' ')}] /Count 200 >>',
    ];
    for (int i = 0; i < 200; i++) {
      objects
        ..add(
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
          '/Contents ${4 + i * 2} 0 R >>',
        )
        ..add('<< /Length ${content.length} >>\nstream\n${content}endstream');
    }
    Uint8List big = buildPdf(objects);
    expect(big.length, greaterThan(10 << 20));

    int ticks = 0;
    Timer timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (Timer _) => ticks++,
    );
    Stopwatch watch = Stopwatch()..start();
    PDFDocument doc = await PDFDocument.load(big);
    int loadMs = watch.elapsedMilliseconds;
    int loadTicks = ticks;
    watch.reset();
    Uint8List saved = await doc.save();
    int saveMs = watch.elapsedMilliseconds;
    timer.cancel();
    printOnFailure('load $loadMs ms ($loadTicks ticks), save $saveMs ms');
    expect(doc.getPageCount(), 200);
    expect(saved.length, greaterThan(10 << 20));
    // the timer ran while Rust worked, so the event loop was free
    expect(ticks, greaterThan(0));
  });
}
