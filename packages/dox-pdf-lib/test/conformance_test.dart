import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';
import 'package:test/test.dart';

import 'icc_support.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

/// A 132 byte ICC header, enough for the header check.
Uint8List _header({
  String space = 'RGB ',
  String cls = 'mntr',
  String magic = 'acsp',
  int? size,
  int length = 132,
}) {
  Uint8List b = Uint8List(length);
  ByteData.sublistView(b).setUint32(0, size ?? length);
  b[8] = 2;
  b.setAll(12, ascii.encode(cls));
  b.setAll(16, ascii.encode(space));
  b.setAll(36, ascii.encode(magic));
  return b;
}

/// The file as text, to look for keys.
String _text(Uint8List pdf) => latin1.decode(pdf);

/// True when every start tag has its end tag (a small well-formed check).
bool _wellFormed(String xml) {
  List<String> stack = <String>[];
  for (RegExpMatch m in RegExp(
    r'<(/?)([A-Za-z_][\w:.-]*)[^>]*?(/?)>',
  ).allMatches(xml)) {
    if (m[3] == '/') continue;
    if (m[1] == '/') {
      if (stack.isEmpty || stack.removeLast() != m[2]) return false;
    } else {
      stack.add(m[2]!);
    }
  }
  return stack.isEmpty;
}

/// A document that meets [standard], as far as its content goes.
Future<PDFDocument> _goodDoc(PDFStandard standard) async {
  bool x = standard.isPDFX;
  PDFDocument doc = await PDFDocument.create();
  doc.setTitle('Report <2026> & "more"');
  doc.setAuthor('Dox');
  doc.setSubject('A test');
  doc.setKeywords(<String>['pdf', 'archive']);
  doc.setConformance(
    standard,
    iccProfile: testProfile(x ? 'cmyk.icc' : 'srgb.icc'),
    outputConditionIdentifier: x ? 'Custom CMYK' : 'sRGB IEC61966-2.1',
    outputCondition: x ? 'Test print' : null,
    registryName: x ? 'http://www.color.org' : null,
  );
  PDFFont font = await doc.embedFont(
    _fixture('fonts/noto-sans-test.ttf'),
    subset: true,
  );
  PDFPage page = doc.addPage(<double>[300, 200]);
  if (x) page.setTrimBox(10, 10, 280, 180);
  Color ink = x ? cmyk(0, 0, 0, 1) : rgb(0.1, 0.2, 0.6);
  page.drawText('Hello archive', x: 20, y: 150, font: font, color: ink);
  page.drawRectangle(x: 20, y: 20, width: 50, height: 30, color: ink);
  PDFImage img = await doc.embedJpg(_fixture(x ? 'cmyk.jpg' : 'rgb.jpg'));
  page.drawImage(img, x: 100, y: 20, width: 40, height: 40);
  if (!x) {
    // form fields: save writes their appearances; PDF/A keeps only /N
    PDFForm form = doc.getForm();
    PDFTextField name = form.createTextField('name')..setText('Ada');
    name.addToPage(page, x: 160, y: 120, width: 100, height: 20, font: font);
    form.createCheckBox('ok')
      ..check()
      ..addToPage(page, x: 160, y: 90, width: 15, height: 15);
    // else save draws them with Helvetica, which is not embedded
    form.updateFieldAppearances(font);
  }
  if (standard == PDFStandard.pdfA3b || standard == PDFStandard.pdfA3u) {
    await doc.attach(
      utf8.encode('a,b\n1,2\n'),
      'data.csv',
      mimeType: 'text/csv',
      description: 'The data',
      afRelationship: AFRelationship.data,
      creationDate: DateTime.utc(2026),
      modificationDate: DateTime.utc(2026),
    );
  }
  return doc;
}

/// veraPDF, when it is installed (`verapdf` on the PATH, or `VERAPDF`).
String? _veraPdf() {
  String? env = Platform.environment['VERAPDF'];
  if (env != null && env.isNotEmpty) return env;
  ProcessResult r = Process.runSync('sh', <String>['-c', 'command -v verapdf']);
  String path = (r.stdout as String).trim();
  return r.exitCode == 0 && path.isNotEmpty ? path : null;
}

