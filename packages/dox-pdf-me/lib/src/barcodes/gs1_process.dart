import 'dart:convert';

import 'barcode_validator.dart';
import 'gs1_syntax.dart';

/// One AI and its value of a GS1 element string.
typedef Gs1Element = ({String ai, String value, bool fnc1After});

/// BWIPP's `gs1process` for a bracketed element string like
/// `(01)09521234543213(10)ABC`, with the options bwip-js gets from pdfme
/// (`lintreqs`, no `dontlint`): the AIs and values, and whether an FNC1
/// separator follows each one. Throws a [BarcodeInputException] with the
/// bwip-js message when the string is not valid GS1 data.
///
/// A port of `gs1process` (barcode.ps, version 2026-05-28, MIT license,
/// Copyright (c) 2004-2026 Terry Burton); the AI table is
/// [gs1Syntax].
class Gs1Process {
  Gs1Process._();

  static List<Gs1Element> parse(String text) {
    // bwip-js works on the UTF-8 bytes; one char per byte here
    String value = String.fromCharCodes(utf8.encode(text));
    if (!value.startsWith('(')) {
      _raise('GS1aiMissingOpenParen#2949', "AIs must start with '('");
    }
    List<String> ais = <String>[];
    List<String> vals = <String>[];
    String rest = value.substring(1);
    while (rest.isNotEmpty) {
      int close = rest.indexOf(')');
      if (close < 0) {
        _raise('GS1aiMissingCloseParen#2955', "AIs must end with ')'");
      }
      ais.add(rest.substring(0, close));
      rest = rest.substring(close + 1);
      int open = rest.indexOf('(');
      vals.add(open < 0 ? rest : rest.substring(0, open));
      rest = open < 0 ? '' : rest.substring(open + 1);
    }
    _lint(ais, vals);
    return <Gs1Element>[
      for (int i = 0; i < ais.length; i++)
        (
          ai: ais[i],
          value: vals[i],
          fnc1After:
              i < ais.length - 1 &&
              !(ais[i].length >= 2 && _fixed.contains(ais[i].substring(0, 2))),
        ),
    ];
  }

  /// Two-digit AI prefixes that need no FNC1 after them.
  static const Set<String> _fixed = <String>{
    '00', '01', '02', '03', '04', '11', '12', '13', '14', '15', '16', //
    '17', '18', '19', '20', '31', '32', '33', '34', '35', '36', '41',
  };

  static Never _raise(String name, String info) =>
      throw BarcodeInputException.bwipp(name, info);

  static final Map<String, _Spec> _specs = <String, _Spec>{};

  static _Spec? _spec(String ai) {
    String? s = gs1Syntax[ai];
    return s == null ? null : _specs.putIfAbsent(ai, () => _Spec(s));
  }

  static void _lint(List<String> ais, List<String> vals) {
    for (int i = 0; i < ais.length; i++) {
      String ai = ais[i];
      String? error = _lintValue(ai, vals[i]);
      if (error != null) {
        int colon = error.indexOf(' ');
        _raise(
          error.substring(0, colon),
          'AI $ai: ${error.substring(colon + 1)}',
        );
      }
    }
    Map<String, String> aivals = <String, String>{};
    for (int i = 0; i < ais.length; i++) {
      String? old = aivals[ais[i]];
      if (old == null) {
        aivals[ais[i]] = vals[i];
      } else if (old != vals[i]) {
        _raise(
          'GS1repeatedDifferingAIs#3920',
          'Repeated AIs (${ais[i]}) must have the same value',
        );
      }
    }
    bool exists(String patt, String self) {
      if (aivals.containsKey(patt)) return true;
      if (patt.length == 4 && patt[3] == 'n') {
        int pfx = patt[2] == 'n' ? 2 : 3;
        return ais.any(
          (String a) =>
              a != self &&
              a.length == 4 &&
              a.substring(0, pfx) == patt.substring(0, pfx),
        );
      }
      return false;
    }

    for (String ai in ais) {
      _Spec spec = _spec(ai)!;
      for (String patt in spec.ex) {
        if (exists(patt, ai)) {
          _raise(
            'GS1exclusiveAIs#3940',
            'AIs ($ai) and ($patt) are mutually exclusive',
          );
        }
      }
      for (List<List<String>> req in spec.req) {
        bool ok = req.any(
          (List<String> alt) => alt.every((String p) => exists(p, ai)),
        );
        if (!ok) {
          String all = spec.req
              .map(
                (List<List<String>> r) =>
                    r.map((List<String> alt) => alt.join('+')).join(' OR '),
              )
              .join(' WITH ');
          _raise(
            'GS1missingAIs#3967',
            'One of more requisite AIs for AI ($ai) are missing: $all',
          );
        }
      }
    }
  }

