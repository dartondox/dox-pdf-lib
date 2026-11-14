import 'dart:convert';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import '../ffi/attachment_bindings.dart';
import '../ffi/document_bindings.dart';
import '../ffi/draw_bindings.dart';
import '../ffi/embed_bindings.dart';
import '../ffi/ffi_util.dart';
import '../ffi/font_bindings.dart';
import '../ffi/form_bindings.dart';
import '../ffi/image_bindings.dart';
import '../ffi/metadata_bindings.dart';
import '../ffi/page_bindings.dart';
import 'colors.dart';
import 'errors.dart';
import 'operators.dart' show LineCapStyle, PDFHexString, PDFOperator;
import 'rotations.dart';
import 'sizes.dart';

// One part per feature area, so a new area is one new line here.
part 'attachment.dart';
part 'draw.dart';
part 'embed.dart';
part 'font.dart';
part 'form.dart';
part 'image.dart';
part 'metadata.dart';
part 'page.dart';

/// A PDF document, like pdf-lib's `PDFDocument`.
///
/// The document lives in native memory. It is freed when this object is
/// garbage collected, or at once with [dispose].
class PDFDocument implements Finalizable {
  PDFDocument._(int handle) : _handle = Pointer<Void>.fromAddress(handle) {
    _finalizer.attach(this, _handle, detach: this);
  }

  static final NativeFinalizer _finalizer = NativeFinalizer(docFreePointer);

  Pointer<Void> _handle;

  /// The pages, in order. Kept up to date by insert and remove, so adding
  /// many pages does not read the page tree again each time.
  List<PDFPage>? _pages;
  final Map<int, PDFPage> _pageMap = <int, PDFPage>{};

  /// A new, empty document.
  static Future<PDFDocument> create({bool updateMetadata = true}) async {
    Uint8List now = _nowBytes();
    Int64List out = Int64List(1);
    check(
      doxPdfCreate(
        updateMetadata ? loadUpdateMetadata : 0,
        now.address,
        now.length,
        out.address,
      ),
    );
    return PDFDocument._(out[0]);
  }

  /// Reads a PDF. Throws [PDFParsingError] for a broken one.
  ///
  /// An encrypted file throws [EncryptedPDFError], unless [ignoreEncryption]
  /// is true. Then, unlike pdf-lib:
  /// - A file with only an owner password (it opens with no password) is
  ///   decrypted. Its text and info can be read, [isEncrypted] stays true,
  ///   and [save] writes an unencrypted file.
  /// - A file with a user password throws [PDFParsingError]: its objects
  ///   can not be read without the password.
  static Future<PDFDocument> load(
    Uint8List pdf, {
    bool ignoreEncryption = false,
    bool updateMetadata = true,
  }) async {
    int flags =
        (ignoreEncryption ? loadIgnoreEncryption : 0) |
        (updateMetadata ? loadUpdateMetadata : 0);
    Uint8List now = _nowBytes();
    Int64List out = Int64List(1);
    int id = Pending.nextId();
    int status = check(
      doxPdfLoad(
        pdf.address,
        pdf.length,
        flags,
        now.address,
        now.length,
        out.address,
        Pending.callback,
        id,
      ),
    );
    int handle = status == statusPending ? await Pending.wait(id) : out[0];
    return PDFDocument._(handle);
  }

  static Uint8List _nowBytes() => ascii.encode(_formatDate(DateTime.now()));

  /// Frees the native document now. The object can not be used after.
  void dispose() {
    if (_handle == nullptr) return;
    _finalizer.detach(this);
    docFree(_handle);
    _handle = nullptr;
    _pages = null;
    _pageMap.clear();
  }

  /// True when the source file was encrypted, like pdf-lib.
  bool get isEncrypted => check(doxPdfIsEncrypted(_handle)) == 1;

  /// The file as bytes. Defaults as in pdf-lib.
  ///
  /// With [updateFieldAppearances], the field appearances are updated
  /// first, when the form was used ([PDFDocumentForm.getForm]).
  Future<Uint8List> save({
    bool useObjectStreams = true,
    bool addDefaultPage = true,
    bool updateFieldAppearances = true,
  }) async {
    int flags =
        (useObjectStreams ? saveObjectStreams : 0) |
        (addDefaultPage ? saveAddDefaultPage : 0) |
        (updateFieldAppearances ? saveUpdateFieldAppearances : 0);
    Int64List out = Int64List(1);
    int id = Pending.nextId();
    int status = check(
      doxPdfSave(_handle, flags, out.address, Pending.callback, id),
    );
    // addDefaultPage may have added a page
    _pages = null;
    int bytes = status == statusPending ? await Pending.wait(id) : out[0];
    return takeBytes(bytes);
  }

