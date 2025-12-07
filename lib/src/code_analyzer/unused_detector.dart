import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/code_element.dart';
import '../models/code_scan_config.dart';
import '../utils/logger.dart';
import 'reference_resolver.dart';
import 'semantic_analyzer.dart';
import 'symbol_collector.dart';

/// Detects unused code by comparing declarations with references.
///
/// Supports both AST-only and semantic analysis modes:
/// - AST-only: Fast but name-based matching only
/// - Semantic: Accurate with extension/DI tracking
class UnusedDetector {
  final CodeScanConfig config;
  final Logger logger;

  UnusedDetector({required this.config, required this.logger});

  /// Detect unused code
  ///
  /// [semanticReferences] - Optional semantic references for accurate analysis
  /// [diTypes] - Optional set of types registered via DI (considered used)
  List<CodeIssue> detect({
    required SymbolCollection symbols,
    required ReferenceCollection references,
    SemanticReferenceCollection? semanticReferences,
    Set<String>? diTypes,
  }) {
    final issues = <CodeIssue>[];

    // Build inheritance hierarchy for interface/implementation tracking
    final inheritanceMap = _buildInheritanceMap(symbols);

    // Build abstract method to implementations mapping
    final abstractMethodImpls = _buildAbstractMethodImplementations(
      symbols,
      inheritanceMap,
    );

    // Create enhanced reference checker
    final refChecker = _ReferenceChecker(
      references: references,
      semanticReferences: semanticReferences,
      diTypes: diTypes ?? {},
      abstractMethodImplementations: abstractMethodImpls,
    );

    // Detect unused classes
    if (config.rules.unusedClasses.enabled) {
      issues.addAll(_detectUnusedClasses(symbols, refChecker));
    }

    // Detect unused functions
    if (config.rules.unusedFunctions.enabled) {
      issues.addAll(_detectUnusedFunctions(symbols, refChecker));
    }

    // Detect unused members (methods, fields, etc.)
    if (config.rules.unusedMembers.enabled) {
      issues.addAll(_detectUnusedMembers(symbols, refChecker));
    }

    // Detect unused parameters
    if (config.rules.unusedParameters.enabled) {
      issues.addAll(_detectUnusedParameters(symbols, refChecker));
    }

    // Detect unused imports
    if (config.rules.unusedImports.enabled) {
      issues.addAll(_detectUnusedImports(references, semanticReferences));
    }

    // Filter by minimum severity
    return issues.where((issue) {
      return _severityMeetsMinimum(issue.severity, config.minSeverity);
    }).toList();
  }

  /// Detect unused classes, mixins, extensions, enums, typedefs
  List<CodeIssue> _detectUnusedClasses(
    SymbolCollection symbols,
    _ReferenceChecker refChecker,
  ) {
    final issues = <CodeIssue>[];
    final ruleConfig = config.rules.unusedClasses;

    final typeDeclarations = [
      ...symbols.classes,
      ...symbols.mixins,
      ...symbols.extensions,
      ...symbols.enums,
      ...symbols.typedefs,
    ];

    for (final declaration in typeDeclarations) {
      // Skip if excluded by pattern
      if (_isExcludedByPattern(declaration.name, ruleConfig.excludePatterns)) {
        continue;
      }

      // Skip if excluded by annotation
      if (_hasExcludedAnnotation(declaration, ruleConfig.excludeAnnotations)) {
        continue;
      }

      // Skip public API if configured
      if (config.excludePublicApi && declaration.isPublic) {
        continue;
      }

      // Skip private if configured
      if (ruleConfig.excludePrivate && !declaration.isPublic) {
        continue;
      }

      // Check if referenced (using enhanced checker)
      if (!refChecker.isReferenced(declaration.name) &&
          !refChecker.isTypeReferenced(declaration.name)) {
        // For extensions, also check semantic extension usage or fallback to
        // member usage (helps when semantic analysis fails).
        if (declaration.type == CodeElementType.extensionDeclaration) {
          final extensionUsed =
              refChecker.isExtensionUsed(declaration.name) ||
              _isExtensionMemberUsed(symbols, declaration.name, refChecker);
          if (extensionUsed) {
            continue; // Extension is used implicitly via its members
          }
        }

        final category = _getCategoryForType(declaration.type);
        final message = _getMessageForUnusedType(declaration);

        issues.add(
          CodeIssue(
            category: category,
            severity: _getSeverityForCategory(category),
            symbol: declaration.name,
            location: declaration.location,
            message: message,
            suggestion: _getSuggestionForUnused(declaration),
            codeSnippet: _getCodeSnippet(declaration),
            canAutoFix: true,
            packageName: declaration.packageName,
          ),
        );
      }
    }

    return issues;
  }

