// The quick start of the README. Run: dart run example/main.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';

Future<void> main() async {
  // A template from the pdfme designer (JSON). Sizes are in millimetres.
  Map<String, dynamic> template = <String, dynamic>{
    'basePdf': <String, dynamic>{
      'width': 210,
      'height': 297,
      'padding': <int>[10, 10, 10, 10],
    },
    'schemas': <List<Map<String, dynamic>>>[
      <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'title',
          'type': 'text',
          'position': <String, num>{'x': 20, 'y': 20},
          'width': 170,
          'height': 15,
          'fontSize': 24,
        },
        <String, dynamic>{
          'name': 'link',
          'type': 'qrcode',
          'position': <String, num>{'x': 20, 'y': 40},
          'width': 30,
          'height': 30,
        },
      ],
    ],
  };

  List<Map<String, dynamic>> inputs = <Map<String, dynamic>>[
    <String, dynamic>{'title': 'Hello, pdfme!', 'link': 'https://pdfme.com'},
  ];

  Uint8List pdf = await generate(
    template: template,
    inputs: inputs,
    plugins: builtInPlugins,
  );
  File('hello.pdf').writeAsBytesSync(pdf);
}
