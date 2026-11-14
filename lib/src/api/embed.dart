part of 'document.dart';

/// An area of a page, like pdf-lib's `PageBoundingBox`.
typedef PageBoundingBox = ({
  double left,
  double bottom,
  double right,
  double top,
});

/// A page embedded in [doc] as a Form XObject, like pdf-lib's
/// `PDFEmbeddedPage`. Draw it with [PDFPageDrawPage.drawPage].
class PDFEmbeddedPage {
  PDFEmbeddedPage._(this.doc, this.ref, this.width, this.height);

  /// The document that holds the XObject.
  final PDFDocument doc;

  /// The object number of the XObject, `number << 16 | generation`.
  final int ref;

  final double width;
  final double height;

  /// The size after scaling by [factor].
  ({double width, double height}) scale(double factor) =>
      (width: width * factor, height: height * factor);

  ({double width, double height}) size() => scale(1);

  /// Does nothing: the page is embedded at once. pdf-lib embeds at save.
  Future<void> embed() async {}
}

/// Embedding pages, like pdf-lib.
extension PDFDocumentEmbed on PDFDocument {
  /// Embeds the pages at [indices] of [pdf]: PDF bytes, a base64 string or
  /// data URI, or a [PDFDocument].
  Future<List<PDFEmbeddedPage>> embedPdf(
    Object pdf, [
    List<int> indices = const <int>[0],
  ]) async {
    if (pdf is PDFDocument) {
      return embedPages(<PDFPage>[for (int i in indices) pdf.getPage(i)]);
    }
    PDFDocument src = await PDFDocument.load(_bytesOf(pdf, 'pdf'));
    try {
      return await embedPages(<PDFPage>[for (int i in indices) src.getPage(i)]);
    } finally {
      src.dispose();
    }
  }

  /// Embeds [page]. [boundingBox] clips a part of it (default: the whole
  /// media box). [transformationMatrix] (`[a, b, c, d, e, f]`) is applied
  /// wherever the page is drawn.
  Future<PDFEmbeddedPage> embedPage(
    PDFPage page, [
    PageBoundingBox? boundingBox,
    List<double>? transformationMatrix,
  ]) async {
    List<PDFEmbeddedPage> pages = await embedPages(
      <PDFPage>[page],
      <PageBoundingBox?>[boundingBox],
      <List<double>?>[transformationMatrix],
    );
    return pages.single;
  }

  /// Embeds [pages], which must all be from one document. The same source
  /// page with the same box and matrix gives the same XObject again.
  Future<List<PDFEmbeddedPage>> embedPages(
    List<PDFPage> pages, [
    List<PageBoundingBox?> boundingBoxes = const <PageBoundingBox?>[],
    List<List<double>?> transformationMatrices = const <List<double>?>[],
  ]) async {
    if (pages.isEmpty) return <PDFEmbeddedPage>[];
    PDFDocument src = pages.first.doc;
    for (PDFPage p in pages) {
      if (p.doc != src) throw PageEmbeddingMismatchedContextError();
    }
    int n = pages.length;
    Int64List refs = Int64List.fromList(<int>[for (PDFPage p in pages) p.ref]);
    Float64List boxes = Float64List(n * 4)..fillRange(0, n * 4, double.nan);
    Float64List matrices = Float64List(n * 6)..fillRange(0, n * 6, double.nan);
    for (int i = 0; i < n; i++) {
      PageBoundingBox? b = i < boundingBoxes.length ? boundingBoxes[i] : null;
      if (b != null) {
        if (!(b.left.isFinite &&
            b.bottom.isFinite &&
            b.right.isFinite &&
            b.top.isFinite)) {
          throw ArgumentError.value(b, 'boundingBox', 'must be finite numbers');
        }
        boxes.setAll(i * 4, <double>[b.left, b.bottom, b.right, b.top]);
      }
      List<double>? m = i < transformationMatrices.length
          ? transformationMatrices[i]
          : null;
      if (m != null) {
        if (m.length != 6 || !m.every((double v) => v.isFinite)) {
          throw ArgumentError.value(
            m,
            'transformationMatrix',
            'needs 6 finite numbers',
          );
        }
        matrices.setAll(i * 6, m);
      }
    }
    Int64List outRefs = Int64List(n);
    Float64List outSizes = Float64List(n * 2);
    check(
      doxPdfEmbedPages(
        _handle,
        src._handle,
        refs.address,
        n,
        boxes.address,
        matrices.address,
        outRefs.address,
        outSizes.address,
      ),
    );
    return <PDFEmbeddedPage>[
      for (int i = 0; i < n; i++)
        PDFEmbeddedPage._(
          this,
          outRefs[i],
          outSizes[i * 2],
          outSizes[i * 2 + 1],
        ),
    ];
  }
}

/// pdf-lib's `page.drawPage`.
extension PDFPageDrawPage on PDFPage {
  /// Draws [embeddedPage] on this page. [width] and [height] win over
  /// [xScale] and [yScale].
  void drawPage(
    PDFEmbeddedPage embeddedPage, {
    double? x,
    double? y,
    double? xScale,
    double? yScale,
    double? width,
    double? height,
    Rotation? rotate,
    Rotation? xSkew,
    Rotation? ySkew,
    double? opacity,
    BlendMode? blendMode,
  }) {
    if (embeddedPage.doc != doc) {
      throw ArgumentError.value(
        embeddedPage,
        'embeddedPage',
        'is from another document; embed it into this one',
      );
    }
    if (opacity != null && (opacity < 0 || opacity > 1)) {
      throw RangeError.range(opacity, 0, 1, 'opacity');
    }
    double sx = width != null ? width / embeddedPage.width : xScale ?? 1;
    double sy = height != null ? height / embeddedPage.height : yScale ?? 1;
    Float64List values = Float64List.fromList(<double>[
      // the page position of moveTo, like pdf-lib
      x ?? getX(),
      y ?? getY(),
      sx,
      sy,
      toRadians(rotate ?? degrees(0)),
      toRadians(xSkew ?? degrees(0)),
      toRadians(ySkew ?? degrees(0)),
      opacity ?? double.nan,
    ]);
    check(
      doxPdfDrawPage(
        doc._handle,
        ref,
        embeddedPage.ref,
        values.address,
        blendMode?.index ?? -1,
      ),
    );
  }
}