  /// Detect unused top-level functions
  List<CodeIssue> _detectUnusedFunctions(
    SymbolCollection symbols,
    _ReferenceChecker refChecker,
  ) {
    final issues = <CodeIssue>[];
    final ruleConfig = config.rules.unusedFunctions;

    for (final function in symbols.functions) {
      // Skip main function
      if (function.name == 'main') continue;

      // Skip if excluded by pattern
      if (_isExcludedByPattern(function.name, ruleConfig.excludePatterns)) {
        continue;
      }

      // Skip if excluded by annotation
      if (_hasExcludedAnnotation(function, ruleConfig.excludeAnnotations)) {
        continue;
      }

      // Skip public if configured
      if (ruleConfig.excludePublic && function.isPublic) {
        continue;
      }

      // Skip private if configured
      if (ruleConfig.excludePrivate && !function.isPublic) {
        continue;
      }

      // Skip test-only functions (likely used in tests)
      if (_isTestingElement(function.name)) {
        continue;
      }

      // Check if referenced (using enhanced checker)
      if (!refChecker.isReferenced(function.name)) {
        issues.add(
          CodeIssue(
            category: IssueCategory.unusedFunction,
            severity: IssueSeverity.warning,
            symbol: function.name,
            location: function.location,
            message: "Function '${function.name}' is never called",
            suggestion: 'Remove the function or mark with @visibleForTesting',
            codeSnippet: _getCodeSnippet(function),
            canAutoFix: true,
            packageName: function.packageName,
          ),
        );
      }
    }

    return issues;
  }

  /// Detect unused class members
  List<CodeIssue> _detectUnusedMembers(
    SymbolCollection symbols,
    _ReferenceChecker refChecker,
  ) {
    final issues = <CodeIssue>[];
    final ruleConfig = config.rules.unusedMembers;

    final members = [
      ...symbols.methods,
      ...symbols.byType(CodeElementType.getter),
      ...symbols.byType(CodeElementType.setter),
      ...symbols.byType(CodeElementType.field),
      ...symbols.byType(CodeElementType.constructor),
    ];

    // Build a set of interface/abstract method names that have implementations
    // An override method "uses" the abstract method it implements
    final implementedMethods = <String>{};
    for (final member in members) {
      if (member.isOverride) {
        implementedMethods.add(member.name);
      }
    }

    for (final member in members) {
      // Skip overrides if configured
      if (config.excludeOverrides && member.isOverride) {
        continue;
      }

      // Skip abstract methods - they define interface contracts
      // They are "used" by their implementations
      if (member.isAbstract) {
        continue;
      }

      // Skip if excluded by pattern
      if (_isExcludedByPattern(member.name, ruleConfig.excludePatterns)) {
        continue;
      }

      // Skip if excluded by annotation
      if (_hasExcludedAnnotation(member, ruleConfig.excludeAnnotations)) {
        continue;
      }

      // Skip static if configured
      if (ruleConfig.excludeStatic && member.isStatic) {
        continue;
      }

      // Skip private if configured
      if (ruleConfig.excludePrivate && !member.isPublic) {
        continue;
      }

      // Skip common lifecycle methods
      if (_isLifecycleMethod(member.name)) {
        continue;
      }

      // Skip test-only members (likely used in tests)
      if (_isTestingElement(member.name)) {
        continue;
      }

      // Skip operator methods - they are called implicitly via operator syntax
      // e.g., `a + b` calls `operator+` on a
      if (_isOperatorMethod(member.name)) {
        continue;
      }

      // Check if referenced (using enhanced checker)
      // For operators, also check with 'operator' prefix
      final isReferenced =
          refChecker.isReferenced(member.name) ||
          refChecker.isReferenced(member.qualifiedName) ||
          refChecker.isReferenced('operator${member.name}');

      if (!isReferenced) {
        final category = _getCategoryForMember(member.type);

        issues.add(
          CodeIssue(
            category: category,
            severity: IssueSeverity.warning,
            symbol: member.qualifiedName,
            location: member.location,
            message: _getMessageForUnusedMember(member),
            suggestion: _getSuggestionForUnused(member),
            codeSnippet: _getCodeSnippet(member),
            canAutoFix: !member.isOverride && !member.isAbstract,
            packageName: member.packageName,
          ),
        );
      }
    }

    return issues;
  }

