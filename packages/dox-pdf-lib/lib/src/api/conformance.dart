part of 'document.dart';

/// The PDF/X (print) and PDF/A (archive) standards of [setConformance].
enum PDFStandard {
  /// PDF/X-1a:2003. Print. CMYK, gray and spot colors only. No
  /// transparency. PDF 1.4.
  pdfX1a('PDF/X-1a'),

  /// PDF/X-3:2003. Print. Color managed colors allowed. No transparency.
  /// PDF 1.4.
  pdfX3('PDF/X-3'),

  /// PDF/X-4. Print. Transparency allowed. PDF 1.6.
  pdfX4('PDF/X-4'),

  /// PDF/A-1b. Archive. No transparency, no attachments. PDF 1.4.
  pdfA1b('PDF/A-1b'),

  /// PDF/A-2b. Archive. Transparency allowed. PDF 1.7.
  pdfA2b('PDF/A-2b'),

  /// PDF/A-2u. PDF/A-2b, and all text maps to Unicode.
  pdfA2u('PDF/A-2u'),

  /// PDF/A-3b. PDF/A-2b, and any file can be attached.
  pdfA3b('PDF/A-3b'),

  /// PDF/A-3u. PDF/A-3b, and all text maps to Unicode.
  pdfA3u('PDF/A-3u');

  const PDFStandard(this.label);

  /// The name of the standard, eg. `PDF/X-4`.
  final String label;

  bool get isPDFX => index <= PDFStandard.pdfX4.index;
}

/// The `/S` of an output intent.
enum OutputIntentSubtype {
  /// `GTS_PDFX`, for PDF/X.
  pdfX,

  /// `GTS_PDFA1`, for PDF/A (all parts).
  pdfA,
}

/// The kind of a [ConformanceIssue].
enum ConformanceIssueKind {
  /// A font is not in the file (eg. one of the 14 standard fonts).
  fontNotEmbedded,

  /// A font has no ToUnicode map (PDF/A-2u, PDF/A-3u).
  fontNoUnicode,

  /// Opacity, a soft mask (eg. a PNG with alpha), a blend mode or a
  /// transparency group, where the standard does not allow it.
  transparency,

  /// A color space that the standard or the output intent does not allow.
  color,

  /// A page box: no TrimBox or ArtBox, or one outside the MediaBox (PDF/X).
  pageBox,

  /// The file is encrypted.
  encryption,

  /// An attachment the standard does not allow, or one without the data
  /// PDF/A-3 needs.
  embeddedFile,

  /// JavaScript, or an action the standard does not allow.
  action,

  /// No `/ID` in the trailer.
  fileId,

  /// XMP metadata missing or wrong.
  metadata,

  /// The PDF version, or a feature of a newer version.
  version,

  /// The output intent is missing or wrong.
  outputIntent,

  /// A document info entry is missing or wrong (eg. no title in PDF/X).
  info,

  /// An annotation or form field that the standard does not allow.
  annotation,

  /// Anything else (eg. an LZW filter, a transfer function).
  other,
}

/// One problem that [PDFDocumentConformance.checkConformance] found.
class ConformanceIssue {
  const ConformanceIssue({
    required this.kind,
    required this.pageIndex,
    required this.message,
  });

  final ConformanceIssueKind kind;

  /// The page (from 0), or `null` for a problem of the whole document.
  final int? pageIndex;

  /// What is wrong, and what to do, in plain English.
  final String message;

  @override
  String toString() =>
      pageIndex == null ? message : 'page ${pageIndex! + 1}: $message';
}

/// PDF/X and PDF/A. Not in pdf-lib.
extension PDFDocumentConformance on PDFDocument {
  /// Makes [save] write a file of [standard]:
  ///
  /// - now: an output intent with [iccProfile] (the bytes of an ICC
  ///   profile file, eg. sRGB for PDF/A or a CMYK print profile for PDF/X)
  ///   and [outputConditionIdentifier] (eg. `FOGRA39` or
  ///   `sRGB IEC61966-2.1`). It replaces an output intent of the same kind.
  /// - at save: the PDF version, the `/ID`, XMP metadata from the document
  ///   info, and for PDF/X `/Trapped` (False when not set) and
  ///   `/GTS_PDFXVersion`. PDF/X-1a, PDF/X-3 and PDF/A-1 have no object
  ///   streams, so save writes none.
  ///
  /// The XMP is made again at each save, from the document info. The XMP of
  /// a loaded file is replaced, so its extra fields (eg. `dc:rights` or
  /// custom namespaces) are lost. To keep them, read [getXmpMetadata], add
  /// them to [createXmpMetadata], and pass the result to [setXmpMetadata]:
  /// save keeps that XMP as it is.
  ///
  /// The content is up to you: embed all fonts, use the colors and no
  /// transparency where the standard asks. [checkConformance] lists what
  /// is still wrong.
  ///
  /// Throws [PDFLibError] when the profile is not a valid ICC profile, or
  /// does not fit [standard].
  void setConformance(
    PDFStandard standard, {
    required Uint8List iccProfile,
    required String outputConditionIdentifier,
    String? outputCondition,
    String? registryName,
    String? info,
  }) {
    _IntentTexts t = _IntentTexts(
      outputConditionIdentifier,
      outputCondition,
      registryName,
      info,
    );
    check(
      doxPdfConfSet(
        _handle,
        standard.index,
        iccProfile.address,
        iccProfile.length,
        t.bytes.address,
        t.bytes.length,
        t.lengths.address,
      ),
    );
  }