  /// `name message` of the first problem of [value] for [ai], or null.
  static String? _lintValue(String ai, String value) {
    _Spec? spec = _spec(ai);
    if (spec == null) return 'GS1unknownAI#3870 Unrecognised AI';
    int min = 0, max = 0;
    for (_Part p in spec.parts) {
      if (!p.opt) min += p.min;
      max += p.max;
    }
    if (min > value.length) return 'GS1valueTooShort#3842 Too short';
    if (max < value.length) return 'GS1valueTooLong#3845 Too long';
    String val = value;
    // A failing linter only ends the linters of its part: BWIPP goes on
    // with the next parts, and the last problem found wins.
    String? linted;
    for (_Part p in spec.parts) {
      int take = p.max < val.length ? p.max : val.length;
      String part = val.substring(0, take);
      val = val.substring(take);
      if (part.isEmpty) {
        if (!p.opt) return 'GS1valueTooShort#3854 Too short';
        continue;
      }
      if (part.length < p.min) return 'GS1valueTooShort#3858 Too short';
      String? error = _cset(p.cset, part);
      if (error != null) return error;
      for (String linter in p.linters) {
        error = Gs1Linters.run(linter, part);
        if (error != null) {
          linted = error;
          break;
        }
      }
    }
    if (linted != null) return linted;
    if (val.isNotEmpty) return 'GS1valueTooLong#3867 Too long';
    return null;
  }

  static String? _cset(String cset, String v) {
    switch (cset) {
      case 'N':
        return v.codeUnits.every(_digit)
            ? null
            : 'GS1notNumeric#3199 Not numeric';
      case 'X':
        return _all(v, gs1Cset82)
            ? null
            : 'GS1badCSET82character#3204 Invalid CSET 82 character';
      case 'Y':
        return _all(v, gs1Cset39)
            ? null
            : 'GS1badCSET39character#3209 Invalid CSET 39 character';
      default:
        String body = v;
        int eq = v.indexOf('=');
        if (eq >= 0) {
          body = v.substring(0, eq);
          String pad = v.substring(eq + 1);
          int r = body.length % 3;
          if (!((r == 1 && pad == '=') || (r == 2 && pad.isEmpty))) {
            return 'GS1badCSET64padding#3218 Invalid CSET 64 padding';
          }
        }
        return _all(body, gs1Cset64)
            ? null
            : 'GS1badCSET64character#3224 Invalid CSET 64 character';
    }
  }

  static bool _digit(int c) => c >= 48 && c <= 57;

  static bool _all(String v, String set) =>
      v.split('').every((String c) => set.contains(c));
}

class _Part {
  _Part(String s) {
    List<String> f = s.split(',');
    cset = f[0];
    min = int.parse(f[1]);
    max = int.parse(f[2]);
    opt = f[3] == '1';
    linters = f[4].isEmpty ? const <String>[] : f[4].split('.');
  }

  late final String cset;
  late final int min;
  late final int max;
  late final bool opt;
  late final List<String> linters;
}