  /// Detect unused parameters
  List<CodeIssue> _detectUnusedParameters(
    SymbolCollection symbols,
    _ReferenceChecker refChecker,
  ) {
    final issues = <CodeIssue>[];
    final ruleConfig = config.rules.unusedParameters;

    final parameters = symbols.byType(CodeElementType.parameter);

    for (final param in parameters) {
      // Skip if excluded by pattern
      if (_isExcludedByPattern(param.name, ruleConfig.excludePatterns)) {
        continue;
      }

      // Skip override method parameters if configured
      if (ruleConfig.excludeOverrides) {
        // Check if parent function is an override
        final parentFunction = symbols.declarations.where(
          (d) => d.qualifiedName == param.parentName && d.isOverride,
        );
        if (parentFunction.isNotEmpty) continue;
      }

      // Check if referenced (using enhanced checker)
      if (!refChecker.isReferenced(param.name)) {
        issues.add(
          CodeIssue(
            category: IssueCategory.unusedParameter,
            severity: IssueSeverity.info,
            symbol: param.name,
            location: param.location,
            message: "Parameter '${param.name}' is never used",
            suggestion: 'Remove the parameter or prefix with underscore',
            codeSnippet: _getCodeSnippet(param),
            canAutoFix: false, // Parameters are harder to auto-fix
            packageName: param.packageName,
          ),
        );
      }
    }

    return issues;
  }

  /// Detect unused imports
  List<CodeIssue> _detectUnusedImports(
    ReferenceCollection references,
    SemanticReferenceCollection? semanticReferences,
  ) {
    final issues = <CodeIssue>[];

    // Use semantic references if available for more accurate detection
    if (semanticReferences != null && config.semantic.trackImportSymbols) {
      // Completely unused imports
      for (final unusedImport in semanticReferences.getUnusedImports()) {
        if (unusedImport.uri == 'dart:core') continue;

        issues.add(
          CodeIssue(
            category: IssueCategory.unusedImport,
            severity: IssueSeverity.warning,
            symbol: unusedImport.displayName,
            location: unusedImport.location,
            message: "Import '${unusedImport.uri}' is never used",
            suggestion: 'Remove the unused import',
            // NOTE: Auto-fix for imports is disabled because offset tracking
            // becomes invalid after other code in the same file is modified.
            // Use `dart fix` or IDE to remove unused imports after running --fix.
            canAutoFix: false,
          ),
        );
      }

      // Partially used imports (if enabled)
      if (config.semantic.reportPartialImports) {
        for (final partial in semanticReferences.getPartiallyUsedImports()) {
          issues.add(
            CodeIssue(
              category: IssueCategory.unusedImport,
              severity: IssueSeverity.warning,
              symbol: partial.uri,
              location: partial.location,
              message: partial.message,
              suggestion: partial.suggestion,
              canAutoFix: false,
            ),
          );
        }
      }
    } else {
      // Fallback to AST-only detection
      for (final unusedImport in references.unusedImports) {
        if (unusedImport.uri == 'dart:core') continue;

        issues.add(
          CodeIssue(
            category: IssueCategory.unusedImport,
            severity: IssueSeverity.warning,
            symbol: unusedImport.displayName,
            location: unusedImport.location,
            message: "Import '${unusedImport.uri}' is never used",
            suggestion: 'Remove the unused import',
            canAutoFix: false,
          ),
        );
      }
    }

    return issues;
  }

