import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// ICC profiles for the tests. We do not keep them in git: they are
/// downloaded once into `.dart_tool/test_icc`, from a fixed commit, and
/// checked with sha256.
const Map<String, (String, String)> testProfiles = <String, (String, String)>{
  // sRGB, ICC v2, CC0 (public domain), from Compact-ICC-Profiles
  'srgb.icc': (
    'https://raw.githubusercontent.com/saucecontrol/Compact-ICC-Profiles/'
        'bdd84663061bc4ae95ca70decff54f581e27f702/profiles/sRGB-v2-magic.icc',
    'af4efe28f6d311799865f325ba39184a2e978b113ca74124d60af7de22b105f4',
  ),
  // a CMYK output (prtr) profile, ICC v2, from Ghostscript
  'cmyk.icc': (
    'https://raw.githubusercontent.com/ArtifexSoftware/ghostpdl/'
        '852bc7460995ac285eeddef6a536ce158a711227/iccprofiles/default_cmyk.icc',
    '8472fa1493a024b800b67dee9424835ec0c41ab79490200ae8ec4a689fd1b9a9',
  ),
};

const String testProfileDir = '.dart_tool/test_icc';

/// Returns false when they can not be loaded (eg. offline).
Future<bool> fetchTestProfiles() async {
  Directory(testProfileDir).createSync(recursive: true);
  HttpClient http = HttpClient();
  try {
    for (MapEntry<String, (String, String)> e in testProfiles.entries) {
      File file = File('$testProfileDir/${e.key}');
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

Uint8List testProfile(String name) =>
    File('$testProfileDir/$name').readAsBytesSync();
