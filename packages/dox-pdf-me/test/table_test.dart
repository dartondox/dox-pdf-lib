import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';
import 'package:dox_pdf_me/src/dynamic_template.dart';
import 'package:dox_pdf_me/src/raw_template.dart';
import 'package:dox_pdf_me/src/schema.dart';
import 'package:dox_pdf_me/src/table/table_image.dart';
import 'package:dox_pdf_me/src/table/table_layout.dart';
import 'package:test/test.dart';

import 'support.dart';

Map<String, dynamic> cellStyle([
  Map<String, dynamic> extra = const <String, dynamic>{},
]) => <String, dynamic>{
  'alignment': 'left',
  'verticalAlignment': 'middle',
  'fontSize': 13,
  'lineHeight': 1,
  'characterSpacing': 0,
  'fontColor': '#000000',
  'backgroundColor': '',
  'borderColor': '#888888',
  'borderWidth': <String, num>{
    'top': 0.1,
    'right': 0.1,
    'bottom': 0.1,
    'left': 0.1,
  },
  'padding': <String, num>{'top': 5, 'right': 5, 'bottom': 5, 'left': 5},
  ...extra,
};

RawSchema table([Map<String, dynamic> extra = const <String, dynamic>{}]) =>
    RawSchema(<String, dynamic>{
      'name': 't',
      'type': 'table',
      'position': <String, num>{'x': 10, 'y': 20},
      'width': 130,
      'height': 20,
      'showHead': true,
      'repeatHead': false,
      'head': <String>['Name', 'City', 'Description'],
      'headWidthPercentages': <num>[30, 30, 40],
      'tableStyles': <String, dynamic>{
        'borderColor': '#000000',
        'borderWidth': 0.3,
      },
      'headStyles': cellStyle(<String, dynamic>{
        'borderWidth': <String, num>{
          'top': 0,
          'right': 0,
          'bottom': 0,
          'left': 0,
        },
      }),
      'bodyStyles': cellStyle(<String, dynamic>{
        'alternateBackgroundColor': '#f5f5f5',
      }),
      'columnStyles': <String, dynamic>{},
      ...extra,
    });

const Map<String, dynamic> blank = <String, dynamic>{
  'width': 150,
  'height': 100,
  'padding': <num>[10, 10, 10, 10],
};

Future<List<double>> heights(
  RawSchema s,
  String body, [
  Map<String, dynamic> basePdf = blank,
]) async {
  PDFDocument doc = await PDFDocument.create();
  try {
    TableLayout t = await TableLayout.create(
      s,
      parseTableBody(body),
      FontStore(doc, null),
      basePdf,
    );
    return t.dynamicHeights(basePdf);
  } finally {
    doc.dispose();
  }
}

void expectClose(List<double> actual, List<double> expected) {
  expect(actual.length, expected.length, reason: '$actual');
  for (int i = 0; i < actual.length; i++) {
    expect(actual[i], closeTo(expected[i], 1e-6), reason: '$actual');
  }
}

