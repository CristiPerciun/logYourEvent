// Verifies that every package and the library constant carry the same
// version and, when a tag is given, that it matches.
//
//   dart tool/check_versions.dart            # consistency only
//   dart tool/check_versions.dart v0.1.0     # consistency + tag
//
// Exit code 0 when consistent, 1 otherwise. No package imports: runnable
// from a bare checkout.
import 'dart:io';

void main(List<String> args) {
  final root = Directory.current;
  final packagesDir = Directory('${root.path}${Platform.pathSeparator}packages');
  if (!packagesDir.existsSync()) {
    stderr.writeln('Run from the repository root (packages/ not found).');
    exitCode = 1;
    return;
  }
  final versions = <String, String>{};
  final versionPattern = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true);
  for (final entity in packagesDir.listSync()) {
    if (entity is! Directory) continue;
    final pubspec = File('${entity.path}${Platform.pathSeparator}pubspec.yaml');
    if (!pubspec.existsSync()) continue;
    final match = versionPattern.firstMatch(pubspec.readAsStringSync());
    final name = entity.path.split(Platform.pathSeparator).last;
    versions[name] = match?.group(1) ?? '<missing>';
  }
  final constantFile = File(
    '${packagesDir.path}${Platform.pathSeparator}lye_core${Platform.pathSeparator}lib'
    '${Platform.pathSeparator}src${Platform.pathSeparator}version.dart',
  );
  final constant = RegExp(r"const String lyeVersion = '([^']+)';")
      .firstMatch(constantFile.readAsStringSync())
      ?.group(1);
  versions['lye_core/lib/src/version.dart'] = constant ?? '<missing>';

  final distinct = versions.values.toSet();
  for (final entry in versions.entries) {
    stdout.writeln('${entry.key.padRight(32)} ${entry.value}');
  }
  var ok = distinct.length == 1 && !distinct.contains('<missing>');
  if (args.isNotEmpty) {
    final tag = args.first.startsWith('v') ? args.first.substring(1) : args.first;
    if (!distinct.contains(tag)) {
      stderr.writeln('Tag ${args.first} does not match the package version.');
      ok = false;
    }
  }
  stdout.writeln(ok ? 'versions: consistent' : 'versions: INCONSISTENT');
  exitCode = ok ? 0 : 1;
}
