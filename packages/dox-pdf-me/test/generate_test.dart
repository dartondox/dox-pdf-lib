import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';
import 'package:dox_pdf_me/src/schema.dart';
import 'package:dox_pdf_me/src/schemas/date_plugin.dart';
import 'package:dox_pdf_me/src/expression.dart';
import 'package:dox_pdf_me/src/schemas/date_format.dart';
import 'package:dox_pdf_me/src/schemas/image_orientation.dart';
import 'package:dox_pdf_me/src/schemas/image_plugin.dart';
import 'package:test/test.dart';

import 'support.dart';

Map<String, dynamic> blank([List<Map<String, dynamic>>? staticSchema]) =>
    <String, dynamic>{
      'width': 210,
      'height': 297,
      'padding': <int>[10, 10, 10, 10],
      'staticSchema': ?staticSchema,
    };

Map<String, dynamic> schema(
  String name,
  String type, [
  Map<String, dynamic> props = const <String, dynamic>{},
]) => <String, dynamic>{
  'name': name,
  'type': type,
  'position': <String, num>{'x': 10, 'y': 10},
  'width': 50,
  'height': 10,
  ...props,
};

Map<String, dynamic> template(List<List<Map<String, dynamic>>> pages) =>
    <String, dynamic>{'basePdf': blank(), 'schemas': pages};

Matcher throwsMessage(String text) => throwsA(
  isA<ArgumentError>().having(
    (ArgumentError e) => '${e.message}',
    'message',
    contains(text),
  ),
);