void main() {
  // The expected numbers come from pdfme 6.2.8 getDynamicHeightsForTable
  // with the default font (Roboto).
  group('table row heights', () {
    String body = jsonEncode(<List<String>>[
      <String>[
        'Alice',
        'New York',
        'Alice is a freelance web designer and developer',
      ],
      <String>['Bob', 'Paris', 'Bob'],
      <String>['Carol', 'Rome', 'A\nB\nC'],
    ]);

    test('wrapped and multi-line cells', () async {
      expectClose(await heights(table(), body), <double>[
        14.5864,
        23.9592,
        14.7864,
        23.9592,
      ]);
    });

    test('no head: unit 0 is 0', () async {
      expectClose(
        await heights(table(<String, dynamic>{'showHead': false}), body),
        <double>[0, 23.9592, 14.7864, 23.9592],
      );
    });

    test('font size, line height, spacing, padding and borders', () async {
      RawSchema s = table(<String, dynamic>{
        'bodyStyles': cellStyle(<String, dynamic>{
          'fontSize': 9,
          'lineHeight': 1.5,
          'characterSpacing': 1,
          'padding': <String, num>{
            'top': 1,
            'right': 4,
            'bottom': 2,
            'left': 3,
          },
          'borderWidth': <String, num>{
            'top': 0.5,
            'right': 2,
            'bottom': 1,
            'left': 0,
          },
        }),
      });
      expectClose(await heights(s, body), <double>[
        14.5864,
        14.0256,
        9.2628,
        18.7884,
      ]);
    });

    test(
      'a head that would end a page alone moves with the first row',
      () async {
        RawSchema s = table(<String, dynamic>{
          'repeatHead': true,
          'position': <String, num>{'x': 10, 'y': 60},
        });
        expectClose(await heights(s, body), <double>[
          14.5864,
          23.9592,
          14.7864,
          23.9592,
        ]);
      },
    );

    test('repeatHead adds the head to the first row of a new page', () async {
      String rows = jsonEncode(<List<String>>[
        for (int i = 0; i < 6; i++) <String>['x', 'y', 'A\nB\nC'],
      ]);
      expectClose(
        await heights(table(<String, dynamic>{'repeatHead': true}), rows),
        <double>[14.5864, 23.9592, 23.9592, 38.5456, 23.9592, 38.5456, 23.9592],
      );
    });

    group('image cells', () {
      String png =
          'data:image/png;base64,'
          '${base64.encode(File('test/fixtures/crosscheck/image.png').readAsBytesSync())}';
      RawSchema s = table(<String, dynamic>{
        'columnStyles': <String, dynamic>{
          'cellType': <String, String>{'0': 'image', '2': 'image'},
          'imageHeightMode': <String, String>{'2': 'auto'},
          'imageHeight': <String, num>{'0': 12},
        },
      });
      String rows = jsonEncode(<List<String>>[
        <String>[png, 'a', png],
        <String>['', 'b', ''],
        <String>['bad', 'c', 'data:image/png;base64,AAAA'],
      ]);

      test('fixed, auto, empty and broken images', () async {
        expectClose(await heights(s, rows), <double>[
          14.5864,
          38.066666666666666,
          22.2,
          22.2,
        ]);
      });

      test('auto images fit on one page below the head', () async {
        expectClose(
          await heights(s, rows, <String, dynamic>{
            'width': 150,
            'height': 40,
            'padding': <num>[5, 5, 5, 5],
          }),
          <double>[14.5864, 22.2, 22.2, 22.2],
        );
      });

      test('object position from the cell alignment', () {
        expect(tableImageObjectPosition('right', 'top'), 'right top');
        expect(tableImageObjectPosition('justify', null), 'left center');
      });
    });

    test('a row with fewer cells than the head throws, like pdfme', () {
      expect(
        heights(table(), '[["a", "b"]]'),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message,
            'message',
            "Cannot read properties of undefined (reading 'split')",
          ),
        ),
      );
    });

    test('a column without a width throws', () {
      expect(
        heights(
          table(<String, dynamic>{
            'headWidthPercentages': <num>[30, 30],
          }),
          '[]',
        ),
        throwsArgumentError,
      );
    });

    test('column widths come from headWidthPercentages', () async {
      PDFDocument doc = await PDFDocument.create();
      try {
        TableLayout t = await TableLayout.create(
          table(),
          const <List<String>>[],
          FontStore(doc, null),
          blank,
        );
        expectClose(t.columnWidths, <double>[39, 39, 52]);
      } finally {
        doc.dispose();
      }
    });
  });

  group('table body', () {
    test('JSON rows; empty is no rows; cells become strings', () {
      expect(parseTableBody(''), isEmpty);
      expect(parseTableBody('[["a", 1, null, true]]'), <List<String>>[
        <String>['a', '1', 'null', 'true'],
      ]);
    });

    test('bad JSON and too deep JSON throw an ArgumentError', () {
      expect(() => parseTableBody('[["a"'), throwsArgumentError);
      expect(
        () => parseTableBody('${'[' * 100000}${']' * 100000}'),
        throwsArgumentError,
      );
    });

    test('a part draws its __splitRange rows', () {
      List<List<String>> body = <List<String>>[
        for (int i = 0; i < 5; i++) <String>['$i'],
      ];
      RawSchema part = table(<String, dynamic>{
        '__splitRange': <String, dynamic>{
          'unit': 'tableBody',
          'start': 1,
          'end': 3,
        },
      });
      expect(tableBodyPart(body, part), <List<String>>[
        <String>['1'],
        <String>['2'],
      ]);
    });
  });

  // pdfme's common/__tests__/dynamicTemplate.test.ts: `a` grows to the
  // given units, `b` keeps its height.
  group('dynamic template', () {
    const double padding = 10;
    RawTemplate template() => RawTemplate(
      basePdf: <String, dynamic>{
        'width': 100,
        'height': 100,
        'padding': <num>[padding, padding, padding, padding],
      },
      schemas: <List<RawSchema>>[
        <RawSchema>[
          RawSchema(<String, dynamic>{
            'name': 'a',
            'type': 'table',
            'position': <String, num>{'x': 10, 'y': 10},
            'width': 10,
            'height': 10,
          }),
          RawSchema(<String, dynamic>{
            'name': 'b',
            'type': 'table',
            'position': <String, num>{'x': 10, 'y': 30},
            'width': 10,
            'height': 10,
          }),
        ],
      ],
    );

    Future<List<List<RawSchema>>> run(List<double> aHeights, [double? b]) =>
        dynamicTemplate(
          template(),
          (RawSchema s) async =>
              DynamicLayout(s.name == 'a' ? aHeights : <double>[b ?? s.height]),
        );

    test('no page break', () async {
      List<List<RawSchema>> p = await run(<double>[10, 10, 10, 10, 10]);
      expect(p.length, 1);
      expect(p[0][0].y, 10);
      expect(p[0][1].y, 50 - 10 + 30);
    });

    test('a on page 1, b on page 2', () async {
      List<List<RawSchema>> p = await run(<double>[20, 20, 20, 20]);
      expect(p.length, 2);
      expect(p[0].map((RawSchema s) => s.name), <String>['a']);
      expect(p[1].map((RawSchema s) => s.name), <String>['b']);
      expect(p[1][0].y, padding + padding);
    });

    test('a on pages 1 and 2, b on page 2', () async {
      List<List<RawSchema>> p = await run(<double>[20, 20, 20, 20, 20]);
      expect(p.length, 2);
      expect(p[1][0].name, 'a');
      expect(p[1][0].y, padding);
      expect(p[1][1].name, 'b');
      expect(p[1][1].y, 40 - 10 + padding);
    });

    test('many page breaks', () async {
      List<List<RawSchema>> p = await run(<double>[50, 50, 50, 50, 50]);
      expect(p.length, 5);
      for (int i = 0; i < 5; i++) {
        expect(p[i][0].name, 'a');
        expect(p[i][0].height, 50);
        expect(p[i][0].y, i == 0 ? 10 : padding);
      }
      expect(p[4][1].name, 'b');
      expect(p[4][1].y, 70);
    });

    test('a and b on the next page', () async {
      List<List<RawSchema>> p = await run(<double>[80, 10, 10]);
      expect(p.length, 2);
      expect(p[0].length, 1);
      expect(p[0][0].height, 80);
      expect(p[1][0].y, padding);
      expect(p[1][0].height, 20);
      expect(p[1][1].y, greaterThanOrEqualTo(30));
    });

    test('b grows too', () async {
      List<List<RawSchema>> p = await run(<double>[10, 10, 10, 10, 10], 30);
      expect(p.length, 2);
      expect(p[0][0].height, 50);
      expect(p[1][0].name, 'b');
      expect(p[1][0].y, padding);
      expect(p[1][0].height, 30);
    });

    test('empty heights are one unit of 0', () async {
      List<List<RawSchema>> p = await run(<double>[]);
      expect(p.length, 1);
      expect(p[0][0].height, 0);
      expect(p[0][1].name, 'b');
    });

    test('very large units still make pages', () async {
      expect((await run(<double>[1000, 1000])).length, greaterThan(1));
    });

    RawTemplate one(
      double y, {
      List<num> padding = const <num>[10, 10, 10, 10],
    }) => RawTemplate(
      basePdf: <String, dynamic>{
        'width': 100,
        'height': 100,
        'padding': padding,
      },
      schemas: <List<RawSchema>>[
        <RawSchema>[
          RawSchema(<String, dynamic>{
            'name': 'a',
            'type': 'table',
            'position': <String, num>{'x': 10, 'y': y},
            'width': 10,
            'height': 10,
          }),
        ],
      ],
    );
    Future<DynamicLayout> twoRows(RawSchema s) async =>
        DynamicLayout(<double>[10, 10]);

    test('a schema far down throws instead of making millions of pages', () {
      for (double y in <double>[1e9, 1e308]) {
        expect(dynamicTemplate(one(y), twoRows), throwsArgumentError);
      }
    });

    test('a NaN or infinite y throws', () {
      for (double y in <double>[double.nan, double.infinity]) {
        expect(dynamicTemplate(one(y), twoRows), throwsArgumentError);
      }
    });

    test('padding that leaves no room throws', () {
      expect(
        dynamicTemplate(one(10, padding: const <num>[50, 10, 50, 10]), twoRows),
        throwsArgumentError,
      );
    });

    test('an empty template page stays', () async {
      RawTemplate t = RawTemplate(
        basePdf: template().basePdf,
        schemas: <List<RawSchema>>[<RawSchema>[]],
      );
      List<List<RawSchema>> p = await dynamicTemplate(
        t,
        (RawSchema s) => throw StateError('not called'),
      );
      expect(identical(p, t.schemas), isTrue);
    });

    for (double actual in <double>[25, 0]) {
      test('a shrunk table pulls overlapping schemas up ($actual)', () async {
        RawTemplate t = RawTemplate(
          basePdf: <String, dynamic>{
            'width': 210,
            'height': 297,
            'padding': <num>[15, 15, 15, 15],
          },
          schemas: <List<RawSchema>>[
            <RawSchema>[
              RawSchema(<String, dynamic>{
                'name': 'table',
                'type': 'table',
                'position': <String, num>{'x': 15, 'y': 19.91},
                'width': 150,
                'height': 52.932,
              }),
              RawSchema(<String, dynamic>{
                'name': 'caption',
                'type': 'text',
                'position': <String, num>{'x': 15, 'y': 20},
                'width': 70,
                'height': 9,
              }),
              RawSchema(<String, dynamic>{
                'name': 'following',
                'type': 'text',
                'position': <String, num>{'x': 15, 'y': 90},
                'width': 70,
                'height': 9,
              }),
            ],
          ],
        );
        List<List<RawSchema>> p = await dynamicTemplate(
          t,
          (RawSchema s) async => DynamicLayout(<double>[actual]),
        );
        expect(p.length, 1);
        expect(p[0].map((RawSchema s) => s.name), <String>[
          'table',
          'caption',
          'following',
        ]);
        expect(p[0][0].height, actual);
        expect(p[0][1].y, 15);
        expect(p[0][2].y, 85);
        expect(t.schemas[0][0].height, 52.932);
      });
    }
  });

  group('generate', () {
    Map<String, dynamic> template(Map<String, dynamic> extra) =>
        <String, dynamic>{
          'basePdf': blank,
          'schemas': <List<Map<String, dynamic>>>[
            <Map<String, dynamic>>[
              <String, dynamic>{...table().json, ...extra},
            ],
          ],
        };

    Future<int> pages(
      Map<String, dynamic> t,
      Map<String, dynamic> input,
    ) async {
      Uint8List bytes = await generateJson(
        template: t,
        inputs: <Map<String, dynamic>>[input],
        plugins: builtInPlugins,
      );
      PDFDocument doc = await PDFDocument.load(bytes);
      try {
        return doc.getPageCount();
      } finally {
        doc.dispose();
      }
    }

    List<List<String>> rows(int n) => <List<String>>[
      for (int i = 0; i < n; i++) <String>['$i', 'x', 'y'],
    ];

    test('a long table goes on over new pages', () async {
      expect(
        await pages(template(const <String, dynamic>{}), <String, dynamic>{
          't': '',
        }),
        1,
      );
      // each row is 14.7864 mm, 80 mm per page
      expect(
        await pages(template(const <String, dynamic>{}), <String, dynamic>{
          't': jsonEncode(rows(12)),
        }),
        3,
      );
      // a list works like its JSON string
      expect(
        await pages(template(const <String, dynamic>{}), <String, dynamic>{
          't': rows(12),
        }),
        3,
      );
    });

    test('read-only: the input wins over content', () async {
      Map<String, dynamic> t = template(<String, dynamic>{
        'readOnly': true,
        'content': jsonEncode(rows(12)),
      });
      expect(await pages(t, <String, dynamic>{}), 3);
      expect(await pages(t, <String, dynamic>{'t': '[]'}), 1);
    });

    test('a PDF base gets no new pages', () async {
      PDFDocument base = await PDFDocument.create();
      base
          .addPage(<double>[425.19, 283.46])
          .drawRectangle(x: 0, y: 0, width: 1, height: 1);
      Uint8List baseBytes = await base.save();
      base.dispose();
      Map<String, dynamic> t = template(const <String, dynamic>{})
        ..['basePdf'] = baseBytes;
      expect(await pages(t, <String, dynamic>{'t': jsonEncode(rows(12))}), 1);
    });
  });
}
