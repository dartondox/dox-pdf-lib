import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';
import 'package:dox_pdf_me/src/schema.dart';
import 'package:dox_pdf_me/src/text/multi_variable_text_plugin.dart';
import 'package:test/test.dart';

import 'support.dart';

typedef Mvt = MultiVariableTextDrawer;

RawSchema mvt(String text, List<String> variables, [Map<String, dynamic>? p]) =>
    RawSchema(<String, dynamic>{
      'name': 'm',
      'type': 'multiVariableText',
      'text': text,
      'variables': variables,
      ...?p,
    });

Future<String> pdfText(
  Map<String, dynamic> schema,
  Map<String, dynamic> input,
) async {
  Uint8List bytes = await generateJson(
    template: <String, dynamic>{
      'basePdf': <String, dynamic>{
        'width': 210,
        'height': 297,
        'padding': <int>[0, 0, 0, 0],
      },
      'schemas': <List<Map<String, dynamic>>>[
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'f',
            'position': <String, num>{'x': 10, 'y': 10},
            'width': 100,
            'height': 20,
            ...schema,
          },
        ],
      ],
    },
    inputs: <Map<String, dynamic>>[input],
    plugins: builtInPlugins,
  );
  return pdfStreams(bytes);
}

/// The PDF text with every Flate stream inflated, to find the operators
/// of the page.
String pdfStreams(Uint8List bytes) {
  String raw = latin1.decode(bytes);
  StringBuffer out = StringBuffer(raw);
  RegExp stream = RegExp(r'stream\r?\n');
  for (RegExpMatch m in stream.allMatches(raw)) {
    int end = raw.indexOf('endstream', m.end);
    if (end < 0) continue;
    try {
      out.write(
        latin1.decode(
          zlib.decode(bytes.sublist(m.end, end)),
          allowInvalid: true,
        ),
      );
    } on FormatException {
      continue;
    }
  }
  return out.toString();
}

