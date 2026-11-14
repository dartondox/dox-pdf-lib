// Helpers of the crosscheck tests: render pages with pdftoppm and compare
// them, and fetch the test fonts.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

const String crosscheckDir = 'tool/crosscheck';

bool get hasNode =>
    Directory('$crosscheckDir/node_modules/pdf-lib').existsSync();

bool _tool(String name) {
  try {
    return Process.runSync(name, <String>['-v']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

bool get hasPdftoppm => _tool('pdftoppm');

bool get hasPdftotext => _tool('pdftotext');

/// Numbers as doubles, so 0 and 0.0 compare the same.
Object? asDoubles(Object? v) => switch (v) {
  num() => v.toDouble(),
  List<Object?>() => v.map(asDoubles).toList(),
  Map<String, Object?>() => v.map(
    (String k, Object? e) => MapEntry<String, Object?>(k, asDoubles(e)),
  ),
  _ => v,
};

/// A PPM image (`P6`) from pdftoppm.
class Ppm {
  Ppm(Uint8List data) {
    // header: P6 <w> <h> 255, each followed by one whitespace
    int pos = 0;
    List<int> values = <int>[];
    while (values.length < 3) {
      while (data[pos] <= 32) {
        pos++;
      }
      if (data[pos] == 0x50) {
        pos += 2; // "P6"
        continue;
      }
      int start = pos;
      while (data[pos] > 32) {
        pos++;
      }
      values.add(int.parse(ascii.decode(data.sublist(start, pos))));
    }
    width = values[0];
    height = values[1];
    pixels = Uint8List.sublistView(data, pos + 1);
  }

  late final int width;
  late final int height;
  late final Uint8List pixels;
}

/// The pages of [pdf] as images, in a new folder [dir].
Future<List<Ppm>> render(String pdf, String dir) async {
  Directory(dir).createSync();
  ProcessResult r = await Process.run('pdftoppm', <String>[
    '-r',
    '50',
    pdf,
    '$dir/p',
  ]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  List<File> files = Directory(dir).listSync().whereType<File>().toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  return <Ppm>[for (File f in files) Ppm(f.readAsBytesSync())];
}

/// Renders both files and expects the same pages.
Future<void> sameRender(String ours, String theirs, int pages) async {
  List<Ppm> a = await render(ours, '$ours.png');
  List<Ppm> b = await render(theirs, '$theirs.png');
  expect(a.length, pages);
  expect(b.length, pages);
  for (int page = 0; page < pages; page++) {
    expect((a[page].width, a[page].height), (b[page].width, b[page].height));
    int differ = 0;
    Uint8List x = a[page].pixels;
    Uint8List y = b[page].pixels;
    for (int i = 0; i < x.length; i += 3) {
      int d = 0;
      for (int c = 0; c < 3; c++) {
        int v = (x[i + c] - y[i + c]).abs();
        if (v > d) d = v;
      }
      if (d > 40) differ++;
    }
    // the same operators render the same; allow a few edge pixels that
    // float rounding may move
    expect(
      differ,
      lessThanOrEqualTo(20),
      reason: '$ours page ${page + 1}: $differ of ${x.length ~/ 3} differ',
    );
  }
}

/// The text of [pdf], from pdftotext.
Future<String> pdfText(String pdf) async {
  ProcessResult r = await Process.run('pdftotext', <String>[
    '-enc',
    'UTF-8',
    pdf,
    '-',
  ], stdoutEncoding: utf8);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return r.stdout as String;
}

/// Test fonts, all under the SIL Open Font License 1.1. They are too big to
/// keep in git, so they are downloaded once into `.dart_tool/test_fonts`,
/// from a fixed commit, and checked with sha256.
const Map<String, (String, String)> testFonts = <String, (String, String)>{
  'Lato-Regular.ttf': (
    'https://raw.githubusercontent.com/google/fonts/'
        '29b4ec6df2522a8aee279414b78a07910b065874/ofl/lato/Lato-Regular.ttf',
    'd636e4683231f931eda222d588e944d082bfd3bdba02f928bee461c0f185b251',
  ),
  'SourceSans3-Regular.otf': (
    'https://raw.githubusercontent.com/adobe-fonts/source-sans/'
        '87b37a2daaed80fcb8e8ccb0085c4d72ddade12e/OTF/SourceSans3-Regular.otf',
    '08df266400933d3178d081a45f94a08814c3e55b4b7dd2e0ff69cb1329f13ab6',
  ),
  'NotoSansJP-Regular.otf': (
    'https://raw.githubusercontent.com/notofonts/noto-cjk/'
        'f8d157532fbfaeda587e826d4cd5b21a49186f7c/'
        'Sans/SubsetOTF/JP/NotoSansJP-Regular.otf',
    'dff723ba59d57d136764a04b9b2d03205544f7cd785a711442d6d2d085ac5073',
  ),
  'NotoSans-Regular.ttf': (
    'https://raw.githubusercontent.com/notofonts/notofonts.github.io/'
        '1daf901bd023a3811498e0b7e7284694ae06307e/fonts/NotoSans/unhinted/ttf/NotoSans-Regular.ttf',
    'f3961a9cde016d41a4879aecda1474d3a36d6bf54fa0e4643de029cc2248b0e8',
  ),
  'NotoSansThai-Regular.ttf': (
    'https://raw.githubusercontent.com/notofonts/notofonts.github.io/'
        '1daf901bd023a3811498e0b7e7284694ae06307e/fonts/NotoSansThai/unhinted/ttf/NotoSansThai-Regular.ttf',
    'd4303fe9c63ebb72759ca8b6d2040c8ae81689f7d08d7b91c656154382b49313',
  ),
  'NotoSansMyanmar-Regular.ttf': (
    'https://raw.githubusercontent.com/notofonts/notofonts.github.io/'
        '1daf901bd023a3811498e0b7e7284694ae06307e/fonts/NotoSansMyanmar/unhinted/ttf/NotoSansMyanmar-Regular.ttf',
    'f4be6ef43871516d8347c5217a2033991b8ecda2dd1200007c2fb431a66d64db',
  ),
  'NotoSansKhmer-Regular.ttf': (
    'https://raw.githubusercontent.com/notofonts/notofonts.github.io/'
        '1daf901bd023a3811498e0b7e7284694ae06307e/fonts/NotoSansKhmer/unhinted/ttf/NotoSansKhmer-Regular.ttf',
    '60c10dbfae33a44f1897cd939789bd173aedb7c7dc0a9af389a737e33cb7e548',
  ),
  'NotoSansArabic-Regular.ttf': (
    'https://raw.githubusercontent.com/notofonts/notofonts.github.io/'
        '1daf901bd023a3811498e0b7e7284694ae06307e/fonts/NotoSansArabic/unhinted/ttf/NotoSansArabic-Regular.ttf',
    'bd86ca02f087d7f3c3788ba458fb6b73744c7639ed276b8d870dba6def6c40d0',
  ),
  'NotoSansDevanagari-Regular.ttf': (
    'https://raw.githubusercontent.com/notofonts/notofonts.github.io/'
        '1daf901bd023a3811498e0b7e7284694ae06307e/fonts/NotoSansDevanagari/unhinted/ttf/NotoSansDevanagari-Regular.ttf',
    '9c7d935139ea6a1e6ad9dbac4f6d27ece1e04bca8123c8888d00a0f9df4724cd',
  ),
  'NotoSansSC-Regular.otf': (
    'https://raw.githubusercontent.com/notofonts/noto-cjk/'
        'f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf',
    'faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9',
  ),
  'NotoSansKR-Regular.otf': (
    'https://raw.githubusercontent.com/notofonts/noto-cjk/'
        'f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/SubsetOTF/KR/NotoSansKR-Regular.otf',
    '69975a0ac8472717870aefeab0a4d52739308d90856b9955313b2ad5e0148d68',
  ),
  'IBMPlexSansArabic-Regular.ttf': (
    'https://raw.githubusercontent.com/google/fonts/'
        '29b4ec6df2522a8aee279414b78a07910b065874/ofl/ibmplexsansarabic/IBMPlexSansArabic-Regular.ttf',
    '6f611412270a132bbac838da9259d4c68569b4175f3b3b8fa3fa36a30b56dab9',
  ),
  'IBMPlexSansHebrew-Regular.ttf': (
    'https://raw.githubusercontent.com/google/fonts/'
        '29b4ec6df2522a8aee279414b78a07910b065874/ofl/ibmplexsanshebrew/IBMPlexSansHebrew-Regular.ttf',
    'c11df42adf5e2c6e77e623dbedbe8cc23ba72196ac9ad8beb02754eebd9c400a',
  ),
};

const String testFontDir = '.dart_tool/test_fonts';

/// Downloads the test fonts that are not there yet. Returns false when it
/// can not (eg. offline), so the tests that need them are skipped.
Future<bool> fetchTestFonts() async {
  Directory(testFontDir).createSync(recursive: true);
  HttpClient http = HttpClient();
  try {
    for (MapEntry<String, (String, String)> e in testFonts.entries) {
      File file = File('$testFontDir/${e.key}');
      if (file.existsSync() &&
          sha256.convert(file.readAsBytesSync()).toString() == e.value.$2) {
        continue;
      }
      HttpClientResponse res = await (await http.getUrl(Uri.parse(e.value.$1)))
          .close();
      BytesBuilder data = BytesBuilder(copy: false);
      await res.forEach(data.add);
      Uint8List bytes = data.takeBytes();
      if (sha256.convert(bytes).toString() != e.value.$2) return false;
      file.writeAsBytesSync(bytes);
    }
    return true;
  } on IOException {
    return false;
  } finally {
    http.close();
  }
}

Uint8List testFont(String name) => File('$testFontDir/$name').readAsBytesSync();
