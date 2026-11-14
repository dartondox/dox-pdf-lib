// Helpers of the crosscheck test: test fonts, rendering with pdftoppm and
// comparing pages.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
  'NotoSansLao-Regular.ttf': (
    'https://raw.githubusercontent.com/notofonts/notofonts.github.io/'
        '1daf901bd023a3811498e0b7e7284694ae06307e/fonts/NotoSansLao/'
        'unhinted/ttf/NotoSansLao-Regular.ttf',
    'd3976b0ac08702c54999ff42eae295d1597fd73b44e0c57d7f4917524e18afbe',
  ),
  'NotoSansKhmer-Regular.ttf': (
    'https://raw.githubusercontent.com/notofonts/notofonts.github.io/'
        '1daf901bd023a3811498e0b7e7284694ae06307e/fonts/NotoSansKhmer/'
        'unhinted/ttf/NotoSansKhmer-Regular.ttf',
    '60c10dbfae33a44f1897cd939789bd173aedb7c7dc0a9af389a737e33cb7e548',
  ),
  'NotoSansMyanmar-Regular.ttf': (
    'https://raw.githubusercontent.com/notofonts/notofonts.github.io/'
        '1daf901bd023a3811498e0b7e7284694ae06307e/fonts/NotoSansMyanmar/'
        'unhinted/ttf/NotoSansMyanmar-Regular.ttf',
    'f4be6ef43871516d8347c5217a2033991b8ecda2dd1200007c2fb431a66d64db',
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

/// How one schema box looks in two renders of the same page.
class FieldDiff {
  FieldDiff(this.ink, this.pixels, this.inkA, this.inkB);

  /// The largest move (mm) of one edge of the ink box: the box around the
  /// pixels that are not white. Shows a field that is shorter, narrower or
  /// in another place.
  final double ink;

  /// The share of the pixels of the box (0 to 1) that differ.
  final double pixels;

  /// The ink boxes (left, top, right, bottom in mm) of each render.
  final List<double>? inkA;
  final List<double>? inkB;
}

/// Compares the box of [schema] (a pdfme schema in mm) in the pages [a] and
/// [b], rendered at [dpi]. The box turns around its center by `rotate`, and
/// gets a margin of [margin] mm.
FieldDiff fieldDifference(
  Ppm a,
  Ppm b,
  Map<String, dynamic> schema,
  int dpi, {
  double margin = 1,
  int threshold = 48,
}) {
  double px = dpi / 25.4;
  Map<String, dynamic> pos = schema['position'] as Map<String, dynamic>;
  double x = (pos['x'] as num).toDouble();
  double y = (pos['y'] as num).toDouble();
  double w = (schema['width'] as num).toDouble();
  double h = (schema['height'] as num).toDouble();
  double r = ((schema['rotate'] as num?) ?? 0) * math.pi / 180;
  double bw = (w * math.cos(r)).abs() + (h * math.sin(r)).abs();
  double bh = (w * math.sin(r)).abs() + (h * math.cos(r)).abs();
  double cx = x + w / 2;
  double cy = y + h / 2;
  int left = math.max(0, ((cx - bw / 2 - margin) * px).floor());
  int top = math.max(0, ((cy - bh / 2 - margin) * px).floor());
  int right = math.min(a.width, ((cx + bw / 2 + margin) * px).ceil());
  int bottom = math.min(a.height, ((cy + bh / 2 + margin) * px).ceil());
  if (right <= left || bottom <= top) return FieldDiff(0, 0, null, null);
  int differ = 0;
  for (int j = top; j < bottom; j++) {
    for (int i = left; i < right; i++) {
      int k = (j * a.width + i) * 3;
      for (int c = 0; c < 3; c++) {
        if ((a.pixels[k + c] - b.pixels[k + c]).abs() > threshold) {
          differ++;
          break;
        }
      }
    }
  }
  List<double>? inkA = a.inkBox(left, top, right, bottom, px);
  List<double>? inkB = b.inkBox(left, top, right, bottom, px);
  double ink = 0;
  if ((inkA == null) != (inkB == null)) {
    ink = double.infinity;
  } else if (inkA != null) {
    for (int i = 0; i < 4; i++) {
      ink = math.max(ink, (inkA[i] - inkB![i]).abs());
    }
  }
  return FieldDiff(ink, differ / ((right - left) * (bottom - top)), inkA, inkB);
}

extension on Ppm {
  /// The box (left, top, right, bottom in mm) around the pixels in the
  /// given pixel area with a channel below 240; null when there are none.
  List<double>? inkBox(int left, int top, int right, int bottom, double px) {
    int l = right, t = bottom, r = left - 1, b = top - 1;
    for (int j = top; j < bottom; j++) {
      for (int i = left; i < right; i++) {
        int k = (j * width + i) * 3;
        if (pixels[k] < 240 || pixels[k + 1] < 240 || pixels[k + 2] < 240) {
          if (i < l) l = i;
          if (i > r) r = i;
          if (j < t) t = j;
          if (j > b) b = j;
        }
      }
    }
    if (r < l) return null;
    return <double>[l / px, t / px, (r + 1) / px, (b + 1) / px];
  }
}

/// The edges (mm from the left side of the box) of the dark parts on one
/// line across the box of [schema]: the line at [v] (0 top, 1 bottom) of the
/// box height, in the box's own (turned) axes. Dark is darker than the
/// middle of the lightest and darkest pixels of the line.
List<double> scanEdges(
  Ppm page,
  Map<String, dynamic> schema,
  int dpi,
  double v,
) {
  double px = dpi / 25.4;
  Map<String, dynamic> pos = schema['position'] as Map<String, dynamic>;
  double w = (schema['width'] as num).toDouble();
  double h = (schema['height'] as num).toDouble();
  double cx = (pos['x'] as num).toDouble() + w / 2;
  double cy = (pos['y'] as num).toDouble() + h / 2;
  double r = ((schema['rotate'] as num?) ?? 0) * math.pi / 180;
  double step = 0.25 / px;
  List<int> light = <int>[];
  for (double t = 0; t <= w; t += step) {
    double lx = t - w / 2;
    double ly = v * h - h / 2;
    int x = ((cx + lx * math.cos(r) - ly * math.sin(r)) * px).floor();
    int y = ((cy + lx * math.sin(r) + ly * math.cos(r)) * px).floor();
    if (x < 0 || y < 0 || x >= page.width || y >= page.height) {
      light.add(255);
      continue;
    }
    int k = (y * page.width + x) * 3;
    light.add(
      (page.pixels[k] * 3 + page.pixels[k + 1] * 6 + page.pixels[k + 2]) ~/ 10,
    );
  }
  int lo = light.reduce(math.min);
  int hi = light.reduce(math.max);
  if (hi - lo < 40) return <double>[];
  int mid = (lo + hi) ~/ 2;
  List<double> edges = <double>[];
  bool dark = false;
  for (int i = 0; i < light.length; i++) {
    bool d = light[i] < mid;
    if (d != dark) edges.add(i * step);
    dark = d;
  }
  return edges;
}

/// The largest move (mm) between the edges [a] and [b]; infinity when they
/// do not have the same count.
double edgeDifference(List<double> a, List<double> b) {
  if (a.length != b.length) return double.infinity;
  double most = 0;
  for (int i = 0; i < a.length; i++) {
    most = math.max(most, (a[i] - b[i]).abs());
  }
  return most;
}
