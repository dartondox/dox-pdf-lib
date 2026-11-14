// Runs the full Dart examples of the "PDF/X and PDF/A" section of the
// README, so they keep working. The ICC profiles are the test profiles of
// conformance_test.dart, under the file names the examples use.
import 'dart:io';

import 'package:test/test.dart';

import 'icc_support.dart';

void main() {
  test('the PDF/X and PDF/A examples of the README run', () async {
    String readme = File('README.md').readAsStringSync();
    int start = readme.indexOf('### PDF/X and PDF/A');
    String section = readme.substring(start, readme.indexOf('\n## ', start));
    List<String> examples = <String>[
      for (RegExpMatch m in RegExp(
        r'```dart\n([\s\S]*?)```',
      ).allMatches(section))
        if (m[1]!.contains('Future<void> main')) m[1]!,
    ];
    expect(examples, hasLength(2));
    if (!await fetchTestProfiles()) {
      markTestSkipped('the ICC profiles could not be loaded');
      return;
    }
    File srgb = File('$testProfileDir/srgb.icc');
    File cmyk = File('$testProfileDir/cmyk.icc');
    Directory dir = Directory.systemTemp.createTempSync('dox_readme_');
    try {
      srgb.copySync('${dir.path}/sRGB2014.icc');
      cmyk.copySync('${dir.path}/ISOcoated_v2_eci.icc');
      File('test/fixtures/fonts/noto-sans-test.ttf')
          .copySync('${dir.path}/NotoSans-Regular.ttf');
      String packages = File('../../.dart_tool/package_config.json')
          .absolute
          .path;
      for (int i = 0; i < examples.length; i++) {
        File script = File('${dir.path}/example_$i.dart')
          ..writeAsStringSync(examples[i]);
        ProcessResult r = await Process.run(
          Platform.resolvedExecutable,
          <String>['run', '--packages=$packages', script.path],
          workingDirectory: dir.path,
        );
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        // the examples meet their standard: no issue is printed
        expect((r.stdout as String).trim(), isEmpty);
      }
      expect(File('${dir.path}/report.pdf').existsSync(), isTrue);
      expect(File('${dir.path}/flyer.pdf').existsSync(), isTrue);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