class _Spec {
  _Spec(String s) {
    List<String> f = s.split('|');
    parts = <_Part>[for (String p in f[0].split(' ')) _Part(p)];
    ex = f[1].isEmpty ? const <String>[] : f[1].split(',');
    req = f[2].isEmpty
        ? const <List<List<String>>>[]
        : <List<List<String>>>[
            for (String r in f[2].split(';'))
              <List<String>>[for (String alt in r.split('/')) alt.split('+')],
          ];
  }

  late final List<_Part> parts;
  late final List<String> ex;
  late final List<List<List<String>>> req;
}

/// BWIPP's GS1 linters. Each returns `name message` of the problem, or
/// null.
class Gs1Linters {
  Gs1Linters._();

  static const List<int> _primes = <int>[
    2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, //
    67, 71, 73, 79, 83,
  ];
  static const List<int> _daysInMonth = <int>[
    31, -1, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, //
  ];

  static final Set<String> _iso3166 = gs1Iso3166.split(' ').toSet();
  static final Set<String> _iso3166a2 = gs1Iso3166Alpha2.split(' ').toSet();
  static final Set<String> _iso4217 = gs1Iso4217.split(' ').toSet();
  static final Set<String> _media = gs1MediaTypes.split(' ').toSet();
  static final Set<String> _package = gs1PackageTypes.split(' ').toSet();

  static bool _digits(String v) =>
      v.codeUnits.every((int c) => c >= 48 && c <= 57);

  /// PostScript `cvi` of a short digit string.
  static int _i(String v) => int.tryParse(v) ?? 0;

  static String? run(String linter, String v) => switch (linter) {
    'lintgcppos1' => _gcp1(v),
    'lintgcppos2' =>
      v.isEmpty
          ? 'GS1valueTooShortForOffsetGCP#3236 Value is too short to contain an offset GS1 Company Prefix'
          : _gcp1(v.substring(1)),
    'lintimporteridx' =>
      '-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz'
              .contains(v)
          ? null
          : 'GS1badImporterIndex#3242 Invalid importer index',
    'lintcsum' => _csum(v),
    'lintcsumalpha' => _csumAlpha(v),
    'lintiso3166' =>
      _iso3166.contains(v)
          ? null
          : 'GS1UnknownCountry#3279 Unknown country code',
    'lintiso3166999' =>
      v == '999' || _iso3166.contains(v)
          ? null
          : 'GS1UnknownCountryOr999#3284 Unknown country code or not 999',
    'lintiso3166alpha2' => _alpha2(v),
    'lintiso4217' =>
      _iso4217.contains(v)
          ? null
          : 'GS1UnknownCurrency#3295 Unknown currency code',
    'lintiso5218' =>
      const <String>{'0', '1', '2', '9'}.contains(v)
          ? null
          : 'GS1biologicalSexCode#3300 Invalid biological sex code',
    'lintiban' => _iban(v),
    'lintzero' => v == '0' ? null : 'GS1zeroRequired#3322 Zero is required',
    'lintnonzero' =>
      v.split('').any((String c) => c != '0')
          ? null
          : 'GS1zeroNotPermitted#3327 Zero not permitted',
    'lintnozeroprefix' =>
      v.length > 1 && v[0] == '0'
          ? 'GS1badZeroPrefix#3332 Zero prefix is not permitted'
          : null,
    'linthasnondigit' =>
      _digits(v)
          ? 'GS1requiresNonDigit#3338 A non-digit character is required'
          : null,
    'linthyphen' =>
      v == '-' ? null : 'GS1hyphenRequired#3342 A hyphen is required',
    'lintyyyymmd0' => _yyyymmd0(v),
    'lintyyyymmdd' =>
      v.length != 8
          ? 'GS1badDateLength#3356 Invalid length for yyyymmdd date'
          : _i(v.substring(6, 8)) < 1
          ? 'GS1badDay#3357 Invalid day of month'
          : _yyyymmd0(v),
    'lintyymmd0' => _yymmd0(v),
    'lintyymmdd' =>
      v.length != 6
          ? 'GS1badDateLength#3369 Invalid length for yymmdd date'
          : _i(v.substring(4, 6)) < 1
          ? 'GS1badDay#3370 Invalid day of month'
          : _yymmd0(v),
    'linthh' =>
      _i(v.substring(0, 2)) > 23 ? 'GS1badHour#3375 Invalid hour of day' : null,
    'lintmi' =>
      _i(v.substring(0, 2)) > 59
          ? 'GS1badMinute#3379 Invalid minute in the hour'
          : null,
    'lintss' =>
      _i(v.substring(0, 2)) > 59
          ? 'GS1badSecond#3383 Invalid second in the minute'
          : null,
    'linthhmi' =>
      _i(v.substring(0, 2)) > 23
          ? 'GS1badHour#3387 Invalid hour of day'
          : _i(v.substring(2, 4)) > 59
          ? 'GS1badMinute#3388 Invalid minute in the hour'
          : null,
    'lintmmoptss' => _mmOptSs(v),
    'lintyesno' =>
      v == '0' || v == '1'
          ? null
          : 'GS1badBoolean#3404 Neither 0 nor 1 for yes or no',
    'lintwinding' =>
      v == '0' || v == '1' || v == '9'
          ? null
          : 'GS1badWinding#3410 Invalid winding direction',
    'lintpieceoftotal' => _pieceOfTotal(v),
    'lintposinseqslash' => _posInSeq(v),
    'lintpcenc' => _pcenc(v),
    'lintcouponcode' => _Coupon(v).code(),
    'lintcouponposoffer' => _Coupon(v).posOffer(),
    'lintlatitude' =>
      v.length != 10
          ? 'GS1badLatitudeLength#3809 Invalid length for a latitude'
          : v.compareTo('1800000000') > 0
          ? 'GS1badLatitude#3812 Invalid value for latitude'
          : null,
    'lintlongitude' =>
      v.length != 10
          ? 'GS1badLongitudeLength#3817 Invalid length for a longitude'
          : v.compareTo('3600000000') > 0
          ? 'GS1badLongitude#3820 Invalid value for longitude'
          : null,
    'lintmediatype' =>
      _media.contains(v)
          ? null
          : 'GS1UnknownMediaType#3824 Unknown AIDC media type',
    'lintpackagetype' =>
      _package.contains(v)
          ? null
          : 'GS1unknownPackageType#3828 Unknown package type',
    _ => throw StateError('unknown GS1 linter $linter'),
  };

