import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';

import '../../models/code_element.dart';

/// AST Visitor to collect all references (usages) in a Dart file.
///
/// Supports two modes:
/// - AST-only mode (default): Fast but name-based matching only
/// - Semantic mode: Slower but accurate with full type resolution
class ReferenceVisitor extends RecursiveAstVisitor<void> {
  /// Collected references
  final List<CodeReference> references = [];

  /// Set of referenced identifiers (for quick lookup)
  final Set<String> referencedIdentifiers = {};

  /// Set of referenced types
  final Set<String> referencedTypes = {};

  /// Set of imported URIs that are used
  final Set<String> usedImports = {};

  /// Set of used extension names (semantic mode only)
  final Set<String> usedExtensions = {};

  /// Set of fully qualified element IDs (semantic mode only)
  final Set<String> usedElementIds = {};

  /// Map of import prefix to URI
  final Map<String, String> _importPrefixes = {};

  /// The file being visited
  final String filePath;

  /// Package name (for monorepo support)
  final String? packageName;

  /// Resolved unit for semantic analysis (optional)
  final ResolvedUnitResult? resolvedUnit;

  /// Parameters that are used in the current function
  final Set<String> _usedParameters = {};

  /// All parameters in the current function
  final Set<String> _currentParameters = {};

  ReferenceVisitor({
    required this.filePath,
    this.packageName,
    this.resolvedUnit,
  });

  /// Whether semantic analysis is available
  bool get hasSemanticInfo => resolvedUnit != null;