  bool _isExcludedByPattern(String name, List<String> patterns) {
    for (final pattern in patterns) {
      if (_matchesPattern(name, pattern)) {
        return true;
      }
    }
    return false;
  }

  bool _matchesPattern(String name, String pattern) {
    // Handle simple wildcard patterns
    if (pattern.startsWith('*') && pattern.endsWith('*')) {
      return name.contains(pattern.substring(1, pattern.length - 1));
    }
    if (pattern.startsWith('*')) {
      return name.endsWith(pattern.substring(1));
    }
    if (pattern.endsWith('*')) {
      return name.startsWith(pattern.substring(0, pattern.length - 1));
    }
    return name == pattern;
  }

  bool _hasExcludedAnnotation(CodeElement element, List<String> annotations) {
    // Always exclude certain annotations
    const alwaysExclude = [
      'visibleForTesting',
      'protected',
      'mustCallSuper',
      'pragma',
      'JsonKey',
      'JsonSerializable',
      'freezed',
      'injectable',
      'singleton',
      'lazySingleton',
      'riverpod',
      // Test-related
      'testOnly',
      'TestOnly',
    ];

    for (final annotation in element.annotations) {
      if (alwaysExclude.contains(annotation)) {
        return true;
      }
      if (annotations.contains(annotation) ||
          annotations.contains('@$annotation')) {
        return true;
      }
    }
    return false;
  }

  /// Check if element name suggests it's for testing purposes
  bool _isTestingElement(String name) {
    // Common patterns for test-only code
    return name.endsWith('ForTesting') ||
        name.endsWith('ForTest') ||
        name.startsWith('test') ||
        name.startsWith('mock') ||
        name.startsWith('fake') ||
        name.startsWith('stub') ||
        name.contains('Mock') ||
        name.contains('Fake') ||
        name.contains('Stub') ||
        name.contains('ForTesting') ||
        name.contains('ForTest') ||
        name == 'createForTesting' ||
        name == 'resetInstance' ||
        name == 'resetForTesting' ||
        name == 'setUpForTesting';
  }

  bool _isLifecycleMethod(String name) {
    const lifecycleMethods = {
      // Flutter widget lifecycle
      'initState',
      'didChangeDependencies',
      'didUpdateWidget',
      'deactivate',
      'dispose',
      'build', // Also used by Riverpod
      'createState',
      // BLoC
      'close',
      'onEvent',
      'onTransition',
      'onError',
      // GetX
      'onInit',
      'onReady',
      'onClose',
      // Common
      'toString',
      'hashCode',
      'operator==',
      '==',
      'noSuchMethod',
    };
    return lifecycleMethods.contains(name);
  }

  /// Check if a method is an operator method
  /// Operator methods are called implicitly via operator syntax (e.g., a + b)
  bool _isOperatorMethod(String name) {
    // Dart operator method names
    const operators = {
      // Arithmetic
      '+',
      '-',
      '*',
      '/',
      '~/',
      '%',
      // Unary
      'unary-',
      // Relational
      '<',
      '>',
      '<=',
      '>=',
      // Equality (already in lifecycle methods but include for completeness)
      '==',
      // Bitwise
      '&',
      '|',
      '^',
      '~',
      '<<',
      '>>',
      '>>>',
      // Index
      '[]',
      '[]=',
    };
    return operators.contains(name);
  }