  static String? _gcp1(String v) {
    if (v.length < 2) {
      return 'GS1gcpTooShort#3228 Value is too short to contain a GS1 Company Prefix';
    }
    return _digits(v.substring(0, 2))
        ? null
        : 'GS1badGCP#3231 Non-numeric GS1 Company Prefix';
  }

  static String? _csum(String v) {
    int w = v.length.isEven ? 3 : 1;
    int sum = 0;
    for (int c in v.codeUnits) {
      sum += (c - 48) * w;
      w = 4 - w;
    }
    return sum % 10 != 0 ? 'GS1badChecksum#3251 Bad checksum' : null;
  }

  static String? _csumAlpha(String v) {
    if (v.length < 2) {
      return 'GS1alphaTooShort#3255 Alphanumeric string is too short to check';
    }
    String head = v.substring(0, v.length - 2);
    List<int> vals = <int>[];
    for (String c in head.split('')) {
      int i = gs1Cset82.indexOf(c);
      if (i < 0) {
        return 'GS1UnknownCSET82Character#3261 Unknown CSET 82 character';
      }
      vals.add(i);
    }
    List<int> check = <int>[];
    for (String c in v.substring(v.length - 2).split('')) {
      int i = gs1Cset32.indexOf(c);
      if (i < 0) {
        return 'GS1UnknownCSET32Character#3267 Unknown CSET 32 character';
      }
      check.add(i);
    }
    if (vals.length > _primes.length) {
      return 'GS1alphaTooLong#3272 Alphanumeric string is too long to check';
    }
    int sum = 0;
    for (int k = 0; k < vals.length; k++) {
      sum += vals[k] * _primes[vals.length - 1 - k];
    }
    return sum % 1021 != (check[0] << 5) + check[1]
        ? 'GS1badAlphaCheckCharacters#3275 Bad alphanumeric check characters'
        : null;
  }

