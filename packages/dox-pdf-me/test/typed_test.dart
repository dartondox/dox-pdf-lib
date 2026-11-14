// The typed API: templates built in Dart draw the same as the pdfme JSON,
// and toJson / fromJson keep the designer JSON as it is.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The JSON of the pdfme designer (`propPanel.defaultSchema` of pdfme
/// 6.2.8), at [x], [y], with more keys from [props].
Map<String, Object?> designer(
  String type,
  double x,
  double y,
  Map<String, Object?> props,
) => <String, Object?>{
  'name': type,
  'type': type,
  'position': <String, Object?>{'x': x, 'y': y},
  ...props,
};

const Map<String, Object?> textProps = <String, Object?>{
  'rotate': 0,
  'alignment': 'left',
  'verticalAlignment': 'top',
  'fontSize': 13,
  'textFormat': 'plain',
  'overflow': 'visible',
  'fontVariantFallback': 'synthetic',
  'lineHeight': 1,
  'characterSpacing': 0,
  'fontColor': '#000000',
  'backgroundColor': '',
  'borderColor': '#000000',
  'borderWidth': <String, Object?>{
    'top': 0,
    'right': 0,
    'bottom': 0,
    'left': 0,
  },
  'padding': <String, Object?>{'top': 0, 'right': 0, 'bottom': 0, 'left': 0},
  'opacity': 1,
  'strikethrough': false,
  'underline': false,
};

const Map<String, Object?> dateProps = <String, Object?>{
  'width': 50,
  'height': 10,
  'rotate': 0,
  'alignment': 'left',
  'fontSize': 13,
  'characterSpacing': 0,
  'fontColor': '#000000',
  'backgroundColor': '',
  'opacity': 1,
};

String dataUrl(String file, String mime) =>
    'data:$mime;base64,'
    '${base64.encode(File('test/fixtures/crosscheck/$file').readAsBytesSync())}';

const String svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
    '<circle cx="5" cy="5" r="4" fill="#d32f2f"/></svg>';

/// One schema type: the typed schema, the designer JSON and an input.
typedef Case = (Schema typed, Map<String, Object?> json, String input);

