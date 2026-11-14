part of 'document.dart';

/// The text of a PDF date, like pdf-lib's `PDFString.fromDate` (UTC).
String _formatDate(DateTime date) {
  DateTime d = date.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'D:${d.year.toString().padLeft(4, '0')}${two(d.month)}'
      '${two(d.day)}${two(d.hour)}${two(d.minute)}${two(d.second)}Z';
}

final RegExp _dateRegex = RegExp(
  r"^D:(\d\d\d\d)(\d\d)?(\d\d)?(\d\d)?(\d\d)?(\d\d)?([+\-Z])?(\d\d)?'?(\d\d)?'?$",
);

/// pdf-lib's `parseDate`.
DateTime _parseDate(String text) {
  RegExpMatch? m = _dateRegex.firstMatch(text);
  if (m == null) throw InvalidPDFDateStringError(text);
  int part(int i, int fallback) => m[i] == null ? fallback : int.parse(m[i]!);
  DateTime utc = DateTime.utc(
    part(1, 0),
    part(2, 1),
    part(3, 1),
    part(4, 0),
    part(5, 0),
    part(6, 0),
  );
  String sign = m[7] ?? 'Z';
  if (sign == 'Z') return utc;
  Duration offset = Duration(hours: part(8, 0), minutes: part(9, 0));
  return sign == '+' ? utc.subtract(offset) : utc.add(offset);
}

/// The `/Trapped` value of the document info: has the file been trapped
/// for print? PDF/X needs [yes] or [no].
enum Trapped {
  yes('True'),
  no('False'),
  unknown('Unknown');

  const Trapped(this.value);

  /// The PDF name.
  final String value;
}

/// The Info keys that have their own getter and setter. The custom
/// metadata calls do not take them.
const Set<String> _standardInfoKeys = <String>{
  'Title',
  'Author',
  'Subject',
  'Keywords',
  'Creator',
  'Producer',
  'CreationDate',
  'ModDate',
  'Trapped',
};

/// Title, author and the other document info, like pdf-lib.
extension PDFDocumentMetadata on PDFDocument {
  String? _get(String key) {
    Uint8List k = ascii.encode(key);
    Int64List out = Int64List(1);
    int status = check(
      doxPdfMetaGet(_handle, k.address, k.length, out.address),
    );
    return status == statusNotFound ? null : takeString(out[0]);
  }

  void _set(String key, String value, int mode) {
    Uint8List k = ascii.encode(key);
    Uint8List v = utf8.encode(value);
    check(
      doxPdfMetaSet(_handle, k.address, k.length, v.address, v.length, mode),
    );
  }

  String? getTitle() => _get('Title');
  String? getAuthor() => _get('Author');
  String? getSubject() => _get('Subject');
  String? getKeywords() => _get('Keywords');
  String? getCreator() => _get('Creator');
  String? getProducer() => _get('Producer');

  /// The catalog `/Lang`. pdf-lib has only the setter.
  String? getLanguage() => _get('Lang');

  DateTime? getCreationDate() {
    String? text = _get('CreationDate');
    return text == null ? null : _parseDate(text);
  }

  DateTime? getModificationDate() {
    String? text = _get('ModDate');
    return text == null ? null : _parseDate(text);
  }

  /// With [showInWindowTitleBar], readers show the title, not the file name.
  void setTitle(String title, {bool showInWindowTitleBar = false}) =>
      _set('Title', title, showInWindowTitleBar ? metaShowTitle : metaText);

  void setAuthor(String author) => _set('Author', author, metaText);
  void setSubject(String subject) => _set('Subject', subject, metaText);

  /// Stored as one text, joined with spaces, like pdf-lib.
  void setKeywords(List<String> keywords) =>
      _set('Keywords', keywords.join(' '), metaText);

  void setCreator(String creator) => _set('Creator', creator, metaText);
  void setProducer(String producer) => _set('Producer', producer, metaText);
  void setLanguage(String language) => _set('Lang', language, metaLiteral);

  void setCreationDate(DateTime creationDate) =>
      _set('CreationDate', _formatDate(creationDate), metaLiteral);

  void setModificationDate(DateTime modificationDate) =>
      _set('ModDate', _formatDate(modificationDate), metaLiteral);

  /// Sets `/Trapped`. `null` removes it. pdf-lib has no such call.
  void setTrapped(Trapped? trapped) {
    if (trapped == null) {
      _remove('Trapped');
    } else {
      _set('Trapped', trapped.value, metaName);
    }
  }

  /// The `/Trapped` value, or `null` when it is not set or not known.
  Trapped? getTrapped() {
    String? value = _get('Trapped');
    for (Trapped t in Trapped.values) {
      if (t.value == value) return t;
    }
    return null;
  }

  /// Sets a custom text entry of the document info, eg. `Client`. The
  /// standard keys (`Title`, `Author`, ...) have their own setters and are
  /// not allowed here.
  void setCustomMetadata(String key, String value) =>
      _set(_customKey(key), value, metaText);

  /// A custom text entry, or `null` when it is not set.
  String? getCustomMetadata(String key) => _get(_customKey(key));

  /// The keys of the custom entries (all keys but the standard ones).
  List<String> getCustomMetadataKeys() {
    Int64List out = Int64List(1);
    check(doxPdfMetaKeys(_handle, out.address));
    List<String> keys = latin1.decode(takeBytes(out[0])).split('\u0000')
      ..removeLast();
    return <String>[
      for (String k in keys)
        if (!_standardInfoKeys.contains(k)) k,
    ];
  }

  /// Removes a custom entry. Nothing happens when it is not set.
  void removeCustomMetadata(String key) => _remove(_customKey(key));

  void _remove(String key) {
    Uint8List k = ascii.encode(key);
    check(doxPdfMetaRemove(_handle, k.address, k.length));
  }
}

/// A key for the custom metadata calls: a PDF name without spaces or
/// delimiters, and not a standard key.
String _customKey(String key) {
  if (_standardInfoKeys.contains(key)) {
    throw ArgumentError.value(
      key,
      'key',
      'is a standard key; use its own setter (eg. setTitle) instead',
    );
  }
  if (!RegExp(r'^[!-~]+$').hasMatch(key) ||
      RegExp(r'[/()<>\[\]{}%#]').hasMatch(key)) {
    throw ArgumentError.value(
      key,
      'key',
      'must be ASCII letters, digits or marks, with no spaces and none of '
          '/()<>[]{}%#',
    );
  }
  return key;
}
