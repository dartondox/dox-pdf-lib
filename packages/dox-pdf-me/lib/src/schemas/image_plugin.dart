import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dox_pdf_lib/dox_pdf_lib.dart';

import '../constants.dart';
import '../layout.dart';
import '../plugin.dart';
import '../schema.dart';

/// The `image` schema type. The value is a PNG or JPEG data URL (or plain
/// base64). Props: `objectFit` (`contain` default, `cover`) and
/// `objectPosition` (eg. `left top`, default `center center`).
class ImagePlugin extends SchemaPlugin {
  const ImagePlugin();

  static const List<String> positions = <String>[
    'left top',
    'center top',
    'right top',
    'left center',
    'center center',
    'right center',
    'left bottom',
    'center bottom',
    'right bottom',
  ];

  @override
  String get type => 'image';

  @override
  Future<void> pdf(RenderProps props) async {
    String value = props.value;
    if (value.isEmpty) return;
    Schema schema = props.schema;
    PDFImage image = await _embed(props, value);
    ImageFit fit = ImageFit.of(schema, px2mm(image.width), px2mm(image.height));
    Schema fitted = schema.copyWith(<String, dynamic>{
      'width': fit.width,
      'height': fit.height,
      'position': <String, double>{
        'x': schema.x + fit.offsetX,
        'y': schema.y + fit.offsetY,
      },
    });
    double pageHeight = props.page.getHeight();
    PdfLayout box = PdfLayout.of(fitted, pageHeight);
    if (fit.cover) _clip(props.page, schema, pageHeight);
    props.page.drawImage(
      image,
      x: box.x,
      y: box.y,
      width: box.width,
      height: box.height,
      rotate: degrees(box.rotate),
      opacity: box.opacity,
    );
    if (fit.cover) props.page.pushOperators(<PDFOperator>[popGraphicsState()]);
  }

  /// Embeds the image once per document, like pdfme's image cache.
  Future<PDFImage> _embed(RenderProps props, String value) async {
    Object? cached = props.cache['image:$value'];
    if (cached is PDFImage) return cached;
    int marker = value.indexOf(';base64,');
    Uint8List bytes = base64.decode(
      marker >= 0 ? value.substring(marker + 8) : value,
    );
    bool png =
        bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47;
    PDFImage image = png
        ? await props.doc.embedPng(bytes)
        : await props.doc.embedJpg(bytes);
    props.cache['image:$value'] = image;
    return image;
  }

  /// `cover`: clip to the schema box (turned with the schema).
  void _clip(PDFPage page, Schema schema, double pageHeight) {
    PdfLayout plain = PdfLayout.of(
      schema,
      pageHeight,
      applyRotateTranslate: false,
    );
    double x = plain.x;
    double y = plain.y;
    double w = plain.width;
    double h = plain.height;
    Point center = (x: x + w / 2, y: y + h / 2);
    List<Point> corners = <Point>[
      for (Point p in <Point>[
        (x: x, y: y),
        (x: x, y: y + h),
        (x: x + w, y: y + h),
        (x: x + w, y: y),
      ])
        rotatePoint(p, center, plain.rotate),
    ];
    page.pushOperators(<PDFOperator>[
      pushGraphicsState(),
      moveTo(corners[0].x, corners[0].y),
      for (Point p in corners.skip(1)) lineTo(p.x, p.y),
      closePath(),
      clip(),
      endPath(),
    ]);
  }
}

/// pdfme's `getImageFitLayout`, in millimetres.
class ImageFit {
  const ImageFit({
    required this.cover,
    required this.width,
    required this.height,
    required this.offsetX,
    required this.offsetY,
  });

  factory ImageFit.of(Schema schema, double imageWidth, double imageHeight) {
    bool cover = schema.string('objectFit') == 'cover';
    String? asked = schema.string('objectPosition');
    String position = !cover && ImagePlugin.positions.contains(asked)
        ? asked!
        : 'center center';
    double boxW = schema.width;
    double boxH = schema.height;
    double sx = boxW / imageWidth;
    double sy = boxH / imageHeight;
    double scale = cover ? math.max(sx, sy) : math.min(sx, sy);
    double w = imageWidth * scale;
    double h = imageHeight * scale;
    List<String> parts = position.split(' ');
    return ImageFit(
      cover: cover,
      width: w,
      height: h,
      offsetX: _offset(boxW - w, parts[0]),
      offsetY: _offset(boxH - h, parts[1]),
    );
  }

  final bool cover;
  final double width;
  final double height;
  final double offsetX;
  final double offsetY;

  static double _offset(double space, String position) => switch (position) {
    'right' || 'bottom' => space,
    'center' => space / 2,
    _ => 0,
  };
}