  @override
  void visitImportDirective(ImportDirective node) {
    final uri = node.uri.stringValue ?? '';
    final prefix = node.prefix?.name;
    if (prefix != null) {
      _importPrefixes[prefix] = uri;
    }
    super.visitImportDirective(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // Skip if this is a declaration, not a reference
    if (node.inDeclarationContext()) {
      super.visitSimpleIdentifier(node);
      return;
    }

    final name = node.name;
    referencedIdentifiers.add(name);

    // Track parameter usage
    if (_currentParameters.contains(name)) {
      _usedParameters.add(name);
    }

    // Semantic mode: track element usage
    if (hasSemanticInfo) {
      final element = node.staticElement;
      if (element != null) {
        _trackElementUsage(element, node);
      }
    }

    // Create reference
    final reference = CodeReference(
      elementId: name,
      location: _locationFromNode(node),
      type: _determineReferenceType(node),
      packageName: packageName,
    );
    references.add(reference);

    super.visitSimpleIdentifier(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final prefix = node.prefix.name;
    final identifier = node.identifier.name;

    // Check if this is an import prefix
    if (_importPrefixes.containsKey(prefix)) {
      usedImports.add(_importPrefixes[prefix]!);
    }

    referencedIdentifiers.add(identifier);
    referencedIdentifiers.add('$prefix.$identifier');

    final reference = CodeReference(
      elementId: '$prefix.$identifier',
      location: _locationFromNode(node),
      type: _determineReferenceType(node),
      packageName: packageName,
    );
    references.add(reference);

    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final name = node.name2.lexeme;
    referencedTypes.add(name);
    referencedIdentifiers.add(name);

    final reference = CodeReference(
      elementId: name,
      location: _locationFromNode(node),
      type: ReferenceType.typeUsage,
      packageName: packageName,
    );
    references.add(reference);

    // Also track import usage for prefixed types
    final importPrefix = node.importPrefix;
    if (importPrefix != null) {
      final prefix = importPrefix.name.lexeme;
      if (_importPrefixes.containsKey(prefix)) {
        usedImports.add(_importPrefixes[prefix]!);
      }
    }

    super.visitNamedType(node);
  }

  @override
  void visitExtendsClause(ExtendsClause node) {
    final typeName = node.superclass.name2.lexeme;
    referencedTypes.add(typeName);
    referencedIdentifiers.add(typeName);

    final reference = CodeReference(
      elementId: typeName,
      location: _locationFromNode(node),
      type: ReferenceType.inheritance,
      packageName: packageName,
    );
    references.add(reference);

    super.visitExtendsClause(node);
  }

  @override
  void visitImplementsClause(ImplementsClause node) {
    for (final interface in node.interfaces) {
      final typeName = interface.name2.lexeme;
      referencedTypes.add(typeName);
      referencedIdentifiers.add(typeName);

      final reference = CodeReference(
        elementId: typeName,
        location: _locationFromNode(node),
        type: ReferenceType.inheritance,
        packageName: packageName,
      );
      references.add(reference);
    }
    super.visitImplementsClause(node);
  }

  @override
  void visitWithClause(WithClause node) {
    for (final mixin in node.mixinTypes) {
      final typeName = mixin.name2.lexeme;
      referencedTypes.add(typeName);
      referencedIdentifiers.add(typeName);

      final reference = CodeReference(
        elementId: typeName,
        location: _locationFromNode(node),
        type: ReferenceType.inheritance,
        packageName: packageName,
      );
      references.add(reference);
    }
    super.visitWithClause(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final methodName = node.methodName.name;
    referencedIdentifiers.add(methodName);

    // Track target if it's a type
    final target = node.target;
    if (target is SimpleIdentifier) {
      referencedIdentifiers.add(target.name);
    }

    // Semantic mode: check for extension method usage
    if (hasSemanticInfo) {
      final element = node.methodName.staticElement;
      if (element != null) {
        _trackElementUsage(element, node);

        // Check for extension method
        final enclosing = element.enclosingElement3;
        if (enclosing is ExtensionElement) {
          final extensionName = enclosing.name;
          if (extensionName != null && extensionName.isNotEmpty) {
            usedExtensions.add(extensionName);
            referencedIdentifiers.add(extensionName);
          }
        }
      }
    }

    final reference = CodeReference(
      elementId: methodName,
      location: _locationFromNode(node),
      type: ReferenceType.invocation,
      packageName: packageName,
    );
    references.add(reference);

    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final typeName = node.constructorName.type.name2.lexeme;
    referencedTypes.add(typeName);
    referencedIdentifiers.add(typeName);

    // Track named constructor
    final constructorName = node.constructorName.name?.name;
    if (constructorName != null) {
      referencedIdentifiers.add('$typeName.$constructorName');
    }

    final reference = CodeReference(
      elementId: typeName,
      location: _locationFromNode(node),
      type: ReferenceType.invocation,
      packageName: packageName,
    );
    references.add(reference);

    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    // Track operator usage (e.g., a + b uses operator+)
    // This is important for classes that define custom operators
    final operatorName = 'operator${node.operator.lexeme}';
    referencedIdentifiers.add(operatorName);

    // Also track the simple operator token for matching
    referencedIdentifiers.add(node.operator.lexeme);

    // Semantic mode: track the actual operator element
    if (hasSemanticInfo) {
      final element = node.staticElement;
      if (element != null) {
        _trackElementUsage(element, node);
      }
    }

    super.visitBinaryExpression(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    // Track operator[] usage
    referencedIdentifiers.add('operator[]');
    referencedIdentifiers.add('[]');

    // Semantic mode: track the actual operator element
    if (hasSemanticInfo) {
      final element = node.staticElement;
      if (element != null) {
        _trackElementUsage(element, node);
      }
    }

    super.visitIndexExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    // Track prefix operator usage (e.g., -a, !a, ++a)
    final operatorName = 'operator${node.operator.lexeme}';
    referencedIdentifiers.add(operatorName);

    // Semantic mode: track the actual operator element
    if (hasSemanticInfo) {
      final element = node.staticElement;
      if (element != null) {
        _trackElementUsage(element, node);
      }
    }

    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    // Track postfix operator usage (e.g., a++, a--)
    final operatorName = 'operator${node.operator.lexeme}';
    referencedIdentifiers.add(operatorName);

    // Semantic mode: track the actual operator element
    if (hasSemanticInfo) {
      final element = node.staticElement;
      if (element != null) {
        _trackElementUsage(element, node);
      }
    }

    super.visitPostfixExpression(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _currentParameters.clear();
    _usedParameters.clear();

    // Collect parameters
    final params = node.functionExpression.parameters;
    if (params != null) {
      for (final param in params.parameters) {
        final name = _getParameterName(param);
        if (name != null) {
          _currentParameters.add(name);
        }
      }
    }

    super.visitFunctionDeclaration(node);

    // After visiting, record unused parameters
    _currentParameters.clear();
    _usedParameters.clear();
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _currentParameters.clear();
    _usedParameters.clear();

    // Collect parameters
    final params = node.parameters;
    if (params != null) {
      for (final param in params.parameters) {
        final name = _getParameterName(param);
        if (name != null) {
          _currentParameters.add(name);
        }
      }
    }

    super.visitMethodDeclaration(node);

    _currentParameters.clear();
    _usedParameters.clear();
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    _currentParameters.clear();
    _usedParameters.clear();

    // Collect parameters and track field formal parameters as field references
    for (final param in node.parameters.parameters) {
      final name = _getParameterName(param);
      if (name != null) {
        _currentParameters.add(name);
      }

      // Track field formal parameters (this.fieldName) as references to fields
      // This is crucial - fields used in constructors via this.fieldName ARE used
      _trackFieldFormalParameter(param);
    }

    super.visitConstructorDeclaration(node);

    _currentParameters.clear();
    _usedParameters.clear();
  }

  /// Track field formal parameters (this.fieldName) as references to fields
  void _trackFieldFormalParameter(FormalParameter param) {
    FieldFormalParameter? fieldParam;

    if (param is FieldFormalParameter) {
      fieldParam = param;
    } else if (param is DefaultFormalParameter) {
      final inner = param.parameter;
      if (inner is FieldFormalParameter) {
        fieldParam = inner;
      }
    }

    if (fieldParam != null) {
      final fieldName = fieldParam.name.lexeme;
      // Mark the field as referenced - it's used in the constructor!
      referencedIdentifiers.add(fieldName);

      final reference = CodeReference(
        elementId: fieldName,
        location: _locationFromNode(fieldParam),
        type: ReferenceType.assignment,
        packageName: packageName,
      );
      references.add(reference);
    }
  }

  @override
  void visitAnnotation(Annotation node) {
    final name = node.name.name;
    referencedIdentifiers.add(name);
    referencedTypes.add(name);

    final reference = CodeReference(
      elementId: name,
      location: _locationFromNode(node),
      type: ReferenceType.annotation,
      packageName: packageName,
    );
    references.add(reference);

    super.visitAnnotation(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final propertyName = node.propertyName.name;
    referencedIdentifiers.add(propertyName);

    // Semantic mode: check for extension property usage
    if (hasSemanticInfo) {
      final element = node.propertyName.staticElement;
      if (element != null) {
        _trackElementUsage(element, node);

        // Check for extension property
        final enclosing = element.enclosingElement3;
        if (enclosing is ExtensionElement) {
          final extensionName = enclosing.name;
          if (extensionName != null && extensionName.isNotEmpty) {
            usedExtensions.add(extensionName);
            referencedIdentifiers.add(extensionName);
          }
        }
      }
    }

    final reference = CodeReference(
      elementId: propertyName,
      location: _locationFromNode(node),
      type: ReferenceType.propertyAccess,
      packageName: packageName,
    );
    references.add(reference);

    super.visitPropertyAccess(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final leftSide = node.leftHandSide;
    if (leftSide is SimpleIdentifier) {
      final name = leftSide.name;
      referencedIdentifiers.add(name);

      // Track parameter usage
      if (_currentParameters.contains(name)) {
        _usedParameters.add(name);
      }

      final reference = CodeReference(
        elementId: name,
        location: _locationFromNode(node),
        type: ReferenceType.assignment,
        packageName: packageName,
      );
      references.add(reference);
    }
    super.visitAssignmentExpression(node);
  }

  String? _getParameterName(FormalParameter param) {
    if (param is SimpleFormalParameter) {
      return param.name?.lexeme;
    } else if (param is DefaultFormalParameter) {
      return _getParameterName(param.parameter);
    } else if (param is FieldFormalParameter) {
      return param.name.lexeme;
    } else if (param is SuperFormalParameter) {
      return param.name.lexeme;
    }
    return null;
  }

  ReferenceType _determineReferenceType(AstNode node) {
    final parent = node.parent;

    if (parent is MethodInvocation) {
      return ReferenceType.invocation;
    }
    if (parent is InstanceCreationExpression) {
      return ReferenceType.invocation;
    }
    if (parent is NamedType) {
      return ReferenceType.typeUsage;
    }
    if (parent is ExtendsClause ||
        parent is ImplementsClause ||
        parent is WithClause) {
      return ReferenceType.inheritance;
    }
    if (parent is PropertyAccess) {
      return ReferenceType.propertyAccess;
    }
    if (parent is AssignmentExpression) {
      return ReferenceType.assignment;
    }
    if (parent is Annotation) {
      return ReferenceType.annotation;
    }

    return ReferenceType.read;
  }

  /// Track element usage with full semantic information (semantic mode only).
  void _trackElementUsage(Element element, AstNode node) {
    final elementId = _getElementId(element);
    usedElementIds.add(elementId);

    // Also add the simple name for backward compatibility
    final name = element.name;
    if (name != null && name.isNotEmpty) {
      usedElementIds.add(name);
    }
  }

  /// Get a unique ID for an element.
  String _getElementId(Element element) {
    final parts = <String>[];

    // Add library URI
    final library = element.library;
    if (library != null) {
      parts.add(library.source.uri.toString());
    }

    // Add enclosing elements
    Element? current = element.enclosingElement3;
    final enclosingNames = <String>[];
    while (current != null && current is! LibraryElement) {
      final name = current.name;
      if (name != null && name.isNotEmpty) {
        enclosingNames.insert(0, name);
      }
      current = current.enclosingElement3;
    }
    parts.addAll(enclosingNames);

    // Add element name
    final name = element.name;
    if (name != null && name.isNotEmpty) {
      parts.add(name);
    }

    return parts.join('::');
  }

  SourceLocation _locationFromNode(AstNode node) {
    final root = node.root;
    LineInfo? lineInfo;
    if (root is CompilationUnit) {
      lineInfo = root.lineInfo;
    }
    final location = lineInfo?.getLocation(node.offset);
    return SourceLocation(
      filePath: filePath,
      line: location?.lineNumber ?? 0,
      column: location?.columnNumber ?? 0,
      offset: node.offset,
      length: node.length,
    );
  }

  /// Get unused parameters for a function
  Set<String> getUnusedParameters() {
    return _currentParameters.difference(_usedParameters);
  }
}

/// Result of reference collection
class ReferenceResult {
  final List<CodeReference> references;
  final Set<String> referencedIdentifiers;
  final Set<String> referencedTypes;
  final Set<String> usedImports;
  final Set<String> usedExtensions;
  final Set<String> usedElementIds;
  final String filePath;
  final String? packageName;

  const ReferenceResult({
    required this.references,
    required this.referencedIdentifiers,
    required this.referencedTypes,
    required this.usedImports,
    this.usedExtensions = const {},
    this.usedElementIds = const {},
    required this.filePath,
    this.packageName,
  });

  /// Merge multiple results
  static ReferenceResult merge(List<ReferenceResult> results) {
    final allReferences = <CodeReference>[];
    final allIdentifiers = <String>{};
    final allTypes = <String>{};
    final allImports = <String>{};
    final allExtensions = <String>{};
    final allElementIds = <String>{};

    for (final result in results) {
      allReferences.addAll(result.references);
      allIdentifiers.addAll(result.referencedIdentifiers);
      allTypes.addAll(result.referencedTypes);
      allImports.addAll(result.usedImports);
      allExtensions.addAll(result.usedExtensions);
      allElementIds.addAll(result.usedElementIds);
    }

    return ReferenceResult(
      references: allReferences,
      referencedIdentifiers: allIdentifiers,
      referencedTypes: allTypes,
      usedImports: allImports,
      usedExtensions: allExtensions,
      usedElementIds: allElementIds,
      filePath: '',
    );
  }
}