  IssueCategory _getCategoryForType(CodeElementType type) {
    switch (type) {
      case CodeElementType.classDeclaration:
        return IssueCategory.unusedClass;
      case CodeElementType.mixinDeclaration:
        return IssueCategory.unusedMixin;
      case CodeElementType.extensionDeclaration:
        return IssueCategory.unusedExtension;
      case CodeElementType.enumDeclaration:
        return IssueCategory.unusedEnum;
      case CodeElementType.typedefDeclaration:
        return IssueCategory.unusedTypedef;
      default:
        return IssueCategory.unusedClass;
    }
  }

  IssueCategory _getCategoryForMember(CodeElementType type) {
    switch (type) {
      case CodeElementType.method:
        return IssueCategory.unusedMethod;
      case CodeElementType.getter:
        return IssueCategory.unusedGetter;
      case CodeElementType.setter:
        return IssueCategory.unusedSetter;
      case CodeElementType.field:
        return IssueCategory.unusedField;
      case CodeElementType.constructor:
        return IssueCategory.unusedConstructor;
      default:
        return IssueCategory.unusedMethod;
    }
  }

  String _getMessageForUnusedType(CodeElement element) {
    final typeStr = _getTypeString(element.type);
    return "$typeStr '${element.name}' is never used";
  }

  String _getMessageForUnusedMember(CodeElement element) {
    final typeStr = _getMemberTypeString(element.type);
    return "$typeStr '${element.name}' in '${element.parentName}' is never used";
  }

  String _getTypeString(CodeElementType type) {
    switch (type) {
      case CodeElementType.classDeclaration:
        return 'Class';
      case CodeElementType.mixinDeclaration:
        return 'Mixin';
      case CodeElementType.extensionDeclaration:
        return 'Extension';
      case CodeElementType.enumDeclaration:
        return 'Enum';
      case CodeElementType.typedefDeclaration:
        return 'Typedef';
      default:
        return 'Type';
    }
  }

  String _getMemberTypeString(CodeElementType type) {
    switch (type) {
      case CodeElementType.method:
        return 'Method';
      case CodeElementType.getter:
        return 'Getter';
      case CodeElementType.setter:
        return 'Setter';
      case CodeElementType.field:
        return 'Field';
      case CodeElementType.constructor:
        return 'Constructor';
      default:
        return 'Member';
    }
  }

  String _getSuggestionForUnused(CodeElement element) {
    if (element.isPublic) {
      return 'Remove or mark with @visibleForTesting if used in tests';
    }
    return 'Remove the unused ${_getTypeString(element.type).toLowerCase()}';
  }

  String? _getCodeSnippet(CodeElement element) {
    try {
      final file = File(p.join(config.rootPath, element.location.filePath));
      if (!file.existsSync()) return null;

      final lines = file.readAsLinesSync();
      final lineIndex = element.location.line - 1;
      if (lineIndex < 0 || lineIndex >= lines.length) return null;

      return lines[lineIndex].trim();
    } catch (e) {
      return null;
    }
  }

  IssueSeverity _getSeverityForCategory(IssueCategory category) {
    switch (category) {
      case IssueCategory.unusedClass:
      case IssueCategory.unusedMixin:
      case IssueCategory.unusedExtension:
      case IssueCategory.unusedEnum:
      case IssueCategory.unusedTypedef:
      case IssueCategory.unusedFunction:
      case IssueCategory.unusedMethod:
        return IssueSeverity.warning;
      case IssueCategory.unusedParameter:
      case IssueCategory.unusedVariable:
        return IssueSeverity.info;
      case IssueCategory.unusedImport:
        return IssueSeverity.warning;
      default:
        return IssueSeverity.warning;
    }
  }

