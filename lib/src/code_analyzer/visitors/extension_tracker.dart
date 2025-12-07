import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';

import '../../models/code_element.dart';

/// Tracks extension method usage, including implicit calls.
///
/// This visitor specifically handles the case where extension methods
/// are called without explicitly naming the extension:
///
/// ```dart
/// extension StringExtension on String {
///   String capitalize() => ...;
/// }
///
/// // Implicit usage - hard to detect with AST-only analysis
/// final result = 'hello'.capitalize();
/// ```
class ExtensionTracker extends RecursiveAstVisitor<void> {
  /// Set of used extension names
  final Set<String> usedExtensions = {};

  /// Map of extension name to usage locations
  final Map<String, List<ExtensionUsage>> extensionUsages = {};

  /// Set of declared extension names in the codebase
  final Set<String> declaredExtensions = {};

  /// The resolved unit for semantic information
  final ResolvedUnitResult resolvedUnit;

  /// The file being visited
  final String filePath;

  ExtensionTracker({required this.resolvedUnit, required this.filePath});

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final name = node.name?.lexeme;
    if (name != null) {
      declaredExtensions.add(name);
    }
    super.visitExtensionDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _checkForExtensionUsage(node.methodName.staticElement, node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    _checkForExtensionUsage(node.propertyName.staticElement, node);
    super.visitPropertyAccess(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    // Check for extension operator[] usage
    final element = node.staticElement;
    _checkForExtensionUsage(element, node);
    super.visitIndexExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    // Check for extension operator usage (e.g., custom + operator)
    final element = node.staticElement;
    _checkForExtensionUsage(element, node);
    super.visitBinaryExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    // Check for extension prefix operator usage
    final element = node.staticElement;
    _checkForExtensionUsage(element, node);
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    // Check for extension postfix operator usage
    final element = node.staticElement;
    _checkForExtensionUsage(element, node);
    super.visitPostfixExpression(node);
  }

  void _checkForExtensionUsage(Element? element, AstNode node) {
    if (element == null) return;

    final enclosing = element.enclosingElement3;
    if (enclosing is ExtensionElement) {
      final extensionName = enclosing.name;
      if (extensionName != null && extensionName.isNotEmpty) {
        usedExtensions.add(extensionName);

        // Track usage details
        extensionUsages
            .putIfAbsent(extensionName, () => [])
            .add(
              ExtensionUsage(
                extensionName: extensionName,
                memberName: element.name ?? '',
                location: _locationFromNode(node),
                isImplicit: _isImplicitUsage(node),
                extendedType: enclosing.extendedType.toString(),
              ),
            );
      }
    }
  }

  /// Check if this is an implicit extension usage (no explicit extension name).
  bool _isImplicitUsage(AstNode node) {
    // If the target is not explicitly the extension type, it's implicit
    if (node is MethodInvocation) {
      final target = node.target;
      if (target == null) return true;
      // If target is just an expression (not ExtensionOverride), it's implicit
      if (target is! ExtensionOverride) return true;
    }
    if (node is PropertyAccess) {
      final target = node.target;
      if (target is! ExtensionOverride) return true;
    }
    return true;
  }

  SourceLocation _locationFromNode(AstNode node) {
    final lineInfo = resolvedUnit.lineInfo;
    final location = lineInfo.getLocation(node.offset);

    return SourceLocation(
      filePath: filePath,
      line: location.lineNumber,
      column: location.columnNumber,
      offset: node.offset,
      length: node.length,
    );
  }

  /// Get extensions that are declared but never used.
  Set<String> getUnusedExtensions() {
    return declaredExtensions.difference(usedExtensions);
  }

  /// Get all extension usages for a specific extension.
  List<ExtensionUsage> getUsagesFor(String extensionName) {
    return extensionUsages[extensionName] ?? [];
  }
}

/// Information about an extension usage.
class ExtensionUsage {
  /// Name of the extension
  final String extensionName;

  /// Name of the member being accessed
  final String memberName;

  /// Location of the usage
  final SourceLocation location;

  /// Whether this is an implicit usage (no explicit extension name)
  final bool isImplicit;

  /// The type being extended
  final String extendedType;

  const ExtensionUsage({
    required this.extensionName,
    required this.memberName,
    required this.location,
    required this.isImplicit,
    required this.extendedType,
  });

  @override
  String toString() {
    final implicitStr = isImplicit ? ' (implicit)' : '';
    return '$extensionName.$memberName on $extendedType$implicitStr at ${location.filePath}:${location.line}';
  }
}

/// Result of extension tracking analysis.
class ExtensionTrackingResult {
  /// All declared extensions
  final Set<String> declaredExtensions;

  /// All used extensions
  final Set<String> usedExtensions;

  /// Detailed usage information
  final Map<String, List<ExtensionUsage>> usages;

  const ExtensionTrackingResult({
    required this.declaredExtensions,
    required this.usedExtensions,
    required this.usages,
  });

  /// Get unused extensions
  Set<String> get unusedExtensions =>
      declaredExtensions.difference(usedExtensions);

  /// Merge with another result
  ExtensionTrackingResult merge(ExtensionTrackingResult other) {
    final mergedUsages = Map<String, List<ExtensionUsage>>.from(usages);
    for (final entry in other.usages.entries) {
      mergedUsages.update(
        entry.key,
        (existing) => [...existing, ...entry.value],
        ifAbsent: () => entry.value,
      );
    }

    return ExtensionTrackingResult(
      declaredExtensions: {...declaredExtensions, ...other.declaredExtensions},
      usedExtensions: {...usedExtensions, ...other.usedExtensions},
      usages: mergedUsages,
    );
  }
}