  /// [save] as base64, or as a `data:` URI when [dataUri] is true.
  Future<String> saveAsBase64({
    bool dataUri = false,
    bool useObjectStreams = true,
    bool addDefaultPage = true,
    bool updateFieldAppearances = true,
  }) async {
    String base64 = base64Encode(
      await save(
        useObjectStreams: useObjectStreams,
        addDefaultPage: addDefaultPage,
        updateFieldAppearances: updateFieldAppearances,
      ),
    );
    return dataUri ? 'data:application/pdf;base64,$base64' : base64;
  }

  PDFPage _page(int ref) =>
      _pageMap.putIfAbsent(ref, () => PDFPage._(this, ref));

  /// All pages, in order.
  /// A copy, like pdf-lib's fresh array: it does not change when pages are
  /// added or removed later.
  List<PDFPage> getPages() => List<PDFPage>.unmodifiable(_pageList());

  List<PDFPage> _pageList() {
    List<PDFPage>? pages = _pages;
    if (pages != null) return pages;
    Int64List count = Int64List(1);
    Int64List refs = Int64List(64);
    check(doxPdfGetPages(_handle, refs.address, refs.length, count.address));
    if (count[0] > refs.length) {
      refs = Int64List(count[0]);
      check(doxPdfGetPages(_handle, refs.address, refs.length, count.address));
    }
    return _pages = <PDFPage>[
      for (int i = 0; i < count[0]; i++) _page(refs[i]),
    ];
  }

  PDFPage getPage(int index) {
    List<PDFPage> pages = _pageList();
    RangeError.checkValueInInterval(index, 0, pages.length - 1, 'index');
    return pages[index];
  }

  int getPageCount() => _pageList().length;

  List<int> getPageIndices() =>
      List<int>.generate(getPageCount(), (int i) => i);

  /// Adds a page at the end: a new A4 page, a new page of `[width, height]`,
  /// or a [PDFPage] from [copyPages].
  PDFPage addPage([Object? page]) => insertPage(getPageCount(), page);

  /// Like [addPage], at [index].
  PDFPage insertPage(int index, [Object? page]) {
    int ref = 0;
    List<double> size = PageSizes.A4;
    if (page is PDFPage) {
      if (page.doc != this) throw ForeignPageError();
      ref = page.ref;
    } else if (page is List<num> && page.length == 2) {
      size = <double>[page[0].toDouble(), page[1].toDouble()];
      _finite(size[0], 'width');
      _finite(size[1], 'height');
    } else if (page != null) {
      throw ArgumentError.value(
        page,
        'page',
        'must be a PDFPage or [width, height]',
      );
    }
    List<PDFPage> pages = _pageList();
    _checkIndex(index, pages.length);
    // -1 tells Rust to append to the root /Kids, with no walk over the tree
    int at = index == pages.length ? -1 : index;
    Int64List out = Int64List(1);
    check(doxPdfInsertPage(_handle, at, ref, size[0], size[1], out.address));
    PDFPage added = _page(out[0]);
    pages.insert(index, added);
    return added;
  }

  /// Takes the page at [index] out of the document.
  void removePage(int index) {
    int count = _pageList().length;
    if (count == 0) throw RemovePageFromEmptyDocumentError();
    _checkIndex(index, count - 1);
    check(doxPdfRemovePage(_handle, index));
    _pages?.removeAt(index);
  }

  static void _checkIndex(int index, int max) {
    if (index < 0 || index > max) {
      throw RangeError(
        '`index` must be at least 0 and at most $max, but was actually '
        '$index',
      );
    }
  }

  /// Copies the pages at [indices] of [srcDoc] into this document, with
  /// everything they use. Add them with [addPage] or [insertPage].
  Future<List<PDFPage>> copyPages(PDFDocument srcDoc, List<int> indices) async {
    Int64List input = Int64List.fromList(indices);
    Int64List out = Int64List(indices.length);
    check(
      doxPdfCopyPages(
        _handle,
        srcDoc._handle,
        input.address,
        input.length,
        out.address,
      ),
    );
    return <PDFPage>[for (int ref in out) _page(ref)];
  }
}
