import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import '../../models/code_element.dart';

/// AST Visitor to collect all references (usages) in a Dart file
class ReferenceVisitor extends RecursiveAstVisitor<void> {
  /// Collected references
  final List<CodeReference> references = [];

  /// Set of referenced identifiers (for quick lookup)
  final Set<String> referencedIdentifiers = {};

  /// Set of referenced types
  final Set<String> referencedTypes = {};

  /// Set of imported URIs that are used
  final Set<String> usedImports = {};

  /// Map of import prefix to URI
  final Map<String, String> _importPrefixes = {};

  /// The file being visited
  final String filePath;

  /// Package name (for monorepo support)
  final String? packageName;

  /// Parameters that are used in the current function
  final Set<String> _usedParameters = {};

  /// All parameters in the current function
  final Set<String> _currentParameters = {};

  ReferenceVisitor({
    required this.filePath,
    this.packageName,
  });

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

    // Collect parameters
    for (final param in node.parameters.parameters) {
      final name = _getParameterName(param);
      if (name != null) {
        _currentParameters.add(name);
      }
    }

    super.visitConstructorDeclaration(node);

    _currentParameters.clear();
    _usedParameters.clear();
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
  final String filePath;
  final String? packageName;

  const ReferenceResult({
    required this.references,
    required this.referencedIdentifiers,
    required this.referencedTypes,
    required this.usedImports,
    required this.filePath,
    this.packageName,
  });

  /// Merge multiple results
  static ReferenceResult merge(List<ReferenceResult> results) {
    final allReferences = <CodeReference>[];
    final allIdentifiers = <String>{};
    final allTypes = <String>{};
    final allImports = <String>{};

    for (final result in results) {
      allReferences.addAll(result.references);
      allIdentifiers.addAll(result.referencedIdentifiers);
      allTypes.addAll(result.referencedTypes);
      allImports.addAll(result.usedImports);
    }

    return ReferenceResult(
      references: allReferences,
      referencedIdentifiers: allIdentifiers,
      referencedTypes: allTypes,
      usedImports: allImports,
      filePath: '',
    );
  }
}