  bool _severityMeetsMinimum(IssueSeverity severity, IssueSeverity minimum) {
    const order = [
      IssueSeverity.info,
      IssueSeverity.warning,
      IssueSeverity.error,
    ];
    return order.indexOf(severity) >= order.indexOf(minimum);
  }

  /// Build a map of class name -> all parent types (superclass, interfaces, mixins)
  Map<String, Set<String>> _buildInheritanceMap(SymbolCollection symbols) {
    final inheritanceMap = <String, Set<String>>{};

    for (final cls in symbols.classes) {
      final parents = <String>{};

      if (cls.superclassName != null) {
        parents.add(cls.superclassName!);
      }
      parents.addAll(cls.implementedInterfaces);
      parents.addAll(cls.mixins);

      inheritanceMap[cls.name] = parents;
    }

    // Resolve transitive inheritance (if A extends B and B extends C, A should know about C)
    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in inheritanceMap.entries) {
        final className = entry.key;
        final parents = entry.value;
        final newParents = <String>{};

        for (final parent in parents) {
          final grandParents = inheritanceMap[parent];
          if (grandParents != null) {
            for (final gp in grandParents) {
              if (!parents.contains(gp)) {
                newParents.add(gp);
                changed = true;
              }
            }
          }
        }

        if (newParents.isNotEmpty) {
          inheritanceMap[className] = {...parents, ...newParents};
        }
      }
    }

    return inheritanceMap;
  }

  /// Build a map of abstract method name -> list of implementing method qualified names
  ///
  /// This allows us to mark implementation methods as used when their abstract
  /// counterpart is referenced via the interface.
  ///
  /// Also tracks non-abstract methods in abstract classes that are overridden
  /// (common in plugin platform interface pattern where base methods throw
  /// UnimplementedError).
  Map<String, Set<String>> _buildAbstractMethodImplementations(
    SymbolCollection symbols,
    Map<String, Set<String>> inheritanceMap,
  ) {
    final abstractMethodImpls = <String, Set<String>>{};

    // Collect all abstract classes
    final abstractClasses = <String>{};
    for (final cls in symbols.classes) {
      if (cls.isAbstract) {
        abstractClasses.add(cls.name);
      }
    }

    // First, collect all abstract methods from abstract classes/interfaces
    // Also collect non-abstract methods in abstract classes (they may be
    // meant to be overridden - e.g., methods that throw UnimplementedError)
    final abstractMethods =
        <String, Set<String>>{}; // className -> method names
    final overridableMethods =
        <String, Set<String>>{}; // abstract class name -> method names

    for (final method in symbols.methods) {
      if (method.parentName == null) continue;

      if (method.isAbstract) {
        abstractMethods
            .putIfAbsent(method.parentName!, () => {})
            .add(method.name);
      } else if (abstractClasses.contains(method.parentName)) {
        // Non-abstract method in an abstract class - could be an overridable
        // interface method (e.g., platform interface pattern)
        overridableMethods
            .putIfAbsent(method.parentName!, () => {})
            .add(method.name);
      }
    }

    // Also collect getters/setters that are abstract or in abstract classes
    for (final getter in symbols.byType(CodeElementType.getter)) {
      if (getter.parentName == null) continue;

      if (getter.isAbstract) {
        abstractMethods
            .putIfAbsent(getter.parentName!, () => {})
            .add(getter.name);
      } else if (abstractClasses.contains(getter.parentName)) {
        overridableMethods
            .putIfAbsent(getter.parentName!, () => {})
            .add(getter.name);
      }
    }
    for (final setter in symbols.byType(CodeElementType.setter)) {
      if (setter.parentName == null) continue;

      if (setter.isAbstract) {
        abstractMethods
            .putIfAbsent(setter.parentName!, () => {})
            .add(setter.name);
      } else if (abstractClasses.contains(setter.parentName)) {
        overridableMethods
            .putIfAbsent(setter.parentName!, () => {})
            .add(setter.name);
      }
    }

    // Now, for each concrete class, find which methods it implements/overrides
    for (final cls in symbols.classes) {
      if (cls.isAbstract) continue; // Skip abstract classes

      final parents = inheritanceMap[cls.name] ?? {};

      for (final parent in parents) {
        // Check abstract methods
        final parentAbstractMethods = abstractMethods[parent];
        if (parentAbstractMethods != null) {
          _mapMethodImplementations(
            symbols,
            cls.name,
            parent,
            parentAbstractMethods,
            abstractMethodImpls,
          );
        }

        // Check overridable methods in abstract classes
        // These are methods that have bodies but are meant to be overridden
        final parentOverridableMethods = overridableMethods[parent];
        if (parentOverridableMethods != null) {
          _mapMethodImplementations(
            symbols,
            cls.name,
            parent,
            parentOverridableMethods,
            abstractMethodImpls,
            requireOverride: true, // Only count if marked with @override
          );
        }
      }
    }

    logger.debug(
      'Built abstract method implementations map with ${abstractMethodImpls.length} entries',
    );

    return abstractMethodImpls;
  }

  /// Helper to map method implementations from a parent class to a child class
  void _mapMethodImplementations(
    SymbolCollection symbols,
    String childClassName,
    String parentClassName,
    Set<String> methodNames,
    Map<String, Set<String>> implMap, {
    bool requireOverride = false,
  }) {
    for (final methodName in methodNames) {
      // Find the implementation in the child class
      final impl = symbols.declarations.where(
        (d) =>
            d.parentName == childClassName &&
            d.name == methodName &&
            !d.isAbstract &&
            (d.type == CodeElementType.method ||
                d.type == CodeElementType.getter ||
                d.type == CodeElementType.setter) &&
            (!requireOverride || d.isOverride),
      );

      if (impl.isNotEmpty) {
        // Map: "ParentClass.methodName" -> {"ConcreteClass.methodName", ...}
        final abstractKey = '$parentClassName.$methodName';
        implMap
            .putIfAbsent(abstractKey, () => {})
            .add('$childClassName.$methodName');

        // Also map by just method name for simpler lookups
        implMap
            .putIfAbsent(methodName, () => {})
            .add('$childClassName.$methodName');

        // IMPORTANT: Also add reverse mapping so when the abstract/base
        // method is referenced, the implementations are considered used,
        // AND vice versa - when an implementation is found, the base
        // method should be considered used too
        implMap.putIfAbsent(abstractKey, () => {}).add(abstractKey);
      }
    }
  }
}