  static String? _alpha2(String v) => _iso3166a2.contains(v)
      ? null
      : 'GS1UnknownCountryAlpha#3291 Unknown country alpha code';

  static String? _iban(String v) {
    if (v.length <= 4) return 'GS1tooShort#3305 IBAN too short';
    const String set = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    if (!v.split('').every(set.contains)) {
      return 'GS1badIBANcharacter#3312 Invalid IBAN character';
    }
    int acc = 0;
    for (int c in (v.substring(4) + v.substring(0, 4)).codeUnits) {
      int d = c - 48;
      List<int> ds = d > 9 ? <int>[(d - 7) ~/ 10, (d - 7) % 10] : <int>[d];
      for (int x in ds) {
        acc = (acc * 10 + x) % 97;
      }
    }
    if (acc != 1) return 'GS1badIBANchecksum#3317 IBAN checksum incorrect';
    return _alpha2(v.substring(0, 2));
  }

  static bool _leap(int y) => y % 400 == 0 || (y % 4 == 0 && y % 100 != 0);

  static String? _yyyymmd0(String v) {
    int month = _i(v.substring(4, 6));
    if (month < 1 || month > 12) return 'GS1badMonth#3346 Invalid month';
    int days = month == 2
        ? (_leap(_i(v.substring(0, 4))) ? 29 : 28)
        : _daysInMonth[month - 1];
    return days < _i(v.substring(6, 8))
        ? 'GS1badDay#3352 Invalid day of month'
        : null;
  }

  static String? _yymmd0(String v) {
    int d = _i(v.substring(0, 2)) - 21;
    String century = d >= 51 ? '19' : (d <= -50 ? '21' : '20');
    return _yyyymmd0('$century${v.substring(0, 6)}');
  }

  static String? _mmOptSs(String v) {
    if (v.length != 2 && v.length != 4) {
      return 'GS1badTimeLength#3393 Invalid length for optional minutes and seconds';
    }
    if (_i(v.substring(0, 2)) > 59) {
      return 'GS1badMinute#3395 Invalid minute in the hour';
    }
    if (v.length >= 4 && _i(v.substring(2, 4)) > 59) {
      return 'GS1badSecond#3397 Invalid second in the minute';
    }
    return null;
  }

  static String? _pieceOfTotal(String v) {
    if (v.length.isOdd) {
      return 'GS1badPieceTotalLength#3415 Invalid piece/total length';
    }
    int half = v.length ~/ 2;
    int piece = _i(v.substring(0, half));
    if (piece == 0) return 'GS1badPieceNumber#3417 Invalid piece number';
    int total = _i(v.substring(half));
    if (total == 0) return 'GS1badPieceTotal#3419 Invalid total number';
    return piece > total
        ? 'GS1pieceExceedsTotal#3420 Piece number exceeds total'
        : null;
  }

  static String? _posInSeq(String v) {
    int slash = v.indexOf('/');
    if (slash < 0) {
      return 'invalidPosInSeqFormat#3425 Invalid <pos>/<end> format';
    }
    String pos = v.substring(0, slash);
    String end = v.substring(slash + 1);
    if (pos.isEmpty) {
      return 'invalidPosInSeqFormat#3429 Invalid <pos>/<end> format';
    }
    if (end.isEmpty) {
      return 'invalidPosInSeqFormat#3432 Invalid <pos>/<end> format';
    }
    if (!_digits(pos)) return 'positionNotNumeric#3437 Position is not numeric';
    if (!_digits(end)) return 'endNotNumeric#3441 End is not numeric';
    if (pos[0] == '0') {
      return 'positionZeroPrefix#3442 Position cannot have zero prefix';
    }
    if (end[0] == '0') return 'endZeroPrefix#3443 End cannot have zero prefix';
    return int.parse(end) < int.parse(pos)
        ? 'positionExceedsEnd#3445 Position exceeds end'
        : null;
  }

