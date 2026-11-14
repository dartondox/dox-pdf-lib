// Helpers of the crosscheck test: test fonts, rendering with pdftoppm and
// comparing pages.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const String crosscheckDir = 'tool/crosscheck';

bool get hasPdfme =>
    Directory('$crosscheckDir/node_modules/@pdfme/generator').existsSync();

bool hasTool(String name, [List<String> args = const <String>['-v']]) {
  try {
    Process.runSync(name, args);
    return true;
  } on ProcessException {
    return false;
  }
}

/// Test fonts: a fixed commit, checked with sha256 (the same files as the
/// dox_pdf_lib tests).
const Map<String, (String, String)> testFonts = <String, (String, String)>{
  'Lato-Regular.ttf': (
    'https://raw.githubusercontent.com/google/fonts/'
        '29b4ec6df2522a8aee279414b78a07910b065874/ofl/lato/Lato-Regular.ttf',
    'd636e4683231f931eda222d588e944d082bfd3bdba02f928bee461c0f185b251',
  ),
  'NotoSansJP-Regular.otf': (
    'https://raw.githubusercontent.com/notofonts/noto-cjk/'
        'f8d157532fbfaeda587e826d4cd5b21a49186f7c/'
        'Sans/SubsetOTF/JP/NotoSansJP-Regular.otf',
    'dff723ba59d57d136764a04b9b2d03205544f7cd785a711442d6d2d085ac5073',
  ),
  'NotoSansThai-Regular.ttf': (
    'https://raw.githubusercontent.com/notofonts/notofonts.github.io/'
        '1daf901bd023a3811498e0b7e7284694ae06307e/fonts/NotoSansThai/'
        'unhinted/ttf/NotoSansThai-Regular.ttf',
    'd4303fe9c63ebb72759ca8b6d2040c8ae81689f7d08d7b91c656154382b49313',
  ),
};

const String testFontDir = '.dart_tool/test_fonts';

/// Downloads the test fonts that are not there yet. False when it can not
/// (eg. offline).
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

/// A PPM image (`P6`) from pdftoppm.
class Ppm {
  Ppm(Uint8List data) {
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

  /// The darkest channel of pixel [x], [y] is below [limit].
  bool dark(int x, int y, [int limit = 128]) {
    int i = (y * width + x) * 3;
    return pixels[i] < limit && pixels[i + 1] < limit && pixels[i + 2] < limit;
  }
}

/// The pages of [pdf] as images at [dpi], in the new folder [dir].
List<Ppm> renderPages(String pdf, String dir, {int dpi = 72}) {
  Directory(dir).createSync(recursive: true);
  ProcessResult r = Process.runSync('pdftoppm', <String>[
    '-r',
    '$dpi',
    pdf,
    '$dir/p',
  ]);
  if (r.exitCode != 0) throw StateError('pdftoppm: ${r.stderr}');
  List<File> files = Directory(dir).listSync().whereType<File>().toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  return <Ppm>[for (File f in files) Ppm(f.readAsBytesSync())];
}

/// The share of pixels (0 to 1) whose colors differ by more than
/// [threshold] in one channel.
double pixelDifference(Ppm a, Ppm b, {int threshold = 48}) {
  Uint8List x = a.pixels;
  Uint8List y = b.pixels;
  int differ = 0;
  for (int i = 0; i < x.length; i += 3) {
    for (int c = 0; c < 3; c++) {
      if ((x[i + c] - y[i + c]).abs() > threshold) {
        differ++;
        break;
      }
    }
  }
  return differ / (x.length / 3);
}