/// Helper class for checking references with both AST and semantic data.
class _ReferenceChecker {
  final ReferenceCollection references;
  final SemanticReferenceCollection? semanticReferences;
  final Set<String> diTypes;

  /// Map of abstract method -> implementing methods
  /// Used to mark implementations as used when abstract method is called via interface
  final Map<String, Set<String>> abstractMethodImplementations;

  /// Cache of implementation methods that are considered used
  /// because their abstract counterpart is referenced
  late final Set<String> _usedImplementations;

  /// Cache of base class methods that are considered used
  /// because they have implementations that are referenced or exist
  late final Set<String> _usedBaseMethods;

  _ReferenceChecker({
    required this.references,
    this.semanticReferences,
    required this.diTypes,
    this.abstractMethodImplementations = const {},
  }) {
    _usedImplementations = _buildUsedImplementations();
    _usedBaseMethods = _buildUsedBaseMethods();
  }

  /// Build set of implementation method names that are used
  /// because their abstract method is referenced
  Set<String> _buildUsedImplementations() {
    final used = <String>{};

    for (final entry in abstractMethodImplementations.entries) {
      final abstractMethod = entry.key;
      final implementations = entry.value;

      // Check if the abstract method is referenced
      // This handles both "InterfaceName.methodName" and just "methodName"
      final isAbstractReferenced =
          references.isReferenced(abstractMethod) ||
          (semanticReferences?.usedElementIds.contains(abstractMethod) ??
              false);

      // Also check if just the method name part is referenced
      final methodNameOnly = abstractMethod.contains('.')
          ? abstractMethod.split('.').last
          : abstractMethod;
      final isMethodNameReferenced = references.isReferenced(methodNameOnly);

      if (isAbstractReferenced || isMethodNameReferenced) {
        // Mark all implementations as used
        used.addAll(implementations);
        // Also add just the method names
        for (final impl in implementations) {
          if (impl.contains('.')) {
            used.add(impl.split('.').last);
          }
        }
      }
    }

    return used;
  }