void main() {
  group('generate', () {
    test('one page per schema page and input, A4 size', () async {
      Uint8List bytes = await generateJson(
        template: template(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[schema('a', 'text')],
          <Map<String, dynamic>>[],
        ]),
        inputs: <Map<String, dynamic>>[
          <String, dynamic>{'a': 'one'},
          <String, dynamic>{'a': 'two'},
          <String, dynamic>{},
        ],
      );
      PDFDocument doc = await PDFDocument.load(bytes);
      expect(doc.getPageCount(), 6);
      expect(doc.getPage(0).getWidth(), closeTo(595.266, 1e-6));
      expect(doc.getPage(0).getHeight(), closeTo(841.8762, 1e-6));
      doc.dispose();
    });

    test('pdfme metadata defaults and options', () async {
      Uint8List bytes = await generateJson(
        template: template(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[],
        ]),
        inputs: <Map<String, dynamic>>[<String, dynamic>{}],
        options: <String, dynamic>{'title': 'Invoice', 'lang': 'ja'},
      );
      PDFDocument doc = await PDFDocument.load(bytes, updateMetadata: false);
      expect(doc.getTitle(), 'Invoice');
      expect(doc.getAuthor(), 'pdfme (https://pdfme.com/)');
      expect(doc.getProducer(), 'pdfme (https://pdfme.com/)');
      expect(doc.getLanguage(), 'ja');
      doc.dispose();
    });

    test('without plugins only text works, like pdfme', () {
      expect(
        generateJson(
          template: template(<List<Map<String, dynamic>>>[
            <Map<String, dynamic>>[schema('a', 'line')],
          ]),
          inputs: <Map<String, dynamic>>[<String, dynamic>{}],
        ),
        throwsMessage('Plugin or renderer for type line not found'),
      );
    });

    test('builtInPlugins has every type', () {
      expect(
        builtInPlugins.values.map((SchemaPlugin<Schema> p) => p.type).toSet(),
        <String>{
          'text',
          'image',
          'svg',
          'line',
          'rectangle',
          'ellipse',
          ...barcodeTypes,
          'date',
          'time',
          'dateTime',
          'checkbox',
          'radioGroup',
          'select',
          'multiVariableText',
          'signature',
          'circleMark',
          'table',
        },
      );
    });

    test('a custom plugin', () async {
      _Recorder recorder = _Recorder();
      await generateJson(
        template: template(<List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[schema('a', 'stamp'), schema('', 'stamp')],
        ]),
        inputs: <Map<String, dynamic>>[
          <String, dynamic>{'a': 42},
        ],
        plugins: <String, SchemaPlugin<Schema>>{'Stamp': recorder},
      );
      // a schema with no name is skipped; numbers become text
      expect(recorder.values, <String>['42']);
    });

    test('user plugins must cover every type', () {
      expect(
        generateJson(
          template: template(<List<Map<String, dynamic>>>[
            <Map<String, dynamic>>[schema('a', 'text'), schema('b', 'x')],
          ]),
          inputs: <Map<String, dynamic>>[<String, dynamic>{}],
          plugins: <String, SchemaPlugin<Schema>>{'Text': const TextPlugin()},
        ),
        throwsMessage('x of template.schemas is not found in plugins.'),
      );
    });

    test('required input', () {
      expect(
        generateJson(
          template: template(<List<Map<String, dynamic>>>[
            <Map<String, dynamic>>[
              schema('a', 'text', <String, dynamic>{'required': true}),
            ],
          ]),
          inputs: <Map<String, dynamic>>[
            <String, dynamic>{'a': ''},
          ],
        ),
        throwsMessage("input for 'a' is required to generate this PDF"),
      );
    });

    test('font checks', () {
      Future<Uint8List> run(Map<String, dynamic> font, String fontName) =>
          generateJson(
            template: template(<List<Map<String, dynamic>>>[
              <Map<String, dynamic>>[
                schema('a', 'text', <String, dynamic>{'fontName': fontName}),
              ],
            ]),
            inputs: <Map<String, dynamic>>[<String, dynamic>{}],
            options: <String, dynamic>{'font': font},
          );
      Uint8List roboto = FontStore.defaultFont.data;
      expect(
        run(<String, dynamic>{
          'A': <String, dynamic>{'data': roboto},
        }, 'A'),
        throwsMessage('fallback flag is not found in font'),
      );
      expect(
        run(<String, dynamic>{
          'A': <String, dynamic>{'data': roboto, 'fallback': true},
          'B': <String, dynamic>{'data': roboto, 'fallback': true},
        }, 'A'),
        throwsMessage('2 fallback flags found in font'),
      );
      expect(
        run(<String, dynamic>{
          'A': <String, dynamic>{'data': roboto, 'fallback': true},
        }, 'Nope'),
        throwsMessage('Nope of template.schemas is not found in font'),
      );
    });

    test('empty inputs throw', () {
      expect(
        generateJson(
          template: template(<List<Map<String, dynamic>>>[]),
          inputs: <Map<String, dynamic>>[],
        ),
        throwsMessage('inputs should not be empty'),
      );
    });

    test('static schemas and the legacy format', () async {
      _Recorder recorder = _Recorder();
      await generateJson(
        template: <String, dynamic>{
          'basePdf': blank(<Map<String, dynamic>>[
            schema('', 'stamp', <String, dynamic>{
              'readOnly': true,
              'content': '{currentPage}/{totalPages}',
            }),
          ]),
          'schemas': <Map<String, dynamic>>[
            <String, dynamic>{
              'x': <String, dynamic>{
                'type': 'stamp',
                'position': <String, num>{'x': 0, 'y': 0},
                'width': 10,
                'height': 10,
              },
            },
            <String, dynamic>{},
          ],
        },
        inputs: <Map<String, dynamic>>[
          <String, dynamic>{'x': 'value'},
        ],
        plugins: <String, SchemaPlugin<Schema>>{'Stamp': recorder},
      );
      expect(recorder.values, <String>['1/2', 'value', '2/2']);
    });
  });

  group('placeholders', () {
    PlaceholderResolver resolver = PlaceholderResolver(
      schemas: <RawSchema>[
        RawSchema(<String, dynamic>{
          'name': 'company',
          'type': 'text',
          'readOnly': true,
          'content': 'Dox',
        }),
      ],
      variables: <String, dynamic>{
        'name': 'Ann',
        'order': '{"id": 7, "total": "1.50"}',
        'amount': '12.50',
        'currentPage': 1,
        'totalPages': 3,
      },
    );

    test('names, paths and page numbers', () {
      expect(
        resolver.replace('{name} at {company}: {currentPage} of {totalPages}'),
        'Ann at Dox: 1 of 3',
      );
      expect(
        resolver.replace('Order {order.id} {order.total}'),
        'Order 7 1.50',
      );
      // JSON numbers like pdfme: "12.50" is the number 12.5
      expect(resolver.replace('{amount}'), '12.5');
      expect(resolver.replace('{order.missing}'), 'undefined');
    });

    test('unknown names and expressions stay as they are', () {
      expect(resolver.replace('{nope} {1 + 2} {'), '{nope} {1 + 2} {');
      expect(resolver.replace('no braces'), 'no braces');
    });

    test('date', () {
      expect(
        resolver.replace('{date}'),
        matches(RegExp(r'^\d{4}/\d{2}/\d{2}$')),
      );
    });
  });

  group('dates (date-fns tokens)', () {
    DateFormatter f = const DateFormatter();
    DateTime d = DateTime(2024, 5, 7, 18, 5, 9);

    test('tokens', () {
      expect(f.format(d, 'yyyy/MM/dd HH:mm:ss'), '2024/05/07 18:05:09');
      expect(f.format(d, 'MM/dd/yyyy hh:mm aa'), '05/07/2024 06:05 PM');
      expect(f.format(d, 'EEEE, MMMM d, yy'), 'Tuesday, May 7, 24');
      expect(f.format(d, 'EEE MMM'), 'Tue May');
      expect(f.format(d, "'at' h a"), 'at 6 PM');
      expect(f.format(d, "dd 'o''clock'"), "07 o'clock");
      // checked against date-fns 4.4.0 (en-US)
      expect(f.format(d, 'MMM do, yy'), 'May 7th, 24');
      expect(f.format(d, 'PPP'), 'May 7th, 2024');
      expect(f.format(d, 'PPPPpp'), 'Tuesday, May 7th, 2024 at 6:05:09 PM');
      expect(f.format(d, 'Pp'), '05/07/2024, 6:05 PM');
      expect(
        f.format(d, 'iiii eeeeee QQQQ wo Io'),
        'Tuesday Tu 2nd quarter 19th 19th',
      );
      expect(f.format(DateTime(2020, 12, 29), 'R-II Y-ww'), '2020-53 2021-01');
    });

    test('valid formats', () {
      expect(f.isValid('yyyy'), isTrue);
      expect(f.isValid(' '), isFalse);
      expect(f.isValid('undefined'), isFalse);
      expect(f.isValid('yyyy jj'), isFalse);
      expect(f.isValid('DD.MM.YYYY'), isFalse);
      // 7 S tokens (more than milliseconds) work in date-fns
      expect(f.isValid('ss.SSSSSSS'), isTrue);
      expect(
        f.format(DateTime(2024, 5, 7, 18, 5, 9, 123), 'ss.SSSSSSS'),
        '09.1230000',
      );
    });

    test('input values', () {
      DateInput input = const DateInput();
      expect(input.parse('2024/05/07', 'date'), DateTime(2024, 5, 7));
      expect(
        input.parse('2024/05/07 18:30', 'dateTime'),
        DateTime(2024, 5, 7, 18, 30),
      );
      expect(input.parse('09:05', 'time'), DateTime(2021, 1, 1, 9, 5));
      expect(
        input.parse('2024-05-07', 'date'),
        DateTime.utc(2024, 5, 7).toLocal(),
      );
      expect(() => input.parse('nope', 'date'), throwsRangeError);
    });

    test('default formats per locale', () {
      expect(
        const DateDrawer.date().formatValue('2024/05/07', null, 'en'),
        '05/07/2024',
      );
      expect(
        const DateDrawer.dateTime().formatValue('2024/05/07 18:30', '', 'de'),
        '07.05.2024 18:30',
      );
      expect(
        const DateDrawer.time().formatValue('18:30', 'bad jj', 'en'),
        '18:30',
      );
      expect(
        () => const DateDrawer.date().formatValue('2024/05/07', null, 'xx'),
        throwsArgumentError,
      );
    });
  });

  group('EXIF orientation', () {
    int read(String name) => ImageOrientation.read(
      File('test/fixtures/crosscheck/$name').readAsBytesSync(),
    );

    test('JPEG APP1 and PNG eXIf', () {
      expect(read('image.jpg'), 1);
      expect(read('image.png'), 1);
      expect(read('image-o3.jpg'), 3);
      expect(read('image-o6.jpg'), 6);
      expect(read('image-o8.jpg'), 8);
      expect(read('image-o6.png'), 6);
      expect(ImageOrientation.read(Uint8List.fromList(<int>[0xff, 0xd8])), 1);
    });

    test('matrices map the stored image to the shown image', () {
      // orientation 6 turns 90 degrees clockwise: the stored top left
      // (0, 1) is shown at the top right (1, 1)
      List<double> m = ImageOrientation.matrix(6);
      expect((m[0] * 0 + m[2] * 1 + m[4], m[1] * 0 + m[3] * 1 + m[5]), (1, 1));
      m = ImageOrientation.matrix(8);
      expect((m[0] * 0 + m[2] * 1 + m[4], m[1] * 0 + m[3] * 1 + m[5]), (0, 0));
      expect(ImageOrientation.swaps(5), isTrue);
      expect(ImageOrientation.swaps(4), isFalse);
    });
  });

  group('image fit', () {
    RawSchema s(String fit, String position) => RawSchema(<String, dynamic>{
      'width': 40,
      'height': 20,
      'objectFit': fit,
      'objectPosition': position,
    });

    test('contain and positions', () {
      ImageFit f = ImageFit.of(s('contain', 'right bottom'), 10, 10);
      expect((f.width, f.height, f.offsetX, f.offsetY), (20, 20, 20, 0));
      f = ImageFit.of(s('contain', 'bad'), 10, 10);
      expect(f.offsetX, 10);
    });

    test('cover is always centered', () {
      ImageFit f = ImageFit.of(s('cover', 'left top'), 10, 10);
      expect((f.width, f.height, f.offsetX, f.offsetY), (40, 40, 0, -10));
    });
  });
}

class _Recorder extends SchemaPlugin<UnknownSchema> {
  final List<String> values = <String>[];

  @override
  String get type => 'stamp';

  @override
  UnknownSchema fromJson(Map<String, Object?> json) =>
      UnknownSchema.fromJson(json);

  @override
  Future<void> pdf(RenderProps<UnknownSchema> props) async =>
      values.add(props.value);
}