void main() {
  test('builtInPlugins has the three types', () {
    expect(findPlugin(builtInPlugins, 'signature'), isA<SignaturePlugin>());
    expect(findPlugin(builtInPlugins, 'circleMark'), isA<CircleMarkPlugin>());
    expect(
      findPlugin(builtInPlugins, 'multiVariableText'),
      isA<MultiVariableTextPlugin>(),
    );
  });

  group('multiVariableText substituteVariables', () {
    test('fills variables and removes the ones without a value', () {
      expect(
        Mvt.substituteVariables(
          'Hi {name} from {city}{x}',
          '{"name":"Ann","city":"Rome"}',
        ),
        'Hi Ann from Rome',
      );
      expect(Mvt.substituteVariables('A {b} {} c', ''), 'A  {} c');
      expect(Mvt.substituteVariables('', 'not json'), '');
    });

    test('JavaScript replace patterns', () {
      expect(
        Mvt.substituteVariables('<{v}>', <String, dynamic>{
          'v': r"$$|$&|$`|$'|$1|$",
        }),
        // `$&` puts `{v}` back, and then it is removed like pdfme does
        r'<$||<|>|$1|$>',
      );
    });

    test('values become JavaScript strings', () {
      expect(
        Mvt.substituteVariables(
          '{a} {b} {c} {d}',
          '{"a":1.0,"b":2.5,'
              '"c":true,"d":null}',
        ),
        '1 2.5 true null',
      );
    });

    test('number keys go first, like Object.keys', () {
      expect(
        Mvt.substituteVariables(
          '{a} {1}',
          '{"b":"B","a":"{b}","2":"two","1":"{2}"}',
        ),
        ' two',
      );
    });

    test('special characters in names are plain text', () {
      expect(
        Mvt.substituteVariables('{a.b} {a*} {(x)}', <String, dynamic>{
          'a.b': '1',
          'a*': '2',
          '(x)': '3',
        }),
        '1 2 3',
      );
    });

    test('bad JSON throws', () {
      expect(
        () => Mvt.substituteVariables('{a}', '{bad'),
        throwsFormatException,
      );
    });
  });

  group('multiVariableText validateVariables', () {
    test('missing or null variable gives false', () {
      RawSchema s = mvt('{a} {b}', <String>['a', 'b']);
      expect(Mvt.validateVariables('{"a":"1","b":""}', s), isTrue);
      expect(Mvt.validateVariables('{"a":"1"}', s), isFalse);
      expect(Mvt.validateVariables('{"a":"1","b":null}', s), isFalse);
      expect(Mvt.validateVariables('', s), isFalse);
      expect(Mvt.validateVariables('', mvt('x', <String>[])), isTrue);
    });

    test('required throws for a missing variable', () {
      RawSchema s = mvt(
        '{a}',
        <String>['a'],
        <String, dynamic>{'required': true},
      );
      expect(() => Mvt.validateVariables('{}', s), throwsArgumentError);
    });

    test('bad JSON throws', () {
      expect(
        () => Mvt.validateVariables('nope', mvt('{a}', <String>['a'])),
        throwsFormatException,
      );
    });
  });

  group('multiVariableText readOnly', () {
    test('content holds the values', () {
      RawSchema s = mvt(
        'Hi {a}',
        <String>['a'],
        <String, dynamic>{'readOnly': true, 'content': '{"a":"Ann"}'},
      );
      expect(Mvt.readOnlyText(s, '{"a":"Ann"}'), 'Hi Ann');
    });

    test('contentSnapshot draws the content', () {
      RawSchema s = mvt(
        'Hi {a}',
        <String>['a'],
        <String, dynamic>{
          'readOnly': true,
          'contentSnapshot': true,
          'content': 'Done',
        },
      );
      expect(Mvt.readOnlyText(s, 'Done'), 'Done');
    });

    test('no variables: the text as it is', () {
      RawSchema s = mvt('Static {x}', <String>[], <String, dynamic>{
        'readOnly': true,
      });
      expect(Mvt.readOnlyText(s, ''), 'Static {x}');
    });

    test('content that is not JSON is drawn', () {
      RawSchema s = mvt(
        'Hi {a}',
        <String>['a'],
        <String, dynamic>{'readOnly': true, 'content': 'plain'},
      );
      expect(Mvt.readOnlyText(s, 'plain'), 'plain');
    });
  });

  group('generate', () {
    test('multiVariableText draws the filled text', () async {
      String pdf = await pdfText(
        <String, dynamic>{
          'type': 'multiVariableText',
          'text': 'Hi {a}',
          'variables': <String>['a'],
        },
        <String, dynamic>{'f': '{"a":"Ann"}'},
      );
      expect(pdf, contains('BT'));
    });

    test('multiVariableText draws nothing for a missing variable', () async {
      String pdf = await pdfText(
        <String, dynamic>{
          'type': 'multiVariableText',
          'text': 'Hi {a}',
          'variables': <String>['a'],
        },
        <String, dynamic>{'f': '{}'},
      );
      expect(pdf, isNot(contains('BT')));
    });

    test('circleMark draws only for "true" and a valid style', () async {
      Map<String, dynamic> s = <String, dynamic>{
        'type': 'circleMark',
        'color': '#ff0000',
        'borderWidth': 1,
      };
      Future<bool> draws(Map<String, dynamic> schema, String value) async =>
          (await pdfText(schema, <String, dynamic>{
            'f': value,
          })).contains(' c\n');
      expect(await draws(s, 'true'), isTrue);
      expect(await draws(s, 'false'), isFalse);
      expect(await draws(s, 'True'), isFalse);
      expect(
        await draws(<String, dynamic>{...s, 'color': 'red'}, 'true'),
        isFalse,
      );
      expect(
        await draws(<String, dynamic>{...s, 'borderWidth': 0}, 'true'),
        isFalse,
      );
    });

    test('signature draws the image', () async {
      String png = base64.encode(
        File('test/fixtures/crosscheck/image.png').readAsBytesSync(),
      );
      String pdf = await pdfText(
        <String, dynamic>{'type': 'signature'},
        <String, dynamic>{'f': 'data:image/png;base64,$png'},
      );
      expect(pdf, contains('/Subtype/Image'));
    });
  });
}