  /// Build set of base class method names that are considered used
  /// because they are part of an interface contract (have implementations)
  Set<String> _buildUsedBaseMethods() {
    final used = <String>{};

    for (final entry in abstractMethodImplementations.entries) {
      final baseMethod = entry.key;
      final implementations = entry.value;

      // A base method is "used" if it has any implementations
      // This handles the plugin platform interface pattern where base methods
      // throw UnimplementedError but are meant to be overridden
      if (implementations.isNotEmpty) {
        used.add(baseMethod);

        // Also add just the method name for simpler lookups
        if (baseMethod.contains('.')) {
          // But only if this is a qualified name (ClassName.methodName)
          // to avoid false positives
          final methodNameOnly = baseMethod.split('.').last;
          // Check if any implementation is actually referenced
          for (final impl in implementations) {
            if (references.isReferenced(impl) ||
                references.isReferenced(methodNameOnly) ||
                (semanticReferences?.usedElementIds.contains(impl) ?? false)) {
              used.add(methodNameOnly);
              break;
            }
          }
        }
      }
    }

    return used;
  }

  /// Check if an identifier is referenced.
  bool isReferenced(String identifier) {
    // Check DI types first
    if (diTypes.contains(identifier)) {
      return true;
    }

    // Check if this is an implementation of an abstract method that's used
    if (_usedImplementations.contains(identifier)) {
      return true;
    }

    // Check if this is a base class method that has implementations
    // (part of an interface contract - e.g., platform interface pattern)
    if (_usedBaseMethods.contains(identifier)) {
      return true;
    }

    // Check AST references
    if (references.isReferenced(identifier)) {
      return true;
    }

    // Check semantic references if available
    if (semanticReferences != null) {
      if (semanticReferences!.usedElementIds.contains(identifier)) {
        return true;
      }
      // Also check with simple name matching
      for (final elementId in semanticReferences!.usedElementIds) {
        if (elementId.endsWith('::$identifier')) {
          return true;
        }
      }
    }

    return false;
  }

  /// Check if a type is referenced.
  bool isTypeReferenced(String typeName) {
    // Check DI types first
    if (diTypes.contains(typeName)) {
      return true;
    }

    // Check AST references
    if (references.isTypeReferenced(typeName)) {
      return true;
    }

    // Check semantic references if available
    if (semanticReferences != null) {
      if (semanticReferences!.usedElementIds.contains(typeName)) {
        return true;
      }
    }

    return false;
  }

  /// Check if an extension is used (semantic mode only).
  bool isExtensionUsed(String extensionName) {
    if (semanticReferences != null) {
      return semanticReferences!.isExtensionUsed(extensionName);
    }
    return false;
  }
}

/// Check whether any member of an extension is referenced (AST fallback).
bool _isExtensionMemberUsed(
  SymbolCollection symbols,
  String extensionName,
  _ReferenceChecker refChecker,
) {
  final members = symbols.declarations.where(
    (d) =>
        d.parentName == extensionName &&
        (d.type == CodeElementType.method ||
            d.type == CodeElementType.getter ||
            d.type == CodeElementType.setter ||
            d.type == CodeElementType.field),
  );

  for (final member in members) {
    if (refChecker.isReferenced(member.name) ||
        refChecker.isReferenced(member.qualifiedName)) {
      return true;
    }
  }

  return false;
}