  /// Adds an output intent: how the colors of the file are meant to look
  /// when printed or shown. Most users want [setConformance], which calls
  /// this. With [registryName] set to `http://www.color.org`, the
  /// identifier names a registered print condition.
  void addOutputIntent({
    required OutputIntentSubtype subtype,
    required Uint8List iccProfile,
    required String outputConditionIdentifier,
    String? outputCondition,
    String? registryName,
    String? info,
  }) {
    _IntentTexts t = _IntentTexts(
      outputConditionIdentifier,
      outputCondition,
      registryName,
      info,
    );
    check(
      doxPdfConfAddIntent(
        _handle,
        iccProfile.address,
        iccProfile.length,
        subtype.index,
        t.bytes.address,
        t.bytes.length,
        t.lengths.address,
      ),
    );
  }

  /// Sets your own XMP metadata (the catalog `/Metadata` stream). Save
  /// keeps it, also after [setConformance]: it must then say the same as
  /// the document info, and name the standard.
  void setXmpMetadata(String xml) {
    Uint8List bytes = utf8.encode(xml);
    check(doxPdfConfSetXmp(_handle, bytes.address, bytes.length));
  }

  /// The XMP metadata of the file, or `null` when it has none.
  String? getXmpMetadata() {
    Int64List out = Int64List(1);
    int status = check(doxPdfConfGetXmp(_handle, out.address));
    return status == statusNotFound ? null : takeString(out[0]);
  }

  /// XMP metadata made from the document info (title, author, dates, ...)
  /// and the identification of [standard]. Save writes this after
  /// [setConformance]; use it as a start for [setXmpMetadata].
  String createXmpMetadata({PDFStandard? standard}) {
    Int64List out = Int64List(1);
    check(doxPdfConfMakeXmp(_handle, standard?.index ?? -1, out.address));
    return takeString(out[0]);
  }

  /// What keeps the file, as [save] would write it now, from being a file
  /// of [standard]. Empty when nothing was found.
  ///
  /// It checks what depends on your content: fonts, colors, transparency,
  /// page boxes, annotations, actions, attachments, and the output intent,
  /// XMP, `/ID`, version and info that [setConformance] sets. It is not a
  /// full validator: use veraPDF for PDF/A, and a preflight tool (eg.
  /// Acrobat Preflight) for PDF/X.
  List<ConformanceIssue> checkConformance(PDFStandard standard) {
    Int64List out = Int64List(1);
    check(doxPdfConfCheck(_handle, standard.index, out.address));
    String text = takeString(out[0]);
    return <ConformanceIssue>[
      for (String line in const LineSplitter().convert(text))
        if (line.isNotEmpty) _issue(line),
    ];
  }
}

ConformanceIssue _issue(String line) {
  List<String> parts = line.split('\t');
  int page = int.parse(parts[1]);
  return ConformanceIssue(
    kind: ConformanceIssueKind.values[int.parse(parts[0])],
    pageIndex: page < 0 ? null : page,
    message: parts.sublist(2).join('\t'),
  );
}

/// The 4 texts of an output intent, joined, with their lengths.
class _IntentTexts {
  _IntentTexts(
    String identifier,
    String? condition,
    String? registry,
    String? info,
  ) {
    if (identifier.isEmpty) {
      throw ArgumentError.value(
        identifier,
        'outputConditionIdentifier',
        'must not be empty',
      );
    }
    BytesBuilder all = BytesBuilder(copy: false);
    List<String> texts = <String>[
      identifier,
      condition ?? '',
      registry ?? '',
      info ?? '',
    ];
    for (int i = 0; i < texts.length; i++) {
      Uint8List b = utf8.encode(texts[i]);
      lengths[i] = b.length;
      all.add(b);
    }
    bytes = all.takeBytes();
  }

  final Int64List lengths = Int64List(4);
  late final Uint8List bytes;
}
