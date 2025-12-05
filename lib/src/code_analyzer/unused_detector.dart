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

    // Create enhanced reference checker
    final refChecker = _ReferenceChecker(
      references: references,
      semanticReferences: semanticReferences,
      diTypes: diTypes ?? {},
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
        // For extensions, also check semantic extension usage
        if (declaration.type == CodeElementType.extensionDeclaration) {
          if (refChecker.isExtensionUsed(declaration.name)) {
            continue; // Extension is used implicitly
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

      // Check if referenced (using enhanced checker)
      if (!refChecker.isReferenced(member.name) &&
          !refChecker.isReferenced(member.qualifiedName)) {
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
            canAutoFix: !member.isOverride,
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
            severity: IssueSeverity.info,
            symbol: unusedImport.displayName,
            location: unusedImport.location,
            message: "Import '${unusedImport.uri}' is never used",
            suggestion: 'Remove the unused import',
            canAutoFix: true,
          ),
        );
      }

      // Partially used imports (if enabled)
      if (config.semantic.reportPartialImports) {
        for (final partial in semanticReferences.getPartiallyUsedImports()) {
          issues.add(
            CodeIssue(
              category: IssueCategory.unusedImport,
              severity: IssueSeverity.info,
              symbol: partial.uri,
              location: partial.location,
              message: partial.message,
              suggestion: partial.suggestion,
              canAutoFix: true,
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
            severity: IssueSeverity.info,
            symbol: unusedImport.displayName,
            location: unusedImport.location,
            message: "Import '${unusedImport.uri}' is never used",
            suggestion: 'Remove the unused import',
            canAutoFix: true,
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
    const order = [
      IssueSeverity.info,
      IssueSeverity.warning,
      IssueSeverity.error,
    ];
    return order.indexOf(severity) >= order.indexOf(minimum);
  }
}

/// Helper class for checking references with both AST and semantic data.
class _ReferenceChecker {
  final ReferenceCollection references;
  final SemanticReferenceCollection? semanticReferences;
  final Set<String> diTypes;

  const _ReferenceChecker({
    required this.references,
    this.semanticReferences,
    required this.diTypes,
  });

  /// Check if an identifier is referenced.
  bool isReferenced(String identifier) {
    // Check DI types first
    if (diTypes.contains(identifier)) {
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
