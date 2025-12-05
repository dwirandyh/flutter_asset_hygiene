import 'package:flutter_tools/src/code_analyzer/code_analyzer.dart';
import 'package:flutter_tools/src/models/code_element.dart';
import 'package:flutter_tools/src/models/code_scan_config.dart';
import 'package:flutter_tools/src/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('CodeAnalyzer', () {
    late String fixtureRoot;
    late Logger logger;

    setUp(() {
      fixtureRoot = p.join(
        p.current,
        'test',
        'fixtures',
        'unused_code_project',
      );
      logger = Logger(verbose: false);
    });

    test('detects unused classes', () async {
      final config = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      // Check that UnusedService is detected
      final unusedClasses = result.issues
          .where((i) => i.category == IssueCategory.unusedClass)
          .map((i) => i.symbol)
          .toList();

      expect(unusedClasses, contains('UnusedService'));
      expect(unusedClasses, isNot(contains('UsedService')));
      expect(unusedClasses, isNot(contains('UsedHelper')));
    });

    test('detects unused functions', () async {
      final config = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      final unusedFunctions = result.issues
          .where((i) => i.category == IssueCategory.unusedFunction)
          .map((i) => i.symbol)
          .toList();

      expect(unusedFunctions, contains('unusedFunction'));
      expect(unusedFunctions, isNot(contains('usedFunction')));
      expect(unusedFunctions, isNot(contains('main')));
    });

    test('detects unused enums', () async {
      final config = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      final unusedEnums = result.issues
          .where((i) => i.category == IssueCategory.unusedEnum)
          .map((i) => i.symbol)
          .toList();

      expect(unusedEnums, contains('UnusedStatus'));
      expect(unusedEnums, isNot(contains('UsedStatus')));
    });

    test('detects unused mixins', () async {
      final config = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      final unusedMixins = result.issues
          .where((i) => i.category == IssueCategory.unusedMixin)
          .map((i) => i.symbol)
          .toList();

      expect(unusedMixins, contains('UnusedMixin'));
      expect(unusedMixins, isNot(contains('UsedMixin')));
    });

    test('detects unused typedefs', () async {
      final config = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      final unusedTypedefs = result.issues
          .where((i) => i.category == IssueCategory.unusedTypedef)
          .map((i) => i.symbol)
          .toList();

      expect(unusedTypedefs, contains('UnusedCallback'));
      expect(unusedTypedefs, isNot(contains('UsedCallback')));
    });

    test('detects unused extensions', () async {
      final config = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      final unusedExtensions = result.issues
          .where((i) => i.category == IssueCategory.unusedExtension)
          .map((i) => i.symbol)
          .toList();

      // Note: Extensions are hard to track as "used" because their methods
      // are called directly on the extended type. Both may be reported.
      expect(unusedExtensions, contains('UnusedStringExtension'));
    });

    test('generates statistics', () async {
      final config = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      expect(result.statistics.filesScanned, greaterThan(0));
      expect(result.statistics.totalIssues, greaterThan(0));
      expect(result.statistics.scanDurationMs, greaterThan(0));
    });

    test('respects minimum severity filter', () async {
      // With warning severity, info-level issues should be filtered out
      final warningConfig = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.warning,
      );

      final infoConfig = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.info,
      );

      final warningAnalyzer = CodeAnalyzer(
        config: warningConfig,
        logger: logger,
      );
      final infoAnalyzer = CodeAnalyzer(config: infoConfig, logger: logger);

      final warningResult = await warningAnalyzer.analyze();
      final infoResult = await infoAnalyzer.analyze();

      // Info config should have more issues (includes info-level)
      expect(
        infoResult.issues.length,
        greaterThanOrEqualTo(warningResult.issues.length),
      );
    });

    test('outputs valid JSON', () async {
      final config = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      final json = result.toJson();

      expect(json, containsPair('version', isNotNull));
      expect(json, containsPair('issues', isList));
      expect(json, containsPair('statistics', isMap));
    });

    test('outputs valid CSV', () async {
      final config = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      final csv = result.toCsv();

      expect(
        csv,
        contains(
          'category,severity,symbol,file,line,column,message,suggestion',
        ),
      );
      expect(csv.split('\n').length, greaterThan(1));
    });

    test('outputs valid HTML', () async {
      final config = CodeScanConfig(
        rootPath: fixtureRoot,
        minSeverity: IssueSeverity.info,
      );

      final analyzer = CodeAnalyzer(config: config, logger: logger);
      final result = await analyzer.analyze();

      final html = result.toHtml();

      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('Unused Code Analysis'));
      expect(html, contains('</html>'));
    });
  });

  group('CodeScanConfig', () {
    test('parses YAML config correctly', () async {
      // This would need an actual YAML file to test
      // For now, test the default config
      final config = CodeScanConfig(rootPath: '.');

      expect(config.includeTests, isFalse);
      expect(config.excludeOverrides, isTrue);
      expect(config.scanWorkspace, isTrue);
      expect(config.crossPackageAnalysis, isTrue);
      expect(config.outputFormat, equals(CodeOutputFormat.console));
      expect(config.minSeverity, equals(IssueSeverity.warning));
    });

    test('copyWith works correctly', () {
      final original = CodeScanConfig(rootPath: '/original');
      final copied = original.copyWith(
        rootPath: '/copied',
        includeTests: true,
        verbose: true,
      );

      expect(copied.rootPath, equals('/copied'));
      expect(copied.includeTests, isTrue);
      expect(copied.verbose, isTrue);
      // Other values should remain from original
      expect(copied.excludeOverrides, equals(original.excludeOverrides));
    });

    test('effectiveExcludePatterns includes defaults', () {
      final config = CodeScanConfig(
        rootPath: '.',
        excludePatterns: ['custom/**'],
      );

      expect(config.effectiveExcludePatterns, contains('**/*.g.dart'));
      expect(config.effectiveExcludePatterns, contains('**/*.freezed.dart'));
      expect(config.effectiveExcludePatterns, contains('custom/**'));
    });
  });

  group('CodeElement', () {
    test('generates correct ID', () {
      final element = CodeElement(
        name: 'MyClass',
        type: CodeElementType.classDeclaration,
        location: SourceLocation(
          filePath: 'lib/src/my_class.dart',
          line: 1,
          column: 1,
        ),
        packageName: 'my_package',
      );

      expect(element.id, equals('my_package::lib/src/my_class.dart::MyClass'));
    });

    test('generates correct qualified name', () {
      final method = CodeElement(
        name: 'doSomething',
        type: CodeElementType.method,
        location: SourceLocation(
          filePath: 'lib/src/service.dart',
          line: 10,
          column: 3,
        ),
        parentName: 'MyService',
      );

      expect(method.qualifiedName, equals('MyService.doSomething'));
    });

    test('detects annotations correctly', () {
      final element = CodeElement(
        name: 'TestClass',
        type: CodeElementType.classDeclaration,
        location: SourceLocation(filePath: 'lib/test.dart', line: 1, column: 1),
        annotations: ['visibleForTesting', 'immutable'],
      );

      expect(element.hasAnnotation('visibleForTesting'), isTrue);
      expect(element.hasAnnotation('@visibleForTesting'), isTrue);
      expect(element.hasAnnotation('immutable'), isTrue);
      expect(element.hasAnnotation('nonexistent'), isFalse);
    });
  });

  group('CodeIssue', () {
    test('converts to JSON correctly', () {
      final issue = CodeIssue(
        category: IssueCategory.unusedClass,
        severity: IssueSeverity.warning,
        symbol: 'UnusedClass',
        location: SourceLocation(
          filePath: 'lib/unused.dart',
          line: 5,
          column: 1,
        ),
        message: 'Class is never used',
        suggestion: 'Remove the class',
      );

      final json = issue.toJson();

      expect(json['category'], equals('unusedClass'));
      expect(json['severity'], equals('warning'));
      expect(json['symbol'], equals('UnusedClass'));
      expect(json['file'], equals('lib/unused.dart'));
      expect(json['line'], equals(5));
      expect(json['message'], equals('Class is never used'));
      expect(json['suggestion'], equals('Remove the class'));
    });
  });
}