  static String? _pcenc(String v) {
    String rest = v;
    while (true) {
      int p = rest.indexOf('%');
      if (p < 0) return null;
      rest = rest.substring(p + 1);
      if (rest.length < 2) return 'GS1badPercentEscape#3451 Invalid % escape';
      if (!RegExp(r'^[0-9A-Fa-f]{2}').hasMatch(rest)) {
        return 'GS1badPercentChars#3458 Invalid characters for percent encoding';
      }
    }
  }
}

/// The coupon linters (`lintcouponcode`, `lintcouponposoffer`).
class _Coupon {
  _Coupon(this._v);

  String _v;

  int _digit() => _v.codeUnitAt(0) - 48;

  void _drop(int n) => _v = _v.substring(n);

  /// A length indicator and its field: `vli + 1` or more digits.
  String? _vliField(
    int add,
    String missing,
    String? Function(int vli)? bad,
    String truncated,
  ) {
    if (_v.isEmpty) return missing;
    int vli = _digit();
    String? b = bad?.call(vli);
    if (b != null) return b;
    int n = vli + add + 1;
    if (n > _v.length) return truncated;
    _drop(n);
    return null;
  }

  String? _fixed(int n, String truncated) {
    if (_v.length < n) return truncated;
    _drop(n);
    return null;
  }

  String? _code1(String missing, String bad, bool Function(int) ok) {
    if (_v.isEmpty) return missing;
    if (!ok(_digit())) return bad;
    _drop(1);
    return null;
  }

  bool _field(int f) => _v.isNotEmpty && _digit() == f;

  static bool _leap(int y) => y % 400 == 0 || (y % 4 == 0 && y % 100 != 0);

  /// A yymmdd date; the date as a number, or a problem.
  Object _date(String short, String badMonth, String badDay) {
    if (_v.length < 6) return short;
    int month = int.parse(_v.substring(2, 4));
    if (month < 1 || month > 12) return badMonth;
    int days;
    if (month == 2) {
      int y = int.parse(_v.substring(0, 2));
      int d = y - 21;
      y += d >= 51 ? 1900 : (d <= -50 ? 2100 : 2000);
      days = _leap(y) ? 29 : 28;
    } else {
      days = Gs1Linters._daysInMonth[month - 1];
    }
    int day = int.parse(_v.substring(4, 6));
    if (days < day || day < 1) return badDay;
    int date = int.parse(_v.substring(0, 6));
    _drop(6);
    return date;
  }

