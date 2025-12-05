import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/code_element.dart';
import '../models/code_scan_config.dart';
import '../utils/logger.dart';
import 'reference_resolver.dart';
import 'symbol_collector.dart';

/// Detects unused code by comparing declarations with references
class UnusedDetector {
  final CodeScanConfig config;
  final Logger logger;

  UnusedDetector({
    required this.config,
    required this.logger,
  });

  /// Detect unused code
  List<CodeIssue> detect({
    required SymbolCollection symbols,
    required ReferenceCollection references,
  }) {
    final issues = <CodeIssue>[];

    // Detect unused classes
    if (config.rules.unusedClasses.enabled) {
      issues.addAll(_detectUnusedClasses(symbols, references));
    }

    // Detect unused functions
    if (config.rules.unusedFunctions.enabled) {
      issues.addAll(_detectUnusedFunctions(symbols, references));
    }

    // Detect unused members (methods, fields, etc.)
    if (config.rules.unusedMembers.enabled) {
      issues.addAll(_detectUnusedMembers(symbols, references));
    }

    // Detect unused parameters
    if (config.rules.unusedParameters.enabled) {
      issues.addAll(_detectUnusedParameters(symbols, references));
    }

    // Detect unused imports
    if (config.rules.unusedImports.enabled) {
      issues.addAll(_detectUnusedImports(references));
    }

    // Filter by minimum severity
    return issues.where((issue) {
      return _severityMeetsMinimum(issue.severity, config.minSeverity);
    }).toList();
  }

  /// Detect unused classes, mixins, extensions, enums, typedefs
  List<CodeIssue> _detectUnusedClasses(
    SymbolCollection symbols,
    ReferenceCollection references,
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

      // Check if referenced
      if (!references.isTypeReferenced(declaration.name) &&
          !references.isReferenced(declaration.name)) {
        final category = _getCategoryForType(declaration.type);
        final message = _getMessageForUnusedType(declaration);

        issues.add(CodeIssue(
          category: category,
          severity: _getSeverityForCategory(category),
          symbol: declaration.name,
          location: declaration.location,
          message: message,
          suggestion: _getSuggestionForUnused(declaration),
          codeSnippet: _getCodeSnippet(declaration),
          canAutoFix: true,
          packageName: declaration.packageName,
        ));
      }
    }

    return issues;
  }

  /// Detect unused top-level functions
  List<CodeIssue> _detectUnusedFunctions(
    SymbolCollection symbols,
    ReferenceCollection references,
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

      // Check if referenced
      if (!references.isReferenced(function.name)) {
        issues.add(CodeIssue(
          category: IssueCategory.unusedFunction,
          severity: IssueSeverity.warning,
          symbol: function.name,
          location: function.location,
          message: "Function '${function.name}' is never called",
          suggestion: 'Remove the function or mark with @visibleForTesting',
          codeSnippet: _getCodeSnippet(function),
          canAutoFix: true,
          packageName: function.packageName,
        ));
      }
    }

    return issues;
  }

  /// Detect unused class members
  List<CodeIssue> _detectUnusedMembers(
    SymbolCollection symbols,
    ReferenceCollection references,
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

    for (final member in members) {
      // Skip overrides if configured
      if (config.excludeOverrides && member.isOverride) {
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

      // Check if referenced
      if (!references.isReferenced(member.name) &&
          !references.isReferenced(member.qualifiedName)) {
        final category = _getCategoryForMember(member.type);

        issues.add(CodeIssue(
          category: category,
          severity: IssueSeverity.warning,
          symbol: member.qualifiedName,
          location: member.location,
          message: _getMessageForUnusedMember(member),
          suggestion: _getSuggestionForUnused(member),
          codeSnippet: _getCodeSnippet(member),
          canAutoFix: !member.isOverride,
          packageName: member.packageName,
        ));
      }
    }

    return issues;
  }

  /// Detect unused parameters
  List<CodeIssue> _detectUnusedParameters(
    SymbolCollection symbols,
    ReferenceCollection references,
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

      // Check if referenced
      if (!references.isReferenced(param.name)) {
        issues.add(CodeIssue(
          category: IssueCategory.unusedParameter,
          severity: IssueSeverity.info,
          symbol: param.name,
          location: param.location,
          message: "Parameter '${param.name}' is never used",
          suggestion: 'Remove the parameter or prefix with underscore',
          codeSnippet: _getCodeSnippet(param),
          canAutoFix: false, // Parameters are harder to auto-fix
          packageName: param.packageName,
        ));
      }
    }

    return issues;
  }

  /// Detect unused imports
  List<CodeIssue> _detectUnusedImports(ReferenceCollection references) {
    final issues = <CodeIssue>[];

    for (final unusedImport in references.unusedImports) {
      // Skip dart:core
      if (unusedImport.uri == 'dart:core') continue;

      issues.add(CodeIssue(
        category: IssueCategory.unusedImport,
        severity: IssueSeverity.info,
        symbol: unusedImport.displayName,
        location: unusedImport.location,
        message: "Import '${unusedImport.uri}' is never used",
        suggestion: 'Remove the unused import',
        canAutoFix: true,
      ));
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
      'noSuchMethod',
    };
    return lifecycleMethods.contains(name);
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
      case IssueCategory.unusedImport:
      case IssueCategory.unusedVariable:
        return IssueSeverity.info;
      default:
        return IssueSeverity.warning;
    }
  }

  bool _severityMeetsMinimum(IssueSeverity severity, IssueSeverity minimum) {
    const order = [IssueSeverity.info, IssueSeverity.warning, IssueSeverity.error];
    return order.indexOf(severity) >= order.indexOf(minimum);
  }
}

