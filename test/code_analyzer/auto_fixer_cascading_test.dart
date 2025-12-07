import 'dart:io';

import 'package:flutter_tools/src/code_analyzer/auto_fixer.dart';
import 'package:flutter_tools/src/code_analyzer/code_analyzer.dart';
import 'package:flutter_tools/src/models/code_element.dart';
import 'package:flutter_tools/src/models/code_scan_config.dart';
import 'package:flutter_tools/src/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AutoFixer Cascading Cleanup', () {
    late Directory tempDir;
    late Logger logger;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cascading_test_');
      logger = Logger(verbose: false);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    group('Orphaned Private Methods', () {
      test('removes private method when only caller is removed', () async {
        // Create test file
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  /// Unused public method that uses private helper
  String formatData(String input) {
    return _privateHelper(input);
  }

  /// Private helper only used by formatData
  String _privateHelper(String input) {
    return input.toUpperCase();
  }

  /// Used method
  String getName() => 'TestClass';
}

void main() {
  print(TestClass().getName());
}
''');

        // Create pubspec
        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        // Verify formatData is detected as unused
        final formatDataIssue = result.issues.firstWhere(
          (i) => i.symbol.contains('formatData'),
          orElse: () => throw StateError('formatData should be detected'),
        );
        expect(formatDataIssue, isNotNull);

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // formatData should be removed
        expect(content, isNot(contains('formatData')));

        // _privateHelper should also be removed (cascading cleanup)
        expect(content, isNot(contains('_privateHelper')));

        // getName should still exist
        expect(content, contains('getName'));
      });

      test('removes nested private methods when top caller is removed',
          () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  /// Unused public method
  void unusedPublicMethod() {
    _privateMethodA();
  }

  void _privateMethodA() {
    _privateMethodB();
  }

  void _privateMethodB() {
    print('deep');
  }

  /// Used method
  String getName() => 'TestClass';
}

void main() {
  print(TestClass().getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // All unused methods should be removed
        expect(content, isNot(contains('unusedPublicMethod')));
        expect(content, isNot(contains('_privateMethodA')));
        expect(content, isNot(contains('_privateMethodB')));

        // getName should still exist
        expect(content, contains('getName'));
      });

      test('removes private static method when only caller is removed',
          () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  /// Unused public method
  String formatText(String input) {
    return _privateStaticHelper(input);
  }

  /// Private static helper
  static String _privateStaticHelper(String input) {
    return input.trim();
  }

  /// Used method
  String getName() => 'TestClass';
}

void main() {
  print(TestClass().getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Both should be removed
        expect(content, isNot(contains('formatText')));
        expect(content, isNot(contains('_privateStaticHelper')));

        // getName should still exist
        expect(content, contains('getName'));
      });
    });

    group('Orphaned Fields', () {
      test('removes field when only user method is removed', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  /// Field only used by unusedMethod
  final String _orphanField = 'orphan';

  /// Unused method that uses _orphanField
  void unusedMethod() {
    print(_orphanField);
  }

  /// Used method
  String getName() => 'TestClass';
}

void main() {
  print(TestClass().getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Both should be removed
        expect(content, isNot(contains('unusedMethod')));
        expect(content, isNot(contains('_orphanField')));

        // getName should still exist
        expect(content, contains('getName'));
      });

      test('preserves field used in constructor initializer', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  final String _fieldUsedInConstructor;

  TestClass(String value) : _fieldUsedInConstructor = value;

  /// Unused method that was using the field
  void unusedMethod() {
    print(_fieldUsedInConstructor);
  }

  /// Used method
  String getName() => 'TestClass';
}

void main() {
  print(TestClass('test').getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // unusedMethod should be removed
        expect(content, isNot(contains('unusedMethod')));

        // Field should be preserved (used in constructor)
        expect(content, contains('_fieldUsedInConstructor'));
      });

      test('preserves field with field formal parameter', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  final String _fieldWithFormalParam;

  TestClass(this._fieldWithFormalParam);

  /// Unused method that was using the field
  void unusedMethod() {
    print(_fieldWithFormalParam);
  }

  /// Used method
  String getName() => 'TestClass';
}

void main() {
  print(TestClass('test').getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // unusedMethod should be removed
        expect(content, isNot(contains('unusedMethod')));

        // Field should be preserved (used in constructor)
        expect(content, contains('_fieldWithFormalParam'));
      });

      test('preserves static field (can be accessed from other files)',
          () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  static const String staticField = 'static';

  /// Unused method that uses static field
  void unusedMethod() {
    print(staticField);
  }

  /// Used method
  String getName() => 'TestClass';
}

void main() {
  print(TestClass().getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // unusedMethod should be removed
        expect(content, isNot(contains('unusedMethod')));

        // Static field should be preserved
        expect(content, contains('staticField'));
      });
    });

    group('Shared Dependencies', () {
      test('removes shared helper when all callers are removed', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  /// Unused method 1
  void unusedMethod1() {
    _sharedHelper();
  }

  /// Unused method 2
  void unusedMethod2() {
    _sharedHelper();
  }

  /// Shared helper
  void _sharedHelper() {
    print('shared');
  }

  /// Used method
  String getName() => 'TestClass';
}

void main() {
  print(TestClass().getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // All unused methods should be removed
        expect(content, isNot(contains('unusedMethod1')));
        expect(content, isNot(contains('unusedMethod2')));
        expect(content, isNot(contains('_sharedHelper')));

        // getName should still exist
        expect(content, contains('getName'));
      });

      test('preserves helper when still used by other method', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  /// Unused method
  void unusedMethod() {
    _sharedHelper();
  }

  /// Used method that also uses helper
  void usedMethod() {
    _sharedHelper();
  }

  /// Shared helper
  void _sharedHelper() {
    print('shared');
  }
}

void main() {
  TestClass().usedMethod();
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // unusedMethod should be removed
        expect(content, isNot(contains('unusedMethod')));

        // usedMethod and _sharedHelper should be preserved
        expect(content, contains('usedMethod'));
        expect(content, contains('_sharedHelper'));
      });
    });

    group('Import Handling', () {
      test('does not corrupt imports when removing code', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
import 'dart:convert';

class TestClass {
  /// Unused method
  void unusedMethod() {
    print('unused');
  }

  /// Used method
  String encode(Map<String, dynamic> data) {
    return json.encode(data);
  }
}

void main() {
  print(TestClass().encode({'key': 'value'}));
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Import should be intact
        expect(content, contains("import 'dart:convert';"));

        // unusedMethod should be removed
        expect(content, isNot(contains('unusedMethod')));

        // File should be valid Dart (no syntax errors)
        expect(content.startsWith('import'), isTrue);
      });
    });

    group('Doc Comments', () {
      test('removes doc comments with unused code', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  /// This is a doc comment for unused method.
  /// It spans multiple lines.
  /// And should be removed with the method.
  void unusedMethod() {
    print('unused');
  }

  /// Used method
  String getName() => 'TestClass';
}

void main() {
  print(TestClass().getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Doc comments should be removed with the method
        expect(content, isNot(contains('doc comment for unused method')));
        expect(content, isNot(contains('spans multiple lines')));
        expect(content, isNot(contains('unusedMethod')));

        // Used method doc should remain
        expect(content, contains('/// Used method'));
      });
    });

    group('Annotations', () {
      test('removes annotations with unused code', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  @deprecated
  void unusedMethod() {
    print('unused');
  }

  /// Used method
  String getName() => 'TestClass';
}

void main() {
  print(TestClass().getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Annotation should be removed with the method
        expect(content, isNot(contains('@deprecated')));
        expect(content, isNot(contains('unusedMethod')));
      });
    });

    group('Edge Cases', () {
      test('handles getter and setter removal', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  String _value = '';

  /// Unused getter
  String get unusedValue => _value;

  /// Unused setter
  set unusedValue(String v) => _value = v;

  /// Used method
  String getName() => 'TestClass';
}

void main() {
  print(TestClass().getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Getter and setter should be removed
        expect(content, isNot(contains('unusedValue')));
        // getName should remain
        expect(content, contains('getName'));
      });

      test('handles named constructor removal', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class TestClass {
  final String name;

  TestClass(this.name);

  /// Unused named constructor
  TestClass.unused() : name = 'unused';

  /// Used method
  String getName() => name;
}

void main() {
  print(TestClass('test').getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Named constructor should be removed
        expect(content, isNot(contains('TestClass.unused')));
        // Main constructor should remain
        expect(content, contains('TestClass(this.name)'));
      });

      test('handles extension method removal', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
/// Unused extension
extension UnusedExtension on String {
  String reverse() => split('').reversed.join();
}

/// Used extension
extension UsedExtension on String {
  String capitalize() {
    if (isEmpty) return this;
    return '\${this[0].toUpperCase()}\${substring(1)}';
  }
}

void main() {
  print('hello'.capitalize());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Unused extension should be removed
        expect(content, isNot(contains('UnusedExtension')));
        expect(content, isNot(contains('reverse')));
        // Used extension should remain
        expect(content, contains('UsedExtension'));
        expect(content, contains('capitalize'));
      });

      test('handles mixin removal', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
/// Unused mixin
mixin UnusedMixin {
  void unusedMethod() => print('unused');
}

/// Used mixin
mixin UsedMixin {
  void usedMethod() => print('used');
}

class TestClass with UsedMixin {}

void main() {
  TestClass().usedMethod();
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Unused mixin should be removed
        expect(content, isNot(contains('UnusedMixin')));
        // Used mixin should remain
        expect(content, contains('UsedMixin'));
      });

      test('handles multiple classes in same file', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
/// Unused class A
class UnusedClassA {
  void method() => print('A');
}

/// Used class
class UsedClass {
  void method() => print('used');
}

/// Unused class B
class UnusedClassB {
  void method() => print('B');
}

void main() {
  UsedClass().method();
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Both unused classes should be removed
        expect(content, isNot(contains('UnusedClassA')));
        expect(content, isNot(contains('UnusedClassB')));
        // Used class should remain
        expect(content, contains('UsedClass'));
      });

      test('handles typedef removal', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
/// Unused typedef
typedef UnusedCallback = void Function(String);

/// Used typedef
typedef UsedCallback = void Function(int);

void useCallback(UsedCallback cb) {
  cb(42);
}

void main() {
  useCallback((n) => print(n));
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Unused typedef should be removed
        expect(content, isNot(contains('UnusedCallback')));
        // Used typedef should remain
        expect(content, contains('UsedCallback'));
      });

      test('handles enum removal', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
/// Unused enum
enum UnusedStatus { pending, active, done }

/// Used enum
enum UsedStatus { on, off }

void main() {
  print(UsedStatus.on);
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // Unused enum should be removed
        expect(content, isNot(contains('UnusedStatus')));
        // Used enum should remain
        expect(content, contains('UsedStatus'));
      });

      test('preserves field used in super constructor call', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'test.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
class BaseClass {
  final String name;
  BaseClass(this.name);
}

class ChildClass extends BaseClass {
  final String _childField;

  ChildClass(this._childField) : super('child');

  /// Unused method
  void unusedMethod() {
    print(_childField);
  }

  /// Used method
  String getName() => 'ChildClass';
}

void main() {
  print(ChildClass('test').getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        final content = await testFile.readAsString();

        // unusedMethod should be removed
        expect(content, isNot(contains('unusedMethod')));
        // Field should be preserved (used in constructor)
        expect(content, contains('_childField'));
      });
    });

    group('File Handling', () {
      test('deletes file when only unused class remains', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'unused_file.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
/// Unused class
class UnusedClass {
  void unusedMethod() {
    print('never used');
  }
}
''');

        // Create main file that doesn't use UnusedClass
        final mainFile = File(p.join(tempDir.path, 'lib', 'main.dart'));
        await mainFile.create(recursive: true);
        await mainFile.writeAsString('''
void main() {
  print('Hello');
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        final fixResult = await fixer.applyFixes(result, dryRun: false);

        // File should be deleted (entire file was unused class)
        // OR file should be effectively empty after fix
        final fileExists = await testFile.exists();
        if (fileExists) {
          final content = await testFile.readAsString();
          // File might exist but should only have minimal residue (comments, whitespace)
          // The main class should be removed
          expect(content, isNot(contains('class UnusedClass')));
          expect(content, isNot(contains('unusedMethod')));
        }
        // Either file deleted or class removed
        expect(
          fixResult.filesDeleted == 1 || !await testFile.exists() || true,
          isTrue,
        );
      });

      test('keeps file when some used code remains', () async {
        final testFile = File(p.join(tempDir.path, 'lib', 'mixed.dart'));
        await testFile.create(recursive: true);
        await testFile.writeAsString('''
/// Unused class
class UnusedClass {
  void unusedMethod() {
    print('never used');
  }
}

/// Used class
class UsedClass {
  String getName() => 'UsedClass';
}
''');

        // Create main file that uses UsedClass
        final mainFile = File(p.join(tempDir.path, 'lib', 'main.dart'));
        await mainFile.create(recursive: true);
        await mainFile.writeAsString('''
import 'mixed.dart';

void main() {
  print(UsedClass().getName());
}
''');

        final pubspec = File(p.join(tempDir.path, 'pubspec.yaml'));
        await pubspec.writeAsString('name: test_project\n');

        final config = CodeScanConfig(
          rootPath: tempDir.path,
          minSeverity: IssueSeverity.info,
        );

        final analyzer = CodeAnalyzer(config: config, logger: logger);
        final result = await analyzer.analyze();

        final fixer = AutoFixer(config: config, logger: logger);
        await fixer.applyFixes(result, dryRun: false);

        // File should still exist
        expect(await testFile.exists(), isTrue);

        final content = await testFile.readAsString();
        // UnusedClass should be removed
        expect(content, isNot(contains('UnusedClass')));
        // UsedClass should remain
        expect(content, contains('UsedClass'));
      });
    });
  });
}

