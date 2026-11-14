// The quick start of the README. Run: dart run example/main.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';

Future<void> main() async {
  // An A4 page. Sizes and positions are in millimetres.
  Template template = Template(
    basePdf: const BlankPdf(),
    schemas: <List<Schema>>[
      <Schema>[
        const TextSchema(
          name: 'title',
          position: Position(20, 20),
          width: 170,
          height: 15,
          fontSize: 24,
        ),
        BarcodeSchema(
          name: 'link',
          barcodeType: BarcodeType.qrcode,
          position: const Position(20, 40),
        ),
      ],
    ],
  );

  Uint8List pdf = await generate(
    template: template,
    inputs: <Map<String, String>>[
      <String, String>{'title': 'Hello, pdfme!', 'link': 'https://pdfme.com'},
    ],
    plugins: builtInPlugins,
  );
  File('hello.pdf').writeAsBytesSync(pdf);
}
