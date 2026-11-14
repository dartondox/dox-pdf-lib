/// A date-fns v4 compatible formatter, for the date, time and dateTime
/// schemas.
///
/// It has all date-fns `format` tokens, with the names and the long formats
/// (`P`, `p`) of the English (`en-US`) locale for every locale. Weeks start
/// on Sunday (`w`, `e`, `c`, `Y`). `D`, `DD`, `YY` and `YYYY` throw like in
/// date-fns, so the schema uses its default format.
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

  /// Sunday first, like JavaScript `getDay()`.
  static const List<String> _days = <String>[
    'Sunday',
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ];

  static const Map<String, String> _dateFormats = <String, String>{
    'P': 'MM/dd/yyyy',
    'PP': 'MMM d, y',
    'PPP': 'MMMM do, y',
    'PPPP': 'EEEE, MMMM do, y',
  };

  static const Map<String, String> _timeFormats = <String, String>{
    'p': 'h:mm a',
    'pp': 'h:mm:ss a',
    'ppp': 'h:mm:ss a z',
    'pppp': 'h:mm:ss a zzzz',
  };

  static final RegExp _longTokens = RegExp(r"P+p+|P+|p+|''|'(''|[^'])+('|$)|.");
  static final RegExp _tokens = RegExp(
    r"[yYQqMLwIdDecihHKkms]o|(\w)\1*|''|'(''|[^'])+('|$)|.",
  );
  static final RegExp _latin = RegExp('[a-zA-Z]');
  static const String _letters = 'GyYRuQqMLwIdDEeciabBhHKkmsSXxOztT';

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

  /// Formats [date] like date-fns `format`. Throws a [FormatException] for
  /// an unknown token.
  String format(DateTime date, String pattern) {
    String expanded = _longTokens
        .allMatches(pattern)
        .map((Match m) => _long(m[0]!))
        .join();
    StringBuffer out = StringBuffer();
    for (Match m in _tokens.allMatches(expanded)) {
      String t = m[0]!;
      if (t == "''") {
        out.write("'");
      } else if (t[0] == "'") {
        String inner = t.endsWith("'") && t.length > 1
            ? t.substring(1, t.length - 1)
            : t.substring(1);
        out.write(inner.replaceAll("''", "'"));
      } else if (_letters.contains(t[0])) {
        if (t == 'D' || t == 'DD' || t == 'YY' || t == 'YYYY') {
          throw FormatException('Protected date format token: $t');
        }
        out.write(_token(date, t));
      } else if (_latin.hasMatch(t[0])) {
        throw FormatException('Unsupported date format token: $t');
      } else {
        out.write(t);
      }
    }
    return out.toString();
  }

  /// The English long format of a `P` / `p` token (date-fns
  /// `longFormatters`); other parts stay as they are.
  static String _long(String t) {
    if (t[0] != 'P' && t[0] != 'p') return t;
    String full(Map<String, String> formats, String key) =>
        formats[key] ?? formats.values.last;
    if (t[0] == 'p') return full(_timeFormats, t);
    int split = t.indexOf('p');
    if (split < 0) return full(_dateFormats, t);
    String date = t.substring(0, split);
    String joiner = date.length >= 3 ? " 'at' " : ', ';
    return '${full(_dateFormats, date)}$joiner'
        '${full(_timeFormats, t.substring(split))}';
  }

  static String _pad(int v, int width) {
    String s = v.abs().toString().padLeft(width, '0');
    return v < 0 ? '-$s' : s;
  }

  static String _ordinal(int n) {
    int r = n % 100;
    if (r > 20 || r < 10) {
      switch (r % 10) {
        case 1:
          return '${n}st';
        case 2:
          return '${n}nd';
        case 3:
          return '${n}rd';
      }
    }
    return '${n}th';
  }

  /// A number token: `Xo` is an ordinal, else the number with zeros to the
  /// token length.
  static String _number(int v, String t) =>
      t.length == 2 && t[1] == 'o' ? _ordinal(v) : _pad(v, t.length);

  /// A name by width: 3 or less abbreviated, 4 wide, 5 narrow, 6 short.
  static String _named(String name, int n, {bool day = false}) => switch (n) {
    5 => name[0],
    6 when day => name.substring(0, 2),
    4 || 6 || > 6 => name,
    _ => name.substring(0, 3),
  };

  String _token(DateTime d, String t) {
    int n = t.length;
    int weekday = d.weekday % 7; // Sunday 0
    int quarter = (d.month + 2) ~/ 3;
    switch (t[0]) {
      case 'G':
        return n == 4 || n > 5
            ? (d.year > 0 ? 'Anno Domini' : 'Before Christ')
            : n == 5
            ? (d.year > 0 ? 'A' : 'B')
            : (d.year > 0 ? 'AD' : 'BC');
      case 'y':
        int year = d.year > 0 ? d.year : 1 - d.year;
        if (t == 'yo') return _ordinal(year);
        return _pad(t == 'yy' ? year % 100 : year, n);
      case 'Y':
        int year = _weekYear(d, 0, 1);
        if (t == 'Yo') return _ordinal(year);
        return _pad(year, n);
      case 'R':
        return _pad(_weekYear(d, 1, 4), n);
      case 'u':
        return _pad(d.year, n);
      case 'Q':
      case 'q':
        if (n <= 2) return _number(quarter, t);
        return switch (n) {
          3 => 'Q$quarter',
          5 => '$quarter',
          _ => '${_ordinal(quarter)} quarter',
        };
      case 'M':
      case 'L':
        if (n <= 2) return _number(d.month, t);
        return _named(_months[d.month - 1], n == 6 ? 4 : n);
      case 'w':
        return _number(_week(d, 0, 1), t);
      case 'I':
        return _number(_week(d, 1, 4), t);
      case 'd':
        return t == 'do' ? _ordinal(d.day) : _pad(d.day, n);
      case 'D':
        int dayOfYear =
            DateTime.utc(
              d.year,
              d.month,
              d.day,
            ).difference(DateTime.utc(d.year)).inDays +
            1;
        return _number(dayOfYear, t);
      case 'E':
        return _named(_days[weekday], n, day: true);
      case 'e':
      case 'c':
      case 'i':
        int local = t[0] == 'i' ? (weekday == 0 ? 7 : weekday) : weekday + 1;
        if (n <= 2) return _number(local, t);
        return _named(_days[weekday], n, day: true);
      case 'a':
      case 'b':
        bool pm = d.hour >= 12;
        String? special = t[0] == 'b'
            ? (d.hour == 12
                  ? (n == 5 ? 'n' : 'noon')
                  : d.hour == 0
                  ? (n == 5 ? 'mi' : 'midnight')
                  : null)
            : null;
        if (special != null) return special;
        return switch (n) {
          1 || 2 => pm ? 'PM' : 'AM',
          3 => pm ? 'pm' : 'am',
          5 => pm ? 'p' : 'a',
          _ => pm ? 'p.m.' : 'a.m.',
        };
      case 'B':
        return d.hour >= 17
            ? 'in the evening'
            : d.hour >= 12
            ? 'in the afternoon'
            : d.hour >= 4
            ? 'in the morning'
            : 'at night';
      case 'h':
        return _number(d.hour % 12 == 0 ? 12 : d.hour % 12, t);
      case 'H':
        return _number(d.hour, t);
      case 'K':
        return _number(d.hour % 12, t);
      case 'k':
        return _number(d.hour == 0 ? 24 : d.hour, t);
      case 'm':
        return _number(d.minute, t);
      case 's':
        return _number(d.second, t);
      case 'S':
        // ponytail: BigInt, so many S never overflow; JavaScript writes
        // 1e21 and more with an exponent, we do not (22 or more S only)
        BigInt ms = BigInt.from(d.millisecond);
        BigInt ten = BigInt.from(10);
        BigInt fraction = n <= 3 ? ms ~/ ten.pow(3 - n) : ms * ten.pow(n - 3);
        return fraction.toString().padLeft(n, '0');
      case 'X':
      case 'x':
        int offset = d.timeZoneOffset.inMinutes;
        if (t[0] == 'X' && offset == 0) return 'Z';
        if (n == 1) {
          return offset % 60 == 0
              ? '${_sign(offset)}${_pad(offset.abs() ~/ 60, 2)}'
              : _zone(offset, '');
        }
        return _zone(offset, n == 2 || n == 4 ? '' : ':');
      case 'O':
      case 'z':
        int offset = d.timeZoneOffset.inMinutes;
        if (n == 4 || n > 4) return 'GMT${_zone(offset, ':')}';
        int h = offset.abs() ~/ 60;
        int m = offset.abs() % 60;
        return 'GMT${_sign(offset)}$h${m == 0 ? '' : ':${_pad(m, 2)}'}';
      case 't':
        return _pad(d.millisecondsSinceEpoch ~/ 1000, n);
      case 'T':
        return _pad(d.millisecondsSinceEpoch, n);
    }
    throw FormatException('Unsupported date format token: $t');
  }

  static String _sign(int offsetMinutes) => offsetMinutes < 0 ? '-' : '+';

  static String _zone(int offsetMinutes, String delimiter) =>
      '${_sign(offsetMinutes)}${_pad(offsetMinutes.abs() ~/ 60, 2)}'
      '$delimiter${_pad(offsetMinutes.abs() % 60, 2)}';

  /// The first day of week 1 of [year]: weeks start on [start] (0 Sunday)
  /// and week 1 has January [first].
  static DateTime _firstWeek(int year, int start, int first) {
    DateTime day = DateTime.utc(year, 1, first);
    return day.subtract(Duration(days: (day.weekday % 7 - start + 7) % 7));
  }

  static int _weekYear(DateTime d, int start, int first) {
    DateTime day = DateTime.utc(d.year, d.month, d.day);
    if (!day.isBefore(_firstWeek(d.year + 1, start, first))) return d.year + 1;
    if (!day.isBefore(_firstWeek(d.year, start, first))) return d.year;
    return d.year - 1;
  }

  static int _week(DateTime d, int start, int first) {
    DateTime day = DateTime.utc(d.year, d.month, d.day);
    DateTime week1 = _firstWeek(_weekYear(d, start, first), start, first);
    return day.difference(week1).inDays ~/ 7 + 1;
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
