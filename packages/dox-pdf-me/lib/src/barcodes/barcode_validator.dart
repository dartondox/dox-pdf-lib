/// The barcode schema types of pdfme. Each one gets a `BarcodePlugin`.
const List<String> barcodeTypes = <String>[
  'qrcode',
  'japanpost',
  'ean13',
  'ean8',
  'code39',
  'code128',
  'nw7',
  'itf14',
  'upca',
  'upce',
  'gs1datamatrix',
  'pdf417',
];

final RegExp _japanPost = RegExp(r'^(\d{7})(\d|[A-Z]|-)+$');
final RegExp _ean13 = RegExp(r'^\d{12}$|^\d{13}$');
final RegExp _ean8 = RegExp(r'^\d{7}$|^\d{8}$');
final RegExp _code39 = RegExp(r'^(\d|[A-Z]|[-.$/+%]|\s)+$');
final RegExp _code128Bad = RegExp(
  '([゠-ヿ぀-ゟ々-〆ム-鿏]|'
  '[Ａ-Ｚａ-ｚ０-９！＂＃＄％＆＇（）＊＋，－．／：；＜＝＞？＠［＼］＾＿｀｛｜｝〜　])+',
);
final RegExp _nw7 = RegExp(r'^[A-Da-d]([0-9.$:/+-])+[A-Da-d]$');
final RegExp _itf14 = RegExp(r'^\d{13}$|^\d{14}$');
final RegExp _upca = RegExp(r'^\d{11}$|^\d{12}$');
final RegExp _upce = RegExp(r'^0(\d{6}$|\d{7}$)');
final RegExp _gtin = RegExp(r'\((01)\)(\d*)(\(|$)');

/// pdfme's `validateBarcodeInput`. False means: draw nothing.
///
/// The rules and regular expressions are pdfme's, also where they are
/// loose (eg. code39 allows any white space).
bool validateBarcodeInput(String type, String input) {
  if (input.isEmpty) return false;
  return switch (type) {
    // UTF-16 length, like JavaScript
    'qrcode' => input.length < 500,
    'japanpost' => _japanPost.hasMatch(input),
    'ean13' => _ean13.hasMatch(input) && _checkDigitOk(input, 13),
    'ean8' => _ean8.hasMatch(input) && _checkDigitOk(input, 8),
    'code39' => _code39.hasMatch(input),
    'code128' => !_code128Bad.hasMatch(input),
    'nw7' => _nw7.hasMatch(input),
    'itf14' => _itf14.hasMatch(input) && _checkDigitOk(input, 14),
    'upca' => _upca.hasMatch(input) && _checkDigitOk(input, 12),
    'upce' => _upce.hasMatch(input) && _checkDigitOk(input, 8),
    'gs1datamatrix' => _gs1DataMatrixOk(input),
    'pdf417' => input.length <= 1000,
    _ => false,
  };
}

bool _gs1DataMatrixOk(String input) {
  // 52: the longest input bwip-js takes, says pdfme
  if (input.length > 52) return false;
  RegExpMatch? m = _gtin.firstMatch(input);
  if (m == null) return false;
  String gtin = m.group(2)!;
  if (!const <int>[8, 12, 13, 14].contains(gtin.length)) return false;
  return _checkDigitOk(gtin, gtin.length);
}

/// pdfme's `validateCheckDigit` (GTIN): checked only when [input] has
/// [length] characters. Weights 3, 1, 3, ... from the right.
bool _checkDigitOk(String input, int length) {
  if (input.length != length) return true;
  return gtinCheckDigit(input.substring(0, input.length - 1)) ==
      input.substring(input.length - 1);
}

/// The GTIN check digit of [body] (the digits before the check digit).
/// Characters that are not digits are left out, like pdfme.
String gtinCheckDigit(String body) {
  String digits = body.replaceAll(RegExp('[^0-9]'), '');
  int sum = 0;
  bool odd = true;
  for (int i = digits.length - 1; i >= 0; i--) {
    sum += (digits.codeUnitAt(i) - 48) * (odd ? 3 : 1);
    odd = !odd;
  }
  String check = '${10 - sum % 10}';
  return check.substring(check.length - 1);
}
