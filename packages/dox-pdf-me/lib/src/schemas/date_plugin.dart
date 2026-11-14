import '../plugin.dart';
import '../text/text_plugin.dart';
import 'date_format.dart';

/// The `date`, `time` and `dateTime` schema types. They format the value
/// and draw it like a `text` schema, centered vertically.
///
/// Props: `format` (date-fns tokens, eg. `yyyy/MM/dd`), `locale` (or the
/// `lang` option, default `en`) and all text props.
class DatePlugin extends SchemaPlugin {
  const DatePlugin._(this.type);

  const DatePlugin.date() : this._('date');

  const DatePlugin.time() : this._('time');

  const DatePlugin.dateTime() : this._('dateTime');

  @override
  final String type;

  /// The default date and time formats of each locale (air-datepicker
  /// 3.6.0, as pdfme uses them). `[dateFormat, timeFormat]`.
  static const Map<String, List<String>> localeFormats = <String, List<String>>{
    'ar': <String>['dd/MM/yyyy', 'hh:mm aa'],
    'bg': <String>['dd.MM.yyyy', 'HH:mm'],
    'ca': <String>['dd/MM/yyyy', 'hh:mm aa'],
    'cs': <String>['dd.MM.yyyy', 'HH:mm'],
    'da': <String>['dd/MM/yyyy', 'HH:mm'],
    'de': <String>['dd.MM.yyyy', 'HH:mm'],
    'el': <String>['dd/MM/yyyy', 'hh:mm aa'],
    'en': <String>['MM/dd/yyyy', 'hh:mm aa'],
    'es': <String>['dd/MM/yyyy', 'hh:mm aa'],
    'eu': <String>['dd/MM/yyyy', 'hh:mm aa'],
    'fi': <String>['dd.MM.yyyy', 'HH:mm'],
    'fr': <String>['dd/MM/yyyy', 'HH:mm'],
    'hr': <String>['dd.MM.yyyy', 'HH:mm'],
    'hu': <String>['yyyy-MM-dd', 'hh:mm aa'],
    'id': <String>['dd/MM/yyyy', 'hh:mm aa'],
    'it': <String>['dd/MM/yyyy', 'HH:mm'],
    'ja': <String>['yyyy/MM/dd', 'HH:mm'],
    'ko': <String>['MM/dd/yyyy', 'hh:mm aa'],
    'nb': <String>['dd.mm.yyyy', 'HH:mm'],
    'nl': <String>['dd-MM-yyyy', 'HH:mm'],
    'pl': <String>['yyyy-MM-dd', 'hh:mm:aa'],
    'pt-Br': <String>['dd/MM/yyyy', 'HH:mm'],
    'pt': <String>['dd/MM/yyyy', 'HH:mm'],
    'ro': <String>['dd.MM.yyyy', 'HH:mm'],
    'ru': <String>['dd.MM.yyyy', 'HH:mm'],
    'si': <String>['yyyy-mm-dd', 'hh:ii aa'],
    'sk': <String>['dd.MM.yyyy', 'HH:mm'],
    'sl': <String>['dd.mm.yyyy', 'hh:ii aa'],
    'sv': <String>['yyyy-MM-dd', 'HH:mm'],
    'th': <String>['dd/MM/yyyy', 'HH:mm'],
    'tr': <String>['dd.MM.yyyy', 'hh:mm aa'],
    'uk': <String>['dd.MM.yyyy', 'HH:mm'],
    'zh': <String>['yyyy-MM-dd', 'HH:mm'],
    'zh-TW': <String>['yyyy-MM-dd', 'HH:mm'],
  };

  static const DateFormatter _formatter = DateFormatter();

  @override
  Future<void> pdf(RenderProps props) async {
    if (props.value.isEmpty) return;
    String text = formatValue(
      props.value,
      props.schema.string('format'),
      _locale(props),
    );
    await const TextPlugin().pdf(
      props.copyWith(
        value: text,
        schema: props.schema.copyWith(<String, dynamic>{
          'verticalAlignment': 'middle',
          'lineHeight': 1,
        }),
      ),
    );
  }

  /// pdfme's `getFmtValue`: [value] in [format], or in the default format
  /// of [locale] when [format] is not valid.
  String formatValue(String value, String? format, String locale) {
    List<String>? formats = localeFormats[locale];
    if (formats == null) throw ArgumentError('Unsupported locale: $locale');
    String pattern = _formatter.isValid(format)
        ? format!.trim()
        : switch (type) {
            'date' => formats[0],
            'time' => 'HH:mm',
            _ => '${formats[0]} ${formats[1]}',
          };
    DateTime date = const DateInput().parse(value, type);
    try {
      return _formatter.format(date, pattern);
    } on FormatException {
      // a default format that date-fns can not read either (si, sl)
      throw RangeError('Invalid format: $pattern');
    }
  }

  String _locale(RenderProps props) {
    String? schemaLocale = props.schema.string('locale');
    if (schemaLocale != null && schemaLocale.isNotEmpty) return schemaLocale;
    String? lang = props.options.lang;
    return lang != null && lang.isNotEmpty ? lang : 'en';
  }
}