  String? code() {
    if (!Gs1Linters._digits(_v)) {
      return 'GS1couponNotNumeric#3466 Coupon not numeric';
    }
    String? e =
        _vliField(
          6,
          'GS1couponTooShortGCPVLI#3470 Coupon too short: Missing GCP VLI',
          (int x) => x > 6
              ? 'GS1couponBadGCPVLI#3473 Coupon GCP length indicator must be 0-6'
              : null,
          'GS1couponTooShortGCP#3477 Coupon too short: GCP truncated',
        ) ??
        _fixed(
          6,
          'GS1couponTooShortOfferCode#3483 Coupon too short: Offer Code truncated',
        ) ??
        _vliField(
          0,
          'GS1couponTooShortSaveValueVLI#3489 Coupon too short: Missing Save Value VLI',
          (int x) => x < 1 || x > 5
              ? 'GS1couponBadSaveValueVLI#3492 Coupon Save Value length indicator must be 1-5'
              : null,
          'GS1couponTooShortSaveValue#3496 Coupon too short: Save Value truncated',
        ) ??
        _vliField(
          0,
          'GS1couponTooShort1stPurchaseRequirementVLI#3502 Coupon too short: Missing 1st Purchase Requirement VLI',
          (int x) => x < 1 || x > 5
              ? 'GS1couponBad1stPurchaseRequirementVLI#3505 Coupon 1st Purchase Requirement length indicator must be 1-5'
              : null,
          'GS1couponTooShort1stPurchaseRequirement#3509 Coupon too short: 1st Purchase Requirement truncated',
        ) ??
        _code1(
          'GS1couponTooShort1stPurchaseRequirementCode#3515 Coupon too short: Missing 1st Purchase Requirement Code',
          'GS1couponBad1stPurchaseRequirementCode#3518 Coupon 1st Purchase Requirement Code must be 0-4 or 9',
          (int x) => x <= 4 || x == 9,
        ) ??
        _fixed(
          3,
          'GS1couponTooShort1stPurchaseFamilyCode#3524 Coupon too short: 1st Purchase Family Code truncated',
        );
    if (e != null) return e;
    if (_field(1)) {
      _drop(1);
      e =
          _code1(
            'GS1couponTooShortAdditionalPurchaseRulesCode#3534 Coupon too short: Missing Additional Purchase Rules Code',
            'GS1couponBadAdditionalPurchaseRulesCode#3537 Coupon Additional Purchase Rules Code must be 0-3',
            (int x) => x <= 3,
          ) ??
          _purchase('2nd', <int>[
            3543,
            3546,
            3550,
            3556,
            3559,
            3565,
            3571,
            3574,
            3578,
          ]);
      if (e != null) return e;
    }
    if (_field(2)) {
      _drop(1);
      e = _purchase('3rd', <int>[
        3590,
        3593,
        3597,
        3603,
        3606,
        3612,
        3618,
        3621,
        3625,
      ]);
      if (e != null) return e;
    }
    int expire = -1;
    if (_field(3)) {
      _drop(1);
      Object d = _date(
        'GS1couponTooShortExpirationDate#3638 Coupon too short: Expiration date',
        'GS1couponExpirationDateBadMonth#3640 Invalid month in expiration date',
        'GS1couponExpirationDateBadDay#3649 Invalid day of month in expiration date',
      );
      if (d is String) return d;
      expire = d as int;
    }
    if (_field(4)) {
      _drop(1);
      Object d = _date(
        'GS1couponTooShortStartDate#3661 Coupon too short: Start date',
        'GS1couponStartDateBadMonth#3663 Invalid month in start date',
        'GS1couponStartDateBadDay#3672 Invalid day of month in start date',
      );
      if (d is String) return d;
      if (expire != -1 && expire < (d as int)) {
        return 'GS1couponExpireDateBeforeStartDate#3675 Coupon expires before it starts';
      }
    }
    if (_field(5)) {
      _drop(1);
      e = _vliField(
        6,
        'GS1couponTooShortSerialNumberVLI#3687 Coupon too short: Missing Serial Number VLI',
        null,
        'GS1couponTooShortSerialNumber#3691 Coupon too short: Serial Number truncated',
      );
      if (e != null) return e;
    }
    if (_field(6)) {
      _drop(1);
      e = _vliField(
        6,
        'GS1couponTooShortRetailerGCPGLNVLI#3703 Coupon too short: Missing Retailer GCP/GLN VLI',
        (int x) => x < 1 || x > 7
            ? 'GS1couponBadRetailerGCPGLNVLI#3706 Coupon Retailer GCP/GLN length indicator must be 1-7'
            : null,
        'GS1couponTooShortRetailerGCPGLN#3710 Coupon too short: Retailer GCP/GLN truncated',
      );
      if (e != null) return e;
    }
    if (_field(9)) {
      _drop(1);
      e =
          _code1(
            'GS1couponTooShortSaveValueCode#3722 Coupon too short: Missing Save Value Code',
            'GS1couponBadSaveValueCode#3725 Coupon Save Value Code must be 0,1,2,5 or 6',
            (int x) => x <= 6 && x != 3 && x != 4,
          ) ??
          _code1(
            'GS1couponTooShortSaveValueAppliesToItem#3731 Coupon too short: Missing Save Value Applies to Item',
            'GS1couponBadSaveValueAppliesToItem#3734 Coupon Save Value Applies to Item must be 0-2',
            (int x) => x <= 2,
          ) ??
          _fixed(
            1,
            'GS1couponTooShortStoreCouponFlag#3740 Coupon too short: Missing Store Coupon Flag',
          ) ??
          _code1(
            "GS1couponTooShortDontMultiplyFlag#3746 Coupon too short: Missing Don't Multiply Flag",
            "GS1couponBadDontMultiplyFlag#3749 Don't Multiply Flag must be 0 or 1",
            (int x) => x <= 1,
          );
      if (e != null) return e;
    }
    return _v.isEmpty
        ? null
        : 'GS1couponUnrecognisedOptionalField#3756 Coupon fields must be 1,2,3,4,5,6 or 9, increasing order';
  }