List<Case> cases() {
  String png = dataUrl('image.png', 'image/png');
  String jpg = dataUrl('image.jpg', 'image/jpeg');
  List<List<String>> rows = <List<String>>[
    <String>['Alice', 'New York', 'Web designer'],
    <String>['Bob', 'Paris', 'Illustrator'],
  ];
  return <Case>[
    (
      const TextSchema(
        name: 'text',
        position: Position(10, 10),
        fontSize: 16,
        alignment: Alignment.center,
        backgroundColor: '#fff59d',
        dynamicFontSize: DynamicFontSize(min: 8, max: 20),
      ),
      designer('text', 10, 10, <String, Object?>{
        ...textProps,
        'width': 45,
        'height': 10,
        'fontSize': 16,
        'alignment': 'center',
        'backgroundColor': '#fff59d',
        'dynamicFontSize': <String, Object?>{
          'min': 8,
          'max': 20,
          'fit': 'vertical',
        },
      }),
      'Hello from Dart',
    ),
    (
      const MultiVariableTextSchema(
        name: 'multiVariableText',
        position: Position(10, 25),
        text: 'Hi {name}, from {city}',
        variables: <String>['name', 'city'],
      ),
      designer('multiVariableText', 10, 25, <String, Object?>{
        ...textProps,
        'width': 50,
        'height': 15,
        'readOnly': false,
        'text': 'Hi {name}, from {city}',
        'variables': <String>['name', 'city'],
      }),
      '{"name": "Ann", "city": "Paris"}',
    ),
    (
      const SelectSchema(name: 'select', position: Position(10, 45)),
      designer('select', 10, 45, <String, Object?>{
        ...textProps,
        'width': 45,
        'height': 10,
        'options': <String>['option1', 'option2'],
      }),
      'option2',
    ),
    (
      const ImageSchema(
        name: 'image',
        position: Position(70, 10),
        objectFit: ObjectFit.cover,
      ),
      designer('image', 70, 10, <String, Object?>{
        'width': 40,
        'height': 40,
        'objectFit': 'cover',
        'objectPosition': 'center center',
        'rotate': 0,
        'opacity': 1,
      }),
      png,
    ),
    (
      const SignatureSchema(name: 'signature', position: Position(120, 10)),
      designer('signature', 120, 10, <String, Object?>{
        'width': 62.5,
        'height': 37.5,
      }),
      jpg,
    ),
    (
      const SvgSchema(name: 'svg', position: Position(10, 60), width: 20),
      designer('svg', 10, 60, <String, Object?>{
        'width': 20,
        'height': 50,
        'rotate': 0,
      }),
      svg,
    ),
    (
      const LineSchema(name: 'line', position: Position(40, 60), rotate: 30),
      designer('line', 40, 60, <String, Object?>{
        'width': 50,
        'height': 0.5,
        'rotate': 30,
        'opacity': 1,
        'readOnly': true,
        'color': '#000000',
      }),
      '',
    ),
    (
      const RectangleSchema(
        name: 'rectangle',
        position: Position(40, 70),
        color: '#b3e5fc',
        radius: 5,
      ),
      designer('rectangle', 40, 70, <String, Object?>{
        'width': 62.5,
        'height': 37.5,
        'rotate': 0,
        'opacity': 1,
        'borderWidth': 1,
        'borderColor': '#000000',
        'color': '#b3e5fc',
        'readOnly': true,
        'radius': 5,
      }),
      '',
    ),
    (
      const EllipseSchema(
        name: 'ellipse',
        position: Position(110, 70),
        borderColor: '#d32f2f',
        opacity: 0.5,
      ),
      designer('ellipse', 110, 70, <String, Object?>{
        'width': 62.5,
        'height': 37.5,
        'rotate': 0,
        'opacity': 0.5,
        'borderWidth': 1,
        'borderColor': '#d32f2f',
        'color': '',
        'readOnly': true,
        'radius': 0,
      }),
      '',
    ),
    (
      const CircleMarkSchema(name: 'circleMark', position: Position(10, 115)),
      designer('circleMark', 10, 115, <String, Object?>{
        'width': 10,
        'height': 10,
        'rotate': 0,
        'opacity': 1,
        'color': '#000000',
        'borderWidth': 1,
      }),
      'true',
    ),
    (
      const CheckboxSchema(name: 'checkbox', position: Position(25, 115)),
      designer('checkbox', 25, 115, <String, Object?>{
        'width': 8,
        'height': 8,
        'color': '#000000',
      }),
      'true',
    ),
    (
      const RadioGroupSchema(name: 'radioGroup', position: Position(35, 115)),
      designer('radioGroup', 35, 115, <String, Object?>{
        'width': 8,
        'height': 8,
        'group': 'MyGroup',
        'color': '#000000',
      }),
      'true',
    ),
    (
      BarcodeSchema(
        name: 'qrcode',
        barcodeType: BarcodeType.qrcode,
        position: const Position(50, 115),
      ),
      designer('qrcode', 50, 115, <String, Object?>{
        'backgroundColor': '#ffffff',
        'barColor': '#000000',
        'width': 30,
        'height': 30,
        'rotate': 0,
        'opacity': 1,
      }),
      'https://pdfme.com/',
    ),
    (
      BarcodeSchema(
        name: 'ean13',
        barcodeType: BarcodeType.ean13,
        position: const Position(90, 115),
        barColor: '#1565c0',
      ),
      designer('ean13', 90, 115, <String, Object?>{
        'backgroundColor': '#ffffff',
        'barColor': '#1565c0',
        'textColor': '#000000',
        'includetext': true,
        'width': 40,
        'height': 16,
        'rotate': 0,
        'opacity': 1,
      }),
      '2112345678900',
    ),
    (
      BarcodeSchema(
        name: 'code128',
        barcodeType: BarcodeType.code128,
        position: const Position(140, 115),
        includetext: false,
      ),
      designer('code128', 140, 115, <String, Object?>{
        'backgroundColor': '#ffffff',
        'barColor': '#000000',
        'textColor': '#000000',
        'includetext': false,
        'width': 40,
        'height': 20,
        'rotate': 0,
        'opacity': 1,
      }),
      'This is Code 128!',
    ),
    (
      const DateSchema(
        name: 'date',
        position: Position(10, 150),
        format: 'MM/dd/yyyy',
      ),
      designer('date', 10, 150, <String, Object?>{
        ...dateProps,
        'format': 'MM/dd/yyyy',
      }),
      '2026/11/14',
    ),
    (
      const TimeSchema(name: 'time', position: Position(65, 150)),
      designer('time', 65, 150, dateProps),
      '20:25',
    ),
    (
      const DateTimeSchema(
        name: 'dateTime',
        position: Position(120, 150),
        format: 'yyyy-MM-dd HH:mm',
        alignment: Alignment.right,
      ),
      designer('dateTime', 120, 150, <String, Object?>{
        ...dateProps,
        'format': 'yyyy-MM-dd HH:mm',
        'alignment': 'right',
      }),
      '2026/11/14 20:25',
    ),
    (
      const TableSchema(
        name: 'table',
        position: Position(10, 170),
        headWidthPercentages: <double>[30, 30, 40],
        columnStyles: ColumnStyles(
          alignment: <int, Alignment>{2: Alignment.right},
        ),
      ),
      designer('table', 10, 170, <String, Object?>{
        'width': 150,
        'height': 20,
        'showHead': true,
        'repeatHead': false,
        'head': <String>['Name', 'City', 'Description'],
        'headWidthPercentages': <num>[30, 30, 40],
        'tableStyles': <String, Object?>{
          'borderColor': '#000000',
          'borderWidth': 0.3,
        },
        'headStyles': <String, Object?>{
          'alignment': 'left',
          'verticalAlignment': 'middle',
          'fontSize': 13,
          'lineHeight': 1,
          'characterSpacing': 0,
          'fontColor': '#ffffff',
          'backgroundColor': '#2980ba',
          'borderColor': '',
          'borderWidth': <String, Object?>{
            'top': 0,
            'right': 0,
            'bottom': 0,
            'left': 0,
          },
          'padding': <String, Object?>{
            'top': 5,
            'right': 5,
            'bottom': 5,
            'left': 5,
          },
        },
        'bodyStyles': <String, Object?>{
          'alignment': 'left',
          'verticalAlignment': 'middle',
          'fontSize': 13,
          'lineHeight': 1,
          'characterSpacing': 0,
          'fontColor': '#000000',
          'backgroundColor': '',
          'borderColor': '#888888',
          'borderWidth': <String, Object?>{
            'top': 0.1,
            'right': 0.1,
            'bottom': 0.1,
            'left': 0.1,
          },
          'padding': <String, Object?>{
            'top': 5,
            'right': 5,
            'bottom': 5,
            'left': 5,
          },
          'alternateBackgroundColor': '#f5f5f5',
        },
        'columnStyles': <String, Object?>{
          'alignment': <String, Object?>{'2': 'right'},
        },
      }),
      jsonEncode(rows),
    ),
  ];
}

