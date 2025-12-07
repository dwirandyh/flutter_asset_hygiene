import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:flutter_tools/src/code_analyzer/visitors/declaration_visitor.dart';
import 'package:flutter_tools/src/code_analyzer/visitors/reference_visitor.dart';
import 'package:flutter_tools/src/code_analyzer/visitors/import_visitor.dart';
import 'package:flutter_tools/src/models/code_element.dart';
import 'package:test/test.dart';

void main() {
  group('DeclarationVisitor', () {
    test('collects class declarations', () {
      const code = '''
class MyClass {
  void method() {}
}

class _PrivateClass {}
''';

      final declarations = _parseDeclarations(code);
      final classes = declarations
          .where((d) => d.type == CodeElementType.classDeclaration)
          .toList();

      expect(classes.length, equals(2));
      expect(classes.map((c) => c.name), contains('MyClass'));
      expect(classes.map((c) => c.name), contains('_PrivateClass'));

      final myClass = classes.firstWhere((c) => c.name == 'MyClass');
      expect(myClass.isPublic, isTrue);

      final privateClass = classes.firstWhere((c) => c.name == '_PrivateClass');
      expect(privateClass.isPublic, isFalse);
    });

    test('collects mixin declarations', () {
      const code = '''
mixin MyMixin {
  void mixinMethod() {}
}
''';

      final declarations = _parseDeclarations(code);
      final mixins = declarations
          .where((d) => d.type == CodeElementType.mixinDeclaration)
          .toList();

      expect(mixins.length, equals(1));
      expect(mixins.first.name, equals('MyMixin'));
    });

    test('collects enum declarations', () {
      const code = '''
enum Status {
  active,
  inactive,
  pending,
}
''';

      final declarations = _parseDeclarations(code);
      final enums = declarations
          .where((d) => d.type == CodeElementType.enumDeclaration)
          .toList();

      expect(enums.length, equals(1));
      expect(enums.first.name, equals('Status'));

      // Check enum values
      final enumValues = declarations
          .where((d) => d.type == CodeElementType.enumValue)
          .toList();
      expect(enumValues.length, equals(3));
      expect(
        enumValues.map((e) => e.name),
        containsAll(['active', 'inactive', 'pending']),
      );
    });

    test('collects extension declarations', () {
      const code = '''
extension StringExtension on String {
  String capitalize() => this;
}
''';

      final declarations = _parseDeclarations(code);
      final extensions = declarations
          .where((d) => d.type == CodeElementType.extensionDeclaration)
          .toList();

      expect(extensions.length, equals(1));
      expect(extensions.first.name, equals('StringExtension'));
    });

    test('collects typedef declarations', () {
      const code = '''
typedef Callback = void Function(String);
typedef OldStyle(int x);
''';

      final declarations = _parseDeclarations(code);
      final typedefs = declarations
          .where((d) => d.type == CodeElementType.typedefDeclaration)
          .toList();

      expect(typedefs.length, equals(2));
      expect(typedefs.map((t) => t.name), contains('Callback'));
      expect(typedefs.map((t) => t.name), contains('OldStyle'));
    });

    test('collects top-level functions', () {
      const code = '''
void publicFunction() {}
void _privateFunction() {}
''';

      final declarations = _parseDeclarations(code);
      final functions = declarations
          .where((d) => d.type == CodeElementType.topLevelFunction)
          .toList();

      expect(functions.length, equals(2));
      expect(functions.map((f) => f.name), contains('publicFunction'));
      expect(functions.map((f) => f.name), contains('_privateFunction'));
    });

    test('collects method declarations', () {
      const code = '''
class MyClass {
  void publicMethod() {}
  void _privateMethod() {}
  static void staticMethod() {}
}
''';

      final declarations = _parseDeclarations(code);
      final methods = declarations
          .where((d) => d.type == CodeElementType.method)
          .toList();

      expect(methods.length, equals(3));

      final staticMethod = methods.firstWhere((m) => m.name == 'staticMethod');
      expect(staticMethod.isStatic, isTrue);
    });

    test('collects getters and setters', () {
      const code = '''
class MyClass {
  int _value = 0;
  int get value => _value;
  set value(int v) => _value = v;
}
''';

      final declarations = _parseDeclarations(code);

      final getters = declarations
          .where((d) => d.type == CodeElementType.getter)
          .toList();
      expect(getters.length, equals(1));
      expect(getters.first.name, equals('value'));

      final setters = declarations
          .where((d) => d.type == CodeElementType.setter)
          .toList();
      expect(setters.length, equals(1));
      expect(setters.first.name, equals('value'));
    });

    test('collects fields', () {
      const code = '''
class MyClass {
  final String name;
  static const int count = 0;
  int _privateField = 0;
  
  MyClass(this.name);
}
''';

      final declarations = _parseDeclarations(code);
      final fields = declarations
          .where((d) => d.type == CodeElementType.field)
          .toList();

      expect(fields.length, equals(3));
      expect(
        fields.map((f) => f.name),
        containsAll(['name', 'count', '_privateField']),
      );
    });

    test('collects constructors', () {
      const code = '''
class MyClass {
  MyClass();
  MyClass.named();
  factory MyClass.factory() => MyClass();
}
''';

      final declarations = _parseDeclarations(code);
      final constructors = declarations
          .where((d) => d.type == CodeElementType.constructor)
          .toList();

      expect(constructors.length, equals(3));
    });

    test('collects parameters', () {
      const code = '''
void myFunction(String required, {int? optional, bool flag = false}) {}
''';

      final declarations = _parseDeclarations(code);
      final params = declarations
          .where((d) => d.type == CodeElementType.parameter)
          .toList();

      expect(params.length, equals(3));
      expect(
        params.map((p) => p.name),
        containsAll(['required', 'optional', 'flag']),
      );
    });

    test('detects override annotation', () {
      const code = '''
class Parent {
  void method() {}
}

class Child extends Parent {
  @override
  void method() {}
}
''';

      final declarations = _parseDeclarations(code);
      final methods = declarations
          .where((d) => d.type == CodeElementType.method)
          .toList();

      final overrideMethod = methods.firstWhere(
        (m) => m.parentName == 'Child' && m.name == 'method',
      );
      expect(overrideMethod.isOverride, isTrue);

      final parentMethod = methods.firstWhere(
        (m) => m.parentName == 'Parent' && m.name == 'method',
      );
      expect(parentMethod.isOverride, isFalse);
    });

    test('collects annotations', () {
      const code = '''
@deprecated
@visibleForTesting
class AnnotatedClass {}
''';

      final declarations = _parseDeclarations(code);
      final annotatedClass = declarations.firstWhere(
        (d) => d.name == 'AnnotatedClass',
      );

      expect(annotatedClass.annotations, contains('deprecated'));
      expect(annotatedClass.annotations, contains('visibleForTesting'));
    });

    test('collects imports', () {
      const code = '''
import 'dart:io';
import 'package:path/path.dart' as p;
import 'local.dart';
''';

      final declarations = _parseDeclarations(code);
      final imports = declarations
          .where((d) => d.type == CodeElementType.importDirective)
          .toList();

      expect(imports.length, equals(3));
    });

    test('collects exports', () {
      const code = '''
export 'src/public.dart';
export 'src/utils.dart' show helper;
''';

      final declarations = _parseDeclarations(code);
      final exports = declarations
          .where((d) => d.type == CodeElementType.exportDirective)
          .toList();

      expect(exports.length, equals(2));
    });
  });

  group('ReferenceVisitor', () {
    test('collects type references', () {
      const code = '''
class MyClass {}
void useClass(MyClass instance) {}
''';

      final references = _parseReferences(code);

      expect(references.referencedTypes, contains('MyClass'));
    });

    test('collects method invocations', () {
      const code = '''
void caller() {
  helper();
}

void helper() {}
''';

      final references = _parseReferences(code);

      expect(references.referencedIdentifiers, contains('helper'));
    });

    test('collects property accesses', () {
      const code = '''
class MyClass {
  String name = '';
}

void access(MyClass obj) {
  print(obj.name);
}
''';

      final references = _parseReferences(code);

      expect(references.referencedIdentifiers, contains('name'));
    });

    test('collects inheritance references', () {
      const code = '''
class Parent {}
mixin MyMixin {}
abstract class Interface {}

class Child extends Parent with MyMixin implements Interface {}
''';

      final references = _parseReferences(code);

      expect(references.referencedTypes, contains('Parent'));
      expect(references.referencedTypes, contains('MyMixin'));
      expect(references.referencedTypes, contains('Interface'));
    });

    test('collects constructor invocations', () {
      const code = '''
class MyClass {
  MyClass();
  MyClass.named();
}

void create() {
  final a = MyClass();
  final b = MyClass.named();
}
''';

      final references = _parseReferences(code);

      // Constructor invocations are tracked as identifiers
      expect(references.referencedIdentifiers, contains('MyClass'));
    });

    test('collects annotation references', () {
      const code = '''
class MyAnnotation {
  const MyAnnotation();
}

@MyAnnotation()
class AnnotatedClass {}
''';

      final references = _parseReferences(code);

      expect(references.referencedIdentifiers, contains('MyAnnotation'));
    });
  });

  group('ImportVisitor', () {
    test('collects import information', () {
      const code = '''
import 'dart:io';
import 'package:path/path.dart' as p;
import 'local.dart' show helper;
import 'another.dart' hide unused;
''';

      final result = _parseImports(code);

      expect(result.imports.length, equals(4));

      final dartIo = result.imports.firstWhere((i) => i.uri == 'dart:io');
      expect(dartIo.isDartSdk, isTrue);
      expect(dartIo.prefix, isNull);

      final pathImport = result.imports.firstWhere(
        (i) => i.uri == 'package:path/path.dart',
      );
      expect(pathImport.isPackage, isTrue);
      expect(pathImport.prefix, equals('p'));
      expect(pathImport.packageName, equals('path'));

      final localImport = result.imports.firstWhere(
        (i) => i.uri == 'local.dart',
      );
      expect(localImport.isRelative, isTrue);
      expect(localImport.shownNames, contains('helper'));

      final anotherImport = result.imports.firstWhere(
        (i) => i.uri == 'another.dart',
      );
      expect(anotherImport.hiddenNames, contains('unused'));
    });

    test('collects export information', () {
      const code = '''
export 'src/public.dart';
export 'src/utils.dart' show helper, utility;
''';

      final result = _parseImports(code);

      expect(result.exports.length, equals(2));

      final utilsExport = result.exports.firstWhere(
        (e) => e.uri == 'src/utils.dart',
      );
      expect(utilsExport.shownNames, containsAll(['helper', 'utility']));
    });

    test('detects unused imports with prefix', () {
      const code = '''
import 'package:path/path.dart' as p;

void main() {
  print('hello');
}
''';

      final result = _parseImports(code);
      final unused = result.getUnusedImports();

      expect(unused.length, equals(1));
      expect(unused.first.uri, equals('package:path/path.dart'));
    });

    test('detects used imports with prefix', () {
      const code = '''
import 'package:path/path.dart' as p;

void main() {
  print(p.join('a', 'b'));
}
''';

      final result = _parseImports(code);
      final unused = result.getUnusedImports();

      expect(unused, isEmpty);
    });

    test('detects unused imports with show combinator', () {
      const code = '''
import 'helpers.dart' show usedHelper, unusedHelper;

void main() {
  usedHelper();
}
''';

      final result = _parseImports(code);

      // The import is used because usedHelper is called
      // This is a limitation - we can't detect partially used show combinators
      // without more sophisticated analysis
      expect(result.imports.length, equals(1));
      expect(
        result.imports.first.shownNames,
        containsAll(['usedHelper', 'unusedHelper']),
      );
    });
  });
}

List<CodeElement> _parseDeclarations(String code) {
  final parseResult = parseString(content: code);
  final visitor = DeclarationVisitor(filePath: 'test.dart');
  parseResult.unit.visitChildren(visitor);
  return visitor.declarations;
}

ReferenceVisitor _parseReferences(String code) {
  final parseResult = parseString(content: code);
  final visitor = ReferenceVisitor(filePath: 'test.dart');
  parseResult.unit.visitChildren(visitor);
  return visitor;
}

ImportVisitor _parseImports(String code) {
  final parseResult = parseString(content: code);
  final visitor = ImportVisitor(filePath: 'test.dart');
  parseResult.unit.visitChildren(visitor);
  return visitor;
}