  /// The 2nd or 3rd purchase requirement, family code and GCP.
  String? _purchase(String n, List<int> l) =>
      _vliField(
        0,
        'GS1couponTooShort${n}PurchaseRequirementVLI#${l[0]} Coupon too short: Missing $n Purchase Requirement VLI',
        (int x) => x < 1 || x > 5
            ? 'GS1couponBad${n}PurchaseRequirementVLI#${l[1]} Coupon $n Purchase Requirement length indicator must be 1-5'
            : null,
        'GS1couponTooShort${n}PurchaseRequirement#${l[2]} Coupon too short: $n Purchase Requirement truncated',
      ) ??
      _code1(
        'GS1couponTooShort${n}PurchaseRequirementCode#${l[3]} Coupon too short: Missing $n Purchase Requirement Code',
        'GS1couponBad${n}PurchaseRequirementCode#${l[4]} Coupon $n Purchase Requirement Code must be 0-4 or 9',
        (int x) => x <= 4 || x == 9,
      ) ??
      _fixed(
        3,
        'GS1couponTooShort${n}PurchaseFamilyCode#${l[5]} Coupon too short: $n Purchase Family Code truncated',
      ) ??
      _gcpOr9(
        'GS1couponTooShort${n}PurchaseGCPVLI#${l[6]} Coupon too short: Missing $n Purchase GCP VLI',
        'GS1couponBad${n}PurchaseGCPVLI#${l[7]} Coupon $n Purchase GCP length indicator must be 0-6 or 9',
        'GS1couponTooShort${n}PurchaseGCP#${l[8]} Coupon too short: $n Purchase GCP truncated',
      );

  /// A GCP VLI of 0-6 (a GCP of 6 + VLI digits) or 9 (no GCP).
  String? _gcpOr9(String missing, String bad, String truncated) {
    if (_v.isEmpty) return missing;
    int vli = _digit();
    if (vli > 6 && vli != 9) return bad;
    int n = (vli == 9 ? 0 : vli + 6) + 1;
    if (n > _v.length) return truncated;
    _drop(n);
    return null;
  }

  String? posOffer() {
    if (!Gs1Linters._digits(_v)) {
      return 'GS1couponNotNumeric#3765 Coupon not numeric';
    }
    return _code1(
          'GS1couponTooShortFormatCode#3768 Coupon too short: Missing Format Code',
          'GS1couponBadFormatCode#3771 Coupon format must be 0 or 1',
          (int x) => x <= 1,
        ) ??
        _vliField(
          6,
          'GS1couponTooShortFunderVLI#3776 Coupon too short: Missing Funder VLI',
          (int x) => x > 6
              ? 'GS1couponBadFunderVLI#3779 Coupon Funder length indicator must be 0-6'
              : null,
          'GS1couponTooShortFunder#3783 Coupon too short: Truncated Funder ID',
        ) ??
        _fixed(
          6,
          'GS1couponTooShortOfferCode#3788 Coupon too short: Truncated Offer Code',
        ) ??
        _vliField(
          6,
          'GS1couponTooShortSnVLI#3793 Coupon too short: Missing SN VLI',
          null,
          'GS1couponTooShortSn#3798 Coupon too short: Truncated SN',
        ) ??
        (_v.isEmpty ? null : 'GS1couponTooLong#3802 Coupon too long');
  }
}