void main() {
  late bool online;
  setUpAll(() async => online = await fetchTestProfiles());

  group('ICC header', () {
    test('a valid header is taken', () async {
      PDFDocument doc = await PDFDocument.create();
      doc.addOutputIntent(
        subtype: OutputIntentSubtype.pdfA,
        iccProfile: _header(),
        outputConditionIdentifier: 'x',
      );
    });

    for ((String, Uint8List, String) c in <(String, Uint8List, String)>[
      ('too short', _header(length: 100), 'too short'),
      ('no acsp', _header(magic: 'xxxx'), "no 'acsp'"),
      ('cut off', _header(size: 9000), 'cut off'),
      ('Lab space', _header(space: 'Lab '), "color space 'Lab'"),
      ('input class', _header(cls: 'scnr'), 'device class'),
    ]) {
      test('rejects: ${c.$1}', () async {
        PDFDocument doc = await PDFDocument.create();
        expect(
          () => doc.addOutputIntent(
            subtype: OutputIntentSubtype.pdfA,
            iccProfile: c.$2,
            outputConditionIdentifier: 'x',
          ),
          throwsA(
            isA<PDFLibError>().having(
              (PDFLibError e) => e.message,
              'message',
              contains(c.$3),
            ),
          ),
        );
      });
    }

    test('PDF/X needs a printer profile, PDF/X-1a a CMYK one', () async {
      PDFDocument doc = await PDFDocument.create();
      expect(
        () => doc.addOutputIntent(
          subtype: OutputIntentSubtype.pdfX,
          iccProfile: _header(),
          outputConditionIdentifier: 'x',
        ),
        throwsA(isA<PDFLibError>()),
      );
      expect(
        () => doc.setConformance(
          PDFStandard.pdfX1a,
          iccProfile: _header(cls: 'prtr'),
          outputConditionIdentifier: 'x',
        ),
        throwsA(isA<PDFLibError>()),
      );
      expect(
        () => doc.setConformance(
          PDFStandard.pdfA1b,
          iccProfile: _header(),
          outputConditionIdentifier: '',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('metadata', () {
    test('custom keys', () async {
      PDFDocument doc = await PDFDocument.create();
      doc.setCustomMetadata('Client', 'ACME 世界');
      doc.setCustomMetadata('JobId', '42');
      expect(doc.getCustomMetadata('Client'), 'ACME 世界');
      expect(doc.getCustomMetadataKeys(), <String>['Client', 'JobId']);
      doc.removeCustomMetadata('JobId');
      expect(doc.getCustomMetadata('JobId'), isNull);
      expect(() => doc.setCustomMetadata('Title', 'x'), throwsArgumentError);
      expect(() => doc.setCustomMetadata('a b', 'x'), throwsArgumentError);
      expect(() => doc.setCustomMetadata('a/b', 'x'), throwsArgumentError);
      PDFDocument again = await PDFDocument.load(await doc.save());
      expect(again.getCustomMetadata('Client'), 'ACME 世界');
    });

    test('trapped', () async {
      PDFDocument doc = await PDFDocument.create();
      expect(doc.getTrapped(), isNull);
      doc.setTrapped(Trapped.yes);
      expect(doc.getTrapped(), Trapped.yes);
      expect(_text(await doc.save()), matches(RegExp(r'/Trapped ?/True')));
      doc.setTrapped(null);
      expect(doc.getTrapped(), isNull);
    });

    test('XMP from the info is well formed and in sync', () async {
      PDFDocument doc = await PDFDocument.create();
      doc.setTitle('A < B & "C"');
      doc.setAuthor('Me');
      doc.setCreationDate(DateTime.utc(2026, 1, 2, 3, 4, 5));
      String xmp = doc.createXmpMetadata(standard: PDFStandard.pdfA2u);
      expect(_wellFormed(xmp), isTrue, reason: xmp);
      for (String ns in <String>[
        'xmlns:x="adobe:ns:meta/"',
        'xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"',
        'xmlns:dc="http://purl.org/dc/elements/1.1/"',
        'xmlns:xmp="http://ns.adobe.com/xap/1.0/"',
        'xmlns:pdf="http://ns.adobe.com/pdf/1.3/"',
        'xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/"',
      ]) {
        expect(xmp, contains(ns));
      }
      expect(xmp, contains('A &lt; B &amp; &quot;C&quot;'));
      expect(xmp, contains('<rdf:li>Me</rdf:li>'));
      expect(
        xmp,
        contains('<xmp:CreateDate>2026-01-02T03:04:05Z</xmp:CreateDate>'),
      );
      expect(xmp, contains('<pdfaid:part>2</pdfaid:part>'));
      expect(xmp, contains('<pdfaid:conformance>U</pdfaid:conformance>'));
      String x4 = doc.createXmpMetadata(standard: PDFStandard.pdfX4);
      expect(_wellFormed(x4), isTrue);
      expect(x4, contains('xmlns:pdfxid="http://www.npes.org/pdfx/ns/id/"'));
      expect(x4, contains('<xmpMM:RenditionClass>'));
      expect(doc.getXmpMetadata(), isNull);
    });

    test('own XMP is kept by save', () async {
      PDFDocument doc = await PDFDocument.create();
      String own = doc.createXmpMetadata().replaceFirst(
        '</rdf:RDF>',
        '<rdf:Description rdf:about="" xmlns:my="urn:my"><my:a>1</my:a>'
            '</rdf:Description></rdf:RDF>',
      );
      doc.setXmpMetadata(own);
      expect(doc.getXmpMetadata(), own);
      PDFDocument again = await PDFDocument.load(await doc.save());
      expect(again.getXmpMetadata(), own);
      expect(() => doc.setXmpMetadata('hello'), throwsA(isA<PDFLibError>()));
    });
  });

  group('setConformance writes the required items', () {
    for (PDFStandard s in PDFStandard.values) {
      test(s.label, () async {
        if (!online) {
          return markTestSkipped('the ICC profiles could not be loaded');
        }
        PDFDocument doc = await _goodDoc(s);
        expect(doc.checkConformance(s), isEmpty);
        // without object streams, so the keys can be read as text
        Uint8List pdf = await doc.save(useObjectStreams: false);
        String t = _text(pdf);
        String version = switch (s) {
          PDFStandard.pdfX1a ||
          PDFStandard.pdfX3 ||
          PDFStandard.pdfA1b => '1.4',
          PDFStandard.pdfX4 => '1.6',
          _ => '1.7',
        };
        expect(t, startsWith('%PDF-$version\n%'));
        expect(pdf.sublist(10, 14).every((int b) => b > 127), isTrue);
        if (version == '1.4') {
          // PDF 1.4 has no object streams, so save writes none
          String plain = _text(await doc.save());
          expect(plain, isNot(contains('/ObjStm')));
          expect(plain, isNot(contains('/XRef')));
        }
        expect(t, matches(RegExp(r'/ID ?\[<[0-9A-F]{32}> ?<[0-9A-F]{32}>\]')));
        expect(t, contains('/S/${s.isPDFX ? 'GTS_PDFX' : 'GTS_PDFA1'}'));
        expect(t, contains('/DestOutputProfile'));
        expect(t, isNot(contains('/Encrypt')));
        PDFDocument again = await PDFDocument.load(pdf);
        String xmp = again.getXmpMetadata()!;
        expect(_wellFormed(xmp), isTrue);
        expect(xmp, contains('<dc:title>'));
        // the metadata stream is plain text in the file
        expect(t, contains('<x:xmpmeta'));
        if (s.isPDFX) {
          expect(again.getTrapped(), Trapped.no);
          expect(t, contains('/GTS_PDFXVersion'));
          expect(t, contains('/N 4'));
          expect(t, contains('/TrimBox'));
          if (s == PDFStandard.pdfX1a) {
            expect(t, contains('/GTS_PDFXConformance(PDF/X-1a:2003)'));
          }
          if (s == PDFStandard.pdfX4) {
            expect(xmp, contains('PDF/X-4'));
            expect(xmp, contains('<xmpMM:VersionID>'));
          }
        } else {
          expect(t, contains('/N 3'));
          expect(xmp, contains('<pdfaid:part>'));
        }
        // fonts are embedded, no transparency where it is not allowed
        expect(t, contains('/FontFile2'));
        if (!s.isPDFX || s == PDFStandard.pdfX1a) {
          expect(t, isNot(contains('/SMask')));
          expect(t, isNot(contains('/ca')));
        }
        expect(again.checkConformance(s), isEmpty);
      });
    }

    test('/ID keeps its first part when a file is saved again', () async {
      if (!online) {
        return markTestSkipped('the ICC profiles could not be loaded');
      }
      PDFDocument doc = await _goodDoc(PDFStandard.pdfA2b);
      RegExp id = RegExp(r'/ID ?\[<([0-9A-F]+)> ?<([0-9A-F]+)>\]');
      Uint8List first = await doc.save(useObjectStreams: false);
      RegExpMatch a = id.firstMatch(_text(first))!;
      PDFDocument again = await PDFDocument.load(first);
      again.setConformance(
        PDFStandard.pdfA2b,
        iccProfile: testProfile('srgb.icc'),
        outputConditionIdentifier: 'sRGB',
      );
      RegExpMatch b = id.firstMatch(
        _text(await again.save(useObjectStreams: false)),
      )!;
      expect(b[1], a[1]);
      expect(b[2], isNot(a[2]));
    });

    test('default save is unchanged: no /ID, no XMP, version 1.7', () async {
      PDFDocument doc = await PDFDocument.create();
      doc.addPage();
      String t = _text(await doc.save());
      expect(t, startsWith('%PDF-1.7'));
      expect(t, isNot(contains('/ID')));
      expect(t, isNot(contains('/Metadata')));
      expect(t, isNot(contains('/OutputIntents')));
    });
  });

  group('checkConformance finds', () {
    Future<List<ConformanceIssue>> issues(
      PDFStandard s,
      Future<void> Function(PDFDocument doc, PDFPage page) change,
    ) async {
      PDFDocument doc = await _goodDoc(s);
      await change(doc, doc.getPage(0));
      return doc.checkConformance(s);
    }

    Matcher has(ConformanceIssueKind kind, [int? page]) => contains(
      isA<ConformanceIssue>()
          .having((ConformanceIssue i) => i.kind, 'kind', kind)
          .having((ConformanceIssue i) => i.pageIndex, 'pageIndex', page),
    );

    test('a standard font', () async {
      if (!online) {
        return markTestSkipped('no ICC profiles');
      }
      List<ConformanceIssue> list = await issues(PDFStandard.pdfA2b, (
        PDFDocument doc,
        PDFPage page,
      ) async {
        PDFFont helv = await doc.embedFont('Helvetica');
        page.drawText('x', font: helv, color: rgb(0, 0, 0));
      });
      expect(list, has(ConformanceIssueKind.fontNotEmbedded, 0));
      expect(list.first.message, contains('Helvetica'));
    });

    test('opacity, but only where it is not allowed', () async {
      if (!online) {
        return markTestSkipped('no ICC profiles');
      }
      Future<void> fade(PDFDocument doc, PDFPage page) async =>
          page.drawRectangle(
            width: 5,
            height: 5,
            color: cmyk(0, 0, 0, 1),
            opacity: 0.5,
          );
      expect(
        await issues(PDFStandard.pdfX1a, fade),
        has(ConformanceIssueKind.transparency, 0),
      );
      expect(await issues(PDFStandard.pdfX4, fade), isEmpty);
    });

    test('a PNG with alpha in PDF/A-1', () async {
      if (!online) {
        return markTestSkipped('no ICC profiles');
      }
      List<ConformanceIssue> list = await issues(PDFStandard.pdfA1b, (
        PDFDocument doc,
        PDFPage page,
      ) async {
        page.drawImage(await doc.embedPng(_fixture('rgba-interlaced.png')));
      });
      expect(list, has(ConformanceIssueKind.transparency, 0));
    });

    test('RGB colors in PDF/X-1a, CMYK with an RGB intent', () async {
      if (!online) {
        return markTestSkipped('no ICC profiles');
      }
      expect(
        await issues(
          PDFStandard.pdfX1a,
          (PDFDocument doc, PDFPage page) async =>
              page.drawText('x', color: rgb(1, 0, 0)),
        ),
        has(ConformanceIssueKind.color, 0),
      );
      expect(
        await issues(
          PDFStandard.pdfA2b,
          (PDFDocument doc, PDFPage page) async =>
              page.drawRectangle(width: 5, height: 5, color: cmyk(0, 1, 0, 0)),
        ),
        has(ConformanceIssueKind.color, 0),
      );
    });

    test('no TrimBox, an annotation inside it (PDF/X)', () async {
      if (!online) {
        return markTestSkipped('no ICC profiles');
      }
      List<ConformanceIssue> list = await issues(PDFStandard.pdfX4, (
        PDFDocument doc,
        PDFPage page,
      ) async {
        doc.addPage(<double>[100, 100]);
        PDFForm form = doc.getForm();
        form.createTextField('name').addToPage(page, x: 50, y: 50);
      });
      expect(list, has(ConformanceIssueKind.pageBox, 1));
      expect(list, has(ConformanceIssueKind.annotation, 0));
    });

    test('attachments by part', () async {
      if (!online) {
        return markTestSkipped('no ICC profiles');
      }
      Future<void> attach(PDFDocument doc, PDFPage page) =>
          doc.attach(Uint8List.fromList(<int>[1, 2, 3]), 'a.bin');
      expect(
        await issues(PDFStandard.pdfA1b, attach),
        has(ConformanceIssueKind.embeddedFile),
      );
      expect(
        await issues(PDFStandard.pdfA2b, attach),
        has(ConformanceIssueKind.embeddedFile),
      );
      List<ConformanceIssue> a3 = await issues(PDFStandard.pdfA3b, attach);
      expect(a3, has(ConformanceIssueKind.embeddedFile));
      expect(
        a3.map((ConformanceIssue i) => i.message).join(),
        contains('AFRelationship'),
      );
    });

    test('a document with no setConformance', () async {
      PDFDocument doc = await PDFDocument.create();
      PDFPage page = doc.addPage();
      page.drawText('Hello');
      List<ConformanceIssue> list = doc.checkConformance(PDFStandard.pdfX1a);
      for (ConformanceIssueKind k in <ConformanceIssueKind>[
        ConformanceIssueKind.fontNotEmbedded,
        ConformanceIssueKind.color,
        ConformanceIssueKind.pageBox,
        ConformanceIssueKind.fileId,
        ConformanceIssueKind.version,
        ConformanceIssueKind.outputIntent,
        ConformanceIssueKind.info,
      ]) {
        expect(list.map((ConformanceIssue i) => i.kind), contains(k));
      }
      expect(
        doc
            .checkConformance(PDFStandard.pdfA2b)
            .map((ConformanceIssue i) => i.kind),
        contains(ConformanceIssueKind.metadata),
      );
    });
  });

  group('veraPDF', () {
    String? vera = _veraPdf();
    bool required = Platform.environment['REQUIRE_VERAPDF'] == '1';
    for ((PDFStandard, String) c in <(PDFStandard, String)>[
      (PDFStandard.pdfA1b, '1b'),
      (PDFStandard.pdfA2b, '2b'),
      (PDFStandard.pdfA2u, '2u'),
      (PDFStandard.pdfA3b, '3b'),
      (PDFStandard.pdfA3u, '3u'),
    ]) {
      test(c.$1.label, () async {
        if (vera == null) {
          if (required) fail('veraPDF is not installed');
          markTestSkipped('veraPDF is not installed');
          return;
        }
        if (!online) {
          return markTestSkipped('no ICC profiles');
        }
        Directory dir = Directory.systemTemp.createTempSync('dox_pdfa_');
        try {
          for (bool streams in <bool>[true, false]) {
            PDFDocument doc = await _goodDoc(c.$1);
            File f = File('${dir.path}/a${c.$2}_$streams.pdf')
              ..writeAsBytesSync(await doc.save(useObjectStreams: streams));
            ProcessResult r = Process.runSync(vera, <String>[
              '--flavour',
              c.$2,
              '--format',
              'text',
              f.path,
            ]);
            expect(
              r.stdout as String,
              startsWith('PASS'),
              reason: '${r.stdout}\n${r.stderr}',
            );
          }
        } finally {
          dir.deleteSync(recursive: true);
        }
      });
    }
  });
}
