/// A small date-fns compatible formatter (date-fns v4 tokens), for the
/// date, time and dateTime schemas.
///
/// Supported tokens: `yyyy yy y`, `M MM MMM MMMM`, `d dd`, `E..EEE EEEE`,
/// `i ii`, `H HH`, `h hh`, `m mm`, `s ss`, `S..`, `a aa aaa aaaa`, and text in
/// single quotes. Month and day names are English. Other date-fns tokens
/// make the format invalid, so the schema uses its default format.
class DateFormatter {
  const DateFormatter();

  static const List<String> _months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static const List<String> _days = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  /// True when [pattern] only has supported tokens (pdfme's
  /// `isValidDateFormat`).
  bool isValid(String? pattern) {
    if (pattern == null) return false;
    String p = pattern.trim();
    if (p.isEmpty || p == 'undefined') return false;
    try {
      format(DateTime.fromMillisecondsSinceEpoch(0), p);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Formats [date]. Throws a [FormatException] for an unknown token.
  String format(DateTime date, String pattern) {
    StringBuffer out = StringBuffer();
    int i = 0;
    while (i < pattern.length) {
      String c = pattern[i];
      if (c == "'") {
        i = _quoted(pattern, i, out);
        continue;
      }
      int end = i;
      while (end < pattern.length && pattern[end] == c) {
        end++;
      }
      String token = pattern.substring(i, end);
      out.write(_isLatin(c) ? _token(date, token) : token);
      i = end;
    }
    return out.toString();
  }

  /// Writes the text between quotes; `''` is one quote.
  int _quoted(String pattern, int start, StringBuffer out) {
    if (start + 1 < pattern.length && pattern[start + 1] == "'") {
      out.write("'");
      return start + 2;
    }
    int i = start + 1;
    while (i < pattern.length) {
      if (pattern[i] == "'") {
        if (i + 1 < pattern.length && pattern[i + 1] == "'") {
          out.write("'");
          i += 2;
          continue;
        }
        return i + 1;
      }
      out.write(pattern[i]);
      i++;
    }
    return i;
  }

  static bool _isLatin(String c) {
    int u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) || (u >= 97 && u <= 122);
  }

  String _token(DateTime d, String t) {
    int n = t.length;
    String pad(int v, int width) => v.toString().padLeft(width, '0');
    int hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    switch (t[0]) {
      case 'y':
        return n == 2 ? pad(d.year % 100, 2) : pad(d.year, n);
      case 'M':
        return switch (n) {
          1 => '${d.month}',
          2 => pad(d.month, 2),
          3 => _months[d.month - 1].substring(0, 3),
          4 => _months[d.month - 1],
          _ => _months[d.month - 1][0],
        };
      case 'd':
        return pad(d.day, n);
      case 'E':
        String day = _days[d.weekday - 1];
        return n <= 3 ? day.substring(0, 3) : (n == 4 ? day : day[0]);
      case 'i':
        // ISO day of the week, Monday is 1
        return n <= 2 ? pad(d.weekday, n) : _token(d, 'E' * (n - 1));
      case 'H':
        return pad(d.hour, n);
      case 'h':
        return pad(hour12, n);
      case 'm':
        return pad(d.minute, n);
      case 's':
        return pad(d.second, n);
      case 'S':
        return pad(d.millisecond, 3).padRight(n, '0').substring(0, n);
      case 'a':
        String ampm = d.hour < 12 ? 'AM' : 'PM';
        return switch (n) {
          1 || 2 => ampm,
          3 => ampm.toLowerCase(),
          4 => d.hour < 12 ? 'a.m.' : 'p.m.',
          _ => ampm[0].toLowerCase(),
        };
    }
    throw FormatException('Unsupported date format token: $t');
  }
}

/// Reads input values like pdfme's `strDateToDate` (JavaScript `Date`
/// rules for the common forms).
class DateInput {
  const DateInput();

  static final RegExp _slashDateTime = RegExp(
    r'^(\d{4})/(\d{1,2})/(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
  );
  static final RegExp _isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
  static final RegExp _timeWithDate = RegExp(
    r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$',
  );

  /// The date of [value] for a schema of [type] (`date`, `time` or
  /// `dateTime`). Throws a [RangeError] for an invalid date, like
  /// date-fns.
  DateTime parse(String value, String type) {
    if (value.trim().isEmpty) return DateTime.now();
    if (type == 'time') {
      String iso = _timeWithDate.hasMatch(value)
          ? value.replaceAll('/', '-').replaceFirst(' ', 'T')
          : '2021-01-01T$value';
      return _check(DateTime.tryParse(iso), value);
    }
    RegExpMatch? slash = _slashDateTime.firstMatch(value);
    if (slash != null) {
      int g(int i) => int.parse(slash.group(i) ?? '0');
      return DateTime(g(1), g(2), g(3), g(4), g(5), g(6));
    }
    RegExpMatch? iso = _isoDate.firstMatch(value);
    if (iso != null) {
      // JavaScript reads a date-only ISO text as UTC midnight
      int g(int i) => int.parse(iso.group(i)!);
      return DateTime.utc(g(1), g(2), g(3)).toLocal();
    }
    return _check(DateTime.tryParse(value)?.toLocal(), value);
  }

  DateTime _check(DateTime? date, String value) =>
      date ?? (throw RangeError('Invalid time value: $value'));
}
