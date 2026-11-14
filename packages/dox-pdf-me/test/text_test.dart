// The text layout math, with the numbers of pdfme's own tests
// (packages/schemas/__tests__/text.test.ts). Those tests measure with
// pdfme's default font, Roboto, which is also our default font.
import 'dart:typed_data';

import 'package:dox_pdf_me/dox_pdf_me.dart';
import 'package:dox_pdf_me/src/fonts/font_metrics.dart';
import 'package:dox_pdf_me/src/text/text_box.dart';
import 'package:dox_pdf_me/src/text/text_measure.dart';
import 'package:dox_pdf_me/src/text/wrap.dart';
import 'package:test/test.dart';

void main() {
  late PDFDocument doc;
  late TextMeasure roboto;

  setUpAll(() async {
    doc = await PDFDocument.create();
    FontStore store = FontStore(doc, null);
    roboto = TextMeasure(await store.embed('Roboto'), store.metrics('Roboto'));
  });

  tearDownAll(() => doc.dispose());

  /// pdfme's getTextSchema(): 50 x 20 mm, fontSize 14, characterSpacing 1.
  double dynamicSize(
    String value,
    double min,
    double max,
    String fit, {
    double width = 50,
    double height = 20,
    double fontSize = 14,
  }) => DynamicFontSize(min: min, max: max, fit: fit).resolveSize(
    measure: roboto,
    value: value,
    startSize: fontSize,
    boxWidth: width,
    boxHeight: height,
    characterSpacing: 1,
    lineHeight: 1,
  );

  const String value = 'test with a length string\n and a new line';

  group('dynamic font size (pdfme tests)', () {
    test('vertical fit', () {
      expect(dynamicSize(value, 10, 30, 'vertical'), 19.25);
    });

    test('horizontal fit', () {
      expect(dynamicSize(value, 10, 30, 'horizontal'), 11.25);
    });

    test('the start size does not change the result', () {
      expect(dynamicSize(value, 10, 30, 'vertical', fontSize: 2), 19.25);
      expect(dynamicSize(value, 10, 30, 'vertical', fontSize: 40), 19.25);
      expect(dynamicSize(value, 10, 30, 'vertical', fontSize: 18), 19.25);
      expect(dynamicSize(value, 10, 30, 'horizontal', fontSize: 36), 11.25);
    });

    test('too big content gives the min size', () {
      expect(dynamicSize(value, 10, 30, 'vertical', width: 10), 10);
    });

    test('too small content gives the max size', () {
      expect(
        dynamicSize(value, 10, 30, 'vertical', width: 1000, height: 200),
        30,
      );
    });

    test('max below min keeps the start size', () {
      expect(dynamicSize(value, 11, 10, 'vertical'), 14);
    });

    test('never below 0', () {
      expect(
        dynamicSize(
          'a very \nlong \nmulti-line \nstring\nto',
          -5,
          10,
          'vertical',
          width: 4,
          height: 1,
        ),
        greaterThan(0),
      );
    });
  });

  group('line splitting with Roboto (pdfme tests)', () {
    List<String> lines(String text) => <String>[
      for (WrapLine l in roboto.wrap(text, 12, 1, 40)) l.text,
    ];

    test('short text stays on one line', () {
      expect(lines('short'), <String>['short']);
    });

    test('long text breaks at spaces', () {
      expect(lines('this will wrap'), <String>['this', 'will', 'wrap']);
    });

    test('a long word breaks in the middle', () {
      expect(lines('thiswillbecut'), <String>['thiswi', 'llbecu', 't']);
    });
  });

  group('font metrics', () {
    test('descent in pt (pdfme tests)', () {
      FontMetrics m(double descent, int upm) => FontMetrics(
        unitsPerEm: upm,
        ascent: 800,
        descent: descent,
        bboxMinY: 0,
        bboxMaxY: 0,
      );
      expect(m(-400, 1000).descentAtSize(12), -4.800000000000001);
      expect(m(54, 1000).descentAtSize(20), 1.08);
      expect(m(-512, 2048).descentAtSize(54), -13.5);
    });

    test('Roboto: hhea values and the height above the baseline', () {
      FontMetrics m = roboto.metrics;
      expect(m.unitsPerEm, 2048);
      expect(m.ascent, 1900);
      expect(m.descent, -500);
      expect(m.heightAtSize(10), closeTo(1900 / 2048 * 10, 1e-9));
    });

    test('width adds the character spacing between code units', () {
      double plain = roboto.width('abc', 10, 0);
      expect(roboto.width('abc', 10, 2), plain + 4);
      // like pdfme: an empty text gives minus the spacing
      expect(roboto.width('', 10, 2), -2);
      expect(roboto.measureForWrap('', 10, 2), 0);
    });

    test('no kerning: AV is the sum of A and V', () {
      expect(
        roboto.width('AV', 20, 0),
        closeTo(roboto.width('A', 20, 0) + roboto.width('V', 20, 0), 1e-9),
      );
    });

    test('parses a font file', () {
      Uint8List data = FontStore.defaultFont.data;
      expect(FontMetrics.parse(data).unitsPerEm, 2048);
    });
  });

  group('box area', () {
    test('border and padding are taken off, never below 0', () {
      BoxArea a = BoxArea.of(
        Schema(<String, dynamic>{
          'width': 50,
          'height': 20,
          'borderWidth': <String, num>{'left': 1, 'right': 2, 'top': 3},
          'padding': <String, num>{'left': 4, 'bottom': 5},
        }),
      );
      expect(a.width, 43);
      expect(a.height, 12);
      expect(a.leftInset, 5);
      expect(a.bottomInset, 5);
      expect(
        BoxArea.of(
          Schema(<String, dynamic>{
            'width': 2,
            'height': 2,
            'padding': <String, num>{'left': 4, 'top': 4},
          }),
        ).width,
        0,
      );
    });
  });
}