final GenerateOptions fixedDates = GenerateOptions(
  creationDate: DateTime.utc(2026, 11, 14),
  modificationDate: DateTime.utc(2026, 11, 14),
);

Future<Uint8List> draw(Template template, Map<String, String> input) =>
    generate(
      template: template,
      inputs: <Map<String, String>>[input],
      options: fixedDates,
      plugins: builtInPlugins,
    );

int _renders = 0;

/// The two PDFs are the same, or (when only the bytes differ, eg. an
/// opacity of 1 that one side writes) their pages look the same.
Future<void> expectSameLook(Uint8List a, Uint8List b) async {
  if (_equal(a, b)) return;
  if (!hasTool('pdftoppm')) fail('the PDFs differ, and pdftoppm is missing');
  String dir = '.dart_tool/typed_test/${_renders++}';
  Directory(dir).createSync(recursive: true);
  File('$dir/a.pdf').writeAsBytesSync(a);
  File('$dir/b.pdf').writeAsBytesSync(b);
  List<Ppm> pa = renderPages('$dir/a.pdf', '$dir/a', dpi: 100);
  List<Ppm> pb = renderPages('$dir/b.pdf', '$dir/b', dpi: 100);
  expect(pa.length, pb.length);
  for (int i = 0; i < pa.length; i++) {
    expect(pixelDifference(pa[i], pb[i], threshold: 0), 0, reason: 'page $i');
  }
}

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  group('a template built in Dart draws like the designer JSON', () {
    for (Case c in cases()) {
      test(c.$1.type == 'qrcode' ? 'qrcode' : c.$1.name, () async {
        Map<String, String> input = <String, String>{c.$1.name: c.$3};
        Uint8List typed = await draw(
          Template(
            basePdf: const BlankPdf(),
            schemas: <List<Schema>>[
              <Schema>[c.$1],
            ],
          ),
          input,
        );
        Uint8List fromJson = await draw(
          Template.fromJson(<String, Object?>{
            'basePdf': <String, Object?>{
              'width': 210,
              'height': 297,
              'padding': <int>[10, 10, 10, 10],
            },
            'schemas': <Object?>[
              <Object?>[c.$2],
            ],
          }),
          input,
        );
        await expectSameLook(typed, fromJson);
      });
    }

    test('all types on one page', () async {
      List<Case> all = cases();
      Map<String, String> input = <String, String>{
        for (Case c in all) c.$1.name: c.$3,
      };
      Template typed = Template(
        basePdf: const BlankPdf(),
        schemas: <List<Schema>>[
          <Schema>[for (Case c in all) c.$1],
        ],
      );
      Template json = Template.fromJson(<String, Object?>{
        'basePdf': <String, Object?>{
          'width': 210,
          'height': 297,
          'padding': <int>[10, 10, 10, 10],
        },
        'schemas': <Object?>[
          <Object?>[for (Case c in all) c.$2],
        ],
      });
      await expectSameLook(await draw(typed, input), await draw(json, input));
    });
  });

  group('fromJson reads the designer JSON', () {
    test('each type gets its class', () {
      for (Case c in cases()) {
        Schema read = Template.fromJson(<String, Object?>{
          'basePdf': <String, Object?>{
            'width': 210,
            'height': 297,
            'padding': <int>[0, 0, 0, 0],
          },
          'schemas': <Object?>[
            <Object?>[c.$2],
          ],
        }).schemas.single.single;
        expect(read.runtimeType, c.$1.runtimeType, reason: c.$1.type);
        expect(read.type, c.$1.type);
        expect(read.name, c.$1.name);
        expect(read.position.x, c.$1.position.x);
        expect(read.width, c.$1.width);
        expect(read.height, c.$1.height);
      }
    });

    test('typed values', () {
      List<Case> all = cases();
      TextSchema text = TextSchema.fromJson(all[0].$2);
      expect(text.fontSize, 16);
      expect(text.alignment, Alignment.center);
      expect(text.verticalAlignment, VerticalAlignment.top);
      expect(text.dynamicFontSize?.max, 20);
      expect(text.dynamicFontSize?.fit, DynamicFontSizeFit.vertical);
      expect(text.padding.left, 0);
      BarcodeSchema code = BarcodeSchema.fromJson(all[14].$2);
      expect(code.barcodeType, BarcodeType.code128);
      expect(code.includetext, isFalse);
      TableSchema table = TableSchema.fromJson(all.last.$2);
      expect(table.headWidthPercentages, <double>[30, 30, 40]);
      expect(table.headStyles.backgroundColor, '#2980ba');
      expect(table.bodyStyles.alternateBackgroundColor, '#f5f5f5');
      expect(table.bodyStyles.borderWidth.top, 0.1);
      expect(table.columnStyles.alignment, <int, Alignment>{
        2: Alignment.right,
      });
    });

    test('missing keys give the pdfme defaults', () {
      TextSchema text = TextSchema.fromJson(<String, Object?>{
        'name': 'a',
        'type': 'text',
      });
      expect(text.fontSize, 13);
      expect(text.lineHeight, 1);
      expect(text.fontColor, '#000000');
      expect(text.position.x, 0);
      LineSchema line = LineSchema.fromJson(<String, Object?>{'type': 'line'});
      expect(line.color, '#000000');
      ImageSchema image = ImageSchema.fromJson(<String, Object?>{});
      expect(image.objectFit, ObjectFit.contain);
      expect(image.objectPosition, ObjectPosition.centerCenter);
    });
  });

  group('toJson and fromJson', () {
    test('designer JSON comes back as it was, with unknown keys', () {
      Map<String, Object?> json = <String, Object?>{
        'basePdf': <String, Object?>{
          'width': 210,
          'height': 297,
          'padding': <int>[10, 10, 10, 10],
        },
        'schemas': <Object?>[
          <Object?>[
            for (Case c in cases())
              <String, Object?>{
                ...c.$2,
                'fromTheFrontend': <String, Object?>{'id': c.$1.name},
                'fontSize': c.$2['fontSize'] ?? '12',
              },
          ],
          <Object?>[
            <String, Object?>{
              'name': 'stamp',
              'type': 'stamp',
              'position': <String, Object?>{'x': 1, 'y': 2},
              'label': 'PAID',
            },
          ],
        ],
      };
      Template template = Template.fromJson(json);
      expect(template.schemas[1].single, isA<UnknownSchema>());
      expect(template.toJson(), json);
      // and once more, through a JSON string
      expect(
        Template.fromJson(
          jsonDecode(jsonEncode(template.toJson())) as Map<String, Object?>,
        ).toJson(),
        json,
      );
    });

    test('the old format (a map per page) is read', () {
      Template template = Template.fromJson(<String, Object?>{
        'basePdf': <String, Object?>{
          'width': 100,
          'height': 100,
          'padding': <int>[0, 0, 0, 0],
        },
        'schemas': <Object?>[
          <String, Object?>{
            'title': <String, Object?>{
              'type': 'text',
              'position': <String, Object?>{'x': 1, 'y': 2},
              'width': 30,
              'height': 10,
            },
          },
        ],
      });
      Schema s = template.schemas.single.single;
      expect(s, isA<TextSchema>());
      expect(s.name, 'title');
    });

    test('a schema built in Dart goes to JSON and back', () {
      for (Case c in cases()) {
        Map<String, Object?> json = c.$1.toJson();
        Schema back = Template.fromJson(<String, Object?>{
          'basePdf': <String, Object?>{
            'width': 210,
            'height': 297,
            'padding': <int>[0, 0, 0, 0],
          },
          'schemas': <Object?>[
            <Object?>[json],
          ],
        }).schemas.single.single;
        expect(back.toJson(), json, reason: c.$1.type);
        // every key of the designer JSON is written, with the same value
        for (MapEntry<String, Object?> e in c.$2.entries) {
          expect(json[e.key], e.value, reason: '${c.$1.type}.${e.key}');
        }
      }
    });

    test('static schemas and a PDF base', () {
      Uint8List pdf = File('test/fixtures/crosscheck/base.pdf')
          .readAsBytesSync();
      Template t = Template.fromJson(<String, Object?>{
        'basePdf': 'data:application/pdf;base64,${base64.encode(pdf)}',
        'schemas': <Object?>[<Object?>[]],
      });
      expect((t.basePdf as PdfFile).bytes, pdf);
      Template blank = Template.fromJson(<String, Object?>{
        'basePdf': <String, Object?>{
          'width': 210,
          'height': 297,
          'padding': <int>[5, 6, 7, 8],
          'staticSchema': <Object?>[
            <String, Object?>{
              'name': 'header',
              'type': 'text',
              'readOnly': true,
              'content': '{currentPage}/{totalPages}',
            },
          ],
        },
        'schemas': <Object?>[<Object?>[]],
      });
      BlankPdf b = blank.basePdf as BlankPdf;
      expect(b.padding.toList(), <double>[5, 6, 7, 8]);
      expect(b.staticSchema.single, isA<TextSchema>());
      expect(b.staticSchema.single.content, '{currentPage}/{totalPages}');
    });
  });

  group('custom plugins', () {
    Template template = Template(
      basePdf: const BlankPdf(),
      schemas: <List<Schema>>[
        <Schema>[
          const StampSchema(
            name: 'stamp',
            position: Position(10, 10),
            label: 'PAID',
          ),
        ],
      ],
    );

    test('a plugin gets its own typed schema', () async {
      StampPlugin plugin = StampPlugin();
      await generate(
        template: template,
        inputs: <Map<String, String>>[
          <String, String>{'stamp': 'yes'},
        ],
        plugins: <String, SchemaPlugin<Schema>>{'Stamp': plugin},
      );
      expect(plugin.drawn, <String>['PAID:yes']);
    });

    test('Template.fromJson reads it with the plugin', () {
      Template read = Template.fromJson(
        template.toJson(),
        plugins: <String, SchemaPlugin<Schema>>{'Stamp': StampPlugin()},
      );
      StampSchema s = read.schemas.single.single as StampSchema;
      expect(s.label, 'PAID');
      expect(s.toJson(), template.schemas.single.single.toJson());
    });

    test('a plugin can draw a built-in schema', () async {
      Uint8List bytes = await generate(
        template: template,
        inputs: <Map<String, String>>[<String, String>{}],
        plugins: <String, SchemaPlugin<Schema>>{'Stamp': StampPlugin()},
      );
      expect((await PDFDocument.load(bytes)).getPageCount(), 1);
    });
  });

  test('a table with its own head but no widths splits 100 equally', () async {
    TableSchema table = const TableSchema(
      name: 'a',
      position: Position(10, 10),
      head: <String>['A', 'B'],
    );
    expect(table.headWidthPercentages, <double>[50, 50]);
    expect(
      await generate(
        template: Template(
          basePdf: const BlankPdf(),
          schemas: <List<Schema>>[
            <Schema>[table],
          ],
        ),
        inputs: <Map<String, String>>[
          <String, String>{
            'a': jsonEncode(<List<String>>[
              <String>['a', 'b'],
            ]),
          },
        ],
        plugins: builtInPlugins,
      ),
      isNotEmpty,
    );
    TableSchema plain = const TableSchema(
      name: 'a',
      position: Position(10, 10),
    );
    expect(plain.head, <String>['Name', 'City', 'Description']);
    expect(plain.headWidthPercentages, <double>[30, 30, 40]);
  });

  test('a select has the designer options by default', () {
    expect(
      const SelectSchema(name: 's', position: Position(0, 0)).options,
      <String>['option1', 'option2'],
    );
  });

  test('fromJson of a table with no styles uses head and body defaults', () {
    TableSchema t = TableSchema.fromJson(<String, Object?>{
      'name': 't',
      'type': 'table',
      'position': <String, Object?>{'x': 0, 'y': 0},
      'width': 100,
      'height': 20,
    });
    expect(t.headStyles.fontColor, '#ffffff');
    expect(t.headStyles.backgroundColor, '#2980ba');
    expect(t.headStyles.borderWidth.top, 0);
    expect(t.bodyStyles.fontColor, '#000000');
    expect(t.bodyStyles.borderWidth.top, 0.1);
  });

  test('Template.toJson keeps pdfmeVersion and unknown basePdf keys', () {
    Map<String, Object?> json = <String, Object?>{
      'pdfmeVersion': '6.2.8',
      'basePdf': <String, Object?>{
        'width': 210,
        'height': 297,
        'padding': <int>[10, 10, 10, 10],
        'fromTheFrontend': 'x',
      },
      'schemas': <Object?>[<Object?>[]],
    };
    Map<String, Object?> out = Template.fromJson(json).toJson();
    expect(out['pdfmeVersion'], '6.2.8');
    expect((out['basePdf']! as Map<String, Object?>)['fromTheFrontend'], 'x');
    expect(Template.fromJson(out).toJson(), out);
  });

  test('a deep table input is a clear error, not a stack overflow', () {
    Template t = Template(
      basePdf: const BlankPdf(),
      schemas: <List<Schema>>[
        <Schema>[
          const TableSchema(
            name: 't',
            position: Position(10, 10),
            head: <String>['a'],
            headWidthPercentages: <double>[100],
          ),
        ],
      ],
    );
    String deep = '${'[' * 100000}${']' * 100000}';
    expect(
      generate(
        template: t,
        inputs: <Map<String, String>>[
          <String, String>{'t': deep},
        ],
        plugins: builtInPlugins,
      ),
      throwsArgumentError,
    );
  });
}

/// A custom schema type with its own field.
class StampSchema extends Schema {
  const StampSchema({
    required super.name,
    required super.position,
    super.width = 30,
    super.height = 10,
    this.label = '',
  });

  StampSchema.fromJson(super.json)
    : label = json['label'] is String ? json['label']! as String : '',
      super.fromJson();

  final String label;

  @override
  String get type => 'stamp';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    ...super.toJson(),
    'label': label,
  };
}

class StampPlugin extends SchemaPlugin<StampSchema> {
  final List<String> drawn = <String>[];

  @override
  String get type => 'stamp';

  @override
  StampSchema fromJson(Map<String, Object?> json) => StampSchema.fromJson(json);

  @override
  Future<void> pdf(RenderProps<StampSchema> props) async {
    drawn.add('${props.schema.label}:${props.value}');
    // draw the label with the built-in text plugin
    await const TextPlugin().pdf(
      props.withSchema(
        TextSchema(
          name: props.schema.name,
          position: props.schema.position,
          width: props.schema.width,
          height: props.schema.height,
          fontColor: '#d32f2f',
        ),
        value: props.schema.label,
      ),
    );
  }
}
