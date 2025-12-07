import 'dart:io';

import 'package:flutter_tools/src/code_analyzer/auto_fixer.dart';
import 'package:flutter_tools/src/code_analyzer/code_analyzer.dart';
import 'package:flutter_tools/src/models/code_element.dart';
import 'package:flutter_tools/src/models/code_scan_config.dart';
import 'package:flutter_tools/src/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AutoFixer', () {
    late Directory tempDir;
    late Logger logger;
    late String fixtureRoot;

    setUp(() async {
      fixtureRoot = p.join(
        p.current,
        'test',
        'fixtures',
        'unused_code_project',
      );

      tempDir = await Directory.systemTemp.createTemp('auto_fixer_test_');
      await _copyDirectory(Directory(fixtureRoot), tempDir);

      logger = Logger(verbose: false);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('removes auto-fixable unused code', () async {
      final config = CodeScanConfig(
        rootPath: tempDir.path,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      final fixer = AutoFixer(config: config, logger: logger);
      final fixResult = await fixer.applyFixes(result, dryRun: false);

      expect(fixResult.totalIssues, greaterThan(0));
      expect(fixResult.filesChanged, greaterThan(0));

      // Note: After removing unused code, some previously "used" elements
      // may become unused (e.g., if their callers were removed).
      // This is expected cascading behavior.
      final postResult = await analyzer.analyze();
      final originalIssueSymbols = result.issues.map((i) => i.symbol).toSet();
      final remainingOriginalIssues = postResult.issues
          .where((i) => i.canAutoFix && originalIssueSymbols.contains(i.symbol))
          .toList();
      expect(remainingOriginalIssues, isEmpty);

      final servicesPath = p.join(tempDir.path, 'lib', 'src', 'services.dart');
      final servicesContent = await File(servicesPath).readAsString();

      // Note: Unused imports are not auto-fixed (canAutoFix: false)
      // because import removal is error-prone. Use `dart fix` for imports.
      // expect(servicesContent, isNot(contains('dart:async')));
      expect(servicesContent, isNot(contains('_unusedMethod')));
      expect(servicesContent, isNot(contains('unusedGetter')));
      expect(servicesContent, isNot(contains('UnusedStringExtension')));
    });

    test('dry-run does not modify files', () async {
      final config = CodeScanConfig(
        rootPath: tempDir.path,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      final fixer = AutoFixer(config: config, logger: logger);
      final servicesPath = p.join(tempDir.path, 'lib', 'src', 'services.dart');
      final originalContent = await File(servicesPath).readAsString();

      final fixResult = await fixer.applyFixes(result, dryRun: true);

      expect(fixResult.totalIssues, greaterThan(0));
      expect(await File(servicesPath).readAsString(), equals(originalContent));
    });
  });
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relativePath = p.relative(entity.path, from: source.path);
    final newPath = p.join(destination.path, relativePath);

    if (entity is Directory) {
      await Directory(newPath).create(recursive: true);
    } else if (entity is File) {
      await File(newPath).create(recursive: true);
      await entity.copy(newPath);
    }
  }
}
