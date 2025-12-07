import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import '../../models/code_element.dart';

/// AST Visitor to collect all declarations in a Dart file
class DeclarationVisitor extends RecursiveAstVisitor<void> {
  /// Collected declarations
  final List<CodeElement> declarations = [];

  /// The file being visited
  final String filePath;

  /// Package name (for monorepo support)
  final String? packageName;

  /// Current class/mixin/extension being visited
  String? _currentParent;

  /// Whether the current parent class is abstract
  bool _currentParentIsAbstract = false;

  DeclarationVisitor({required this.filePath, this.packageName});

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final annotations = _extractAnnotations(node.metadata);
    final isAbstract = node.abstractKeyword != null;

    // Extract inheritance information
    final superclassName = node.extendsClause?.superclass.name2.lexeme;
    final implementedInterfaces =
        node.implementsClause?.interfaces.map((i) => i.name2.lexeme).toList() ??
        [];
    final mixins =
        node.withClause?.mixinTypes.map((m) => m.name2.lexeme).toList() ?? [];

    final element = CodeElement(
      name: node.name.lexeme,
      type: CodeElementType.classDeclaration,
      location: _locationFromNode(node),
      isPublic: !node.name.lexeme.startsWith('_'),
      isAbstract: isAbstract,
      annotations: annotations,
      documentation: _extractDocumentation(node),
      packageName: packageName,
      superclassName: superclassName,
      implementedInterfaces: implementedInterfaces,
      mixins: mixins,
    );
    declarations.add(element);

    // Visit class members
    _currentParent = node.name.lexeme;
    _currentParentIsAbstract = isAbstract;
    super.visitClassDeclaration(node);
    _currentParent = null;
    _currentParentIsAbstract = false;
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    final annotations = _extractAnnotations(node.metadata);
    final element = CodeElement(
      name: node.name.lexeme,
      type: CodeElementType.mixinDeclaration,
      location: _locationFromNode(node),
      isPublic: !node.name.lexeme.startsWith('_'),
      annotations: annotations,
      documentation: _extractDocumentation(node),
      packageName: packageName,
    );
    declarations.add(element);

    _currentParent = node.name.lexeme;
    super.visitMixinDeclaration(node);
    _currentParent = null;
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final name = node.name?.lexeme ?? '<unnamed>';
    if (name == '<unnamed>') {
      // Skip unnamed extensions as they can't be referenced
      super.visitExtensionDeclaration(node);
      return;
    }

    final annotations = _extractAnnotations(node.metadata);
    final element = CodeElement(
      name: name,
      type: CodeElementType.extensionDeclaration,
      location: _locationFromNode(node),
      isPublic: !name.startsWith('_'),
      annotations: annotations,
      documentation: _extractDocumentation(node),
      packageName: packageName,
    );
    declarations.add(element);

    _currentParent = name;
    super.visitExtensionDeclaration(node);
    _currentParent = null;
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    final annotations = _extractAnnotations(node.metadata);
    final element = CodeElement(
      name: node.name.lexeme,
      type: CodeElementType.enumDeclaration,
      location: _locationFromNode(node),
      isPublic: !node.name.lexeme.startsWith('_'),
      annotations: annotations,
      documentation: _extractDocumentation(node),
      packageName: packageName,
    );
    declarations.add(element);

    // Visit enum values
    _currentParent = node.name.lexeme;
    for (final constant in node.constants) {
      final valueElement = CodeElement(
        name: constant.name.lexeme,
        type: CodeElementType.enumValue,
        location: _locationFromNode(constant),
        isPublic: true,
        parentName: node.name.lexeme,
        annotations: _extractAnnotations(constant.metadata),
        packageName: packageName,
      );
      declarations.add(valueElement);
    }
    super.visitEnumDeclaration(node);
    _currentParent = null;
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    final element = CodeElement(
      name: node.name.lexeme,
      type: CodeElementType.typedefDeclaration,
      location: _locationFromNode(node),
      isPublic: !node.name.lexeme.startsWith('_'),
      annotations: _extractAnnotations(node.metadata),
      documentation: _extractDocumentation(node),
      packageName: packageName,
    );
    declarations.add(element);
    super.visitFunctionTypeAlias(node);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    final element = CodeElement(
      name: node.name.lexeme,
      type: CodeElementType.typedefDeclaration,
      location: _locationFromNode(node),
      isPublic: !node.name.lexeme.startsWith('_'),
      annotations: _extractAnnotations(node.metadata),
      documentation: _extractDocumentation(node),
      packageName: packageName,
    );
    declarations.add(element);
    super.visitGenericTypeAlias(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // Only top-level functions (not inside classes)
    if (_currentParent == null) {
      final element = CodeElement(
        name: node.name.lexeme,
        type: CodeElementType.topLevelFunction,
        location: _locationFromNode(node),
        isPublic: !node.name.lexeme.startsWith('_'),
        annotations: _extractAnnotations(node.metadata),
        documentation: _extractDocumentation(node),
        packageName: packageName,
      );
      declarations.add(element);

      // Visit parameters
      _visitParameters(node.functionExpression.parameters, node.name.lexeme);
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    final annotations = _extractAnnotations(node.metadata);
    final variables = node.variables.variables;

    // If there's only one variable, use the full declaration node's location
    // This ensures we capture 'final', 'var', 'const', and the semicolon
    if (variables.length == 1) {
      final variable = variables.first;
      final element = CodeElement(
        name: variable.name.lexeme,
        type: CodeElementType.topLevelVariable,
        location: _locationFromNode(node), // Use node, not variable
        isPublic: !variable.name.lexeme.startsWith('_'),
        annotations: annotations,
        documentation: _extractDocumentation(node),
        packageName: packageName,
      );
      declarations.add(element);
    } else {
      // Multiple variables in one declaration - use individual variable locations
      // but this is less accurate for deletion
      for (final variable in variables) {
        final element = CodeElement(
          name: variable.name.lexeme,
          type: CodeElementType.topLevelVariable,
          location: _locationFromNode(variable),
          isPublic: !variable.name.lexeme.startsWith('_'),
          annotations: annotations,
          documentation: _extractDocumentation(node),
          packageName: packageName,
        );
        declarations.add(element);
      }
    }
    super.visitTopLevelVariableDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    if (_currentParent == null) return;

    // Use the raw constructor name (without repeating the class name) so
    // references like `Class.named` match our stored identifier.
    final ctorName = node.name?.lexeme ?? '';
    // For unnamed constructors, we still want a usable name; use the class name.
    final elementName = ctorName.isEmpty ? _currentParent! : ctorName;
    final parameterParentName = ctorName.isEmpty
        ? _currentParent!
        : '$_currentParent.$ctorName';
    final isOverride = _hasOverrideAnnotation(node.metadata);

    final element = CodeElement(
      name: elementName,
      type: CodeElementType.constructor,
      location: _locationFromNode(node),
      // Public if neither the class nor the constructor name is private
      isPublic:
          !elementName.startsWith('_') && !_currentParent!.startsWith('_'),
      isOverride: isOverride,
      parentName: _currentParent,
      annotations: _extractAnnotations(node.metadata),
      documentation: _extractDocumentation(node),
      packageName: packageName,
    );
    declarations.add(element);

    // Visit parameters
    _visitParameters(node.parameters, parameterParentName);

    super.visitConstructorDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (_currentParent == null) return;

    CodeElementType type;
    if (node.isGetter) {
      type = CodeElementType.getter;
    } else if (node.isSetter) {
      type = CodeElementType.setter;
    } else {
      type = CodeElementType.method;
    }

    final isOverride = _hasOverrideAnnotation(node.metadata);
    // A method is abstract if it has no body (just a semicolon) in an abstract class
    final isAbstract =
        node.body is EmptyFunctionBody && _currentParentIsAbstract;

    final element = CodeElement(
      name: node.name.lexeme,
      type: type,
      location: _locationFromNode(node),
      isPublic: !node.name.lexeme.startsWith('_'),
      isStatic: node.isStatic,
      isOverride: isOverride,
      isAbstract: isAbstract,
      parentName: _currentParent,
      annotations: _extractAnnotations(node.metadata),
      documentation: _extractDocumentation(node),
      packageName: packageName,
    );
    declarations.add(element);

    // Visit parameters (for methods, not getters)
    if (!node.isGetter && node.parameters != null) {
      _visitParameters(node.parameters!, '$_currentParent.${node.name.lexeme}');
    }

    super.visitMethodDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    if (_currentParent == null) return;

    final annotations = _extractAnnotations(node.metadata);
    final variables = node.fields.variables;

    // If there's only one field, use the full declaration node's location
    // This ensures we capture 'final', 'static', type annotations, and the semicolon
    if (variables.length == 1) {
      final variable = variables.first;
      final element = CodeElement(
        name: variable.name.lexeme,
        type: CodeElementType.field,
        location: _locationFromNode(node), // Use node, not variable
        isPublic: !variable.name.lexeme.startsWith('_'),
        isStatic: node.isStatic,
        parentName: _currentParent,
        annotations: annotations,
        documentation: _extractDocumentation(node),
        packageName: packageName,
      );
      declarations.add(element);
    } else {
      // Multiple fields in one declaration - use individual variable locations
      for (final variable in variables) {
        final element = CodeElement(
          name: variable.name.lexeme,
          type: CodeElementType.field,
          location: _locationFromNode(variable),
          isPublic: !variable.name.lexeme.startsWith('_'),
          isStatic: node.isStatic,
          parentName: _currentParent,
          annotations: annotations,
          documentation: _extractDocumentation(node),
          packageName: packageName,
        );
        declarations.add(element);
      }
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitImportDirective(ImportDirective node) {
    final uri = node.uri.stringValue ?? '';
    final prefix = node.prefix?.name ?? '';
    final name = prefix.isNotEmpty ? prefix : uri;

    final element = CodeElement(
      name: name,
      type: CodeElementType.importDirective,
      location: _locationFromNode(node),
      isPublic: true,
      annotations: [],
      packageName: packageName,
    );
    declarations.add(element);
    super.visitImportDirective(node);
  }

  @override
  void visitExportDirective(ExportDirective node) {
    final uri = node.uri.stringValue ?? '';

    final element = CodeElement(
      name: uri,
      type: CodeElementType.exportDirective,
      location: _locationFromNode(node),
      isPublic: true,
      annotations: [],
      packageName: packageName,
    );
    declarations.add(element);
    super.visitExportDirective(node);
  }

  void _visitParameters(FormalParameterList? parameters, String functionName) {
    if (parameters == null) return;

    for (final param in parameters.parameters) {
      String paramName;
      if (param is SimpleFormalParameter) {
        paramName = param.name?.lexeme ?? '';
      } else if (param is DefaultFormalParameter) {
        final innerParam = param.parameter;
        if (innerParam is SimpleFormalParameter) {
          paramName = innerParam.name?.lexeme ?? '';
        } else if (innerParam is FieldFormalParameter) {
          paramName = innerParam.name.lexeme;
        } else if (innerParam is SuperFormalParameter) {
          paramName = innerParam.name.lexeme;
        } else {
          continue;
        }
      } else if (param is FieldFormalParameter) {
        // Skip field formal parameters (this.x) as they're used for initialization
        continue;
      } else if (param is SuperFormalParameter) {
        // Skip super formal parameters
        continue;
      } else {
        continue;
      }

      if (paramName.isEmpty) continue;

      final element = CodeElement(
        name: paramName,
        type: CodeElementType.parameter,
        location: _locationFromNode(param),
        isPublic: !paramName.startsWith('_'),
        parentName: functionName,
        annotations: _extractAnnotations(param.metadata),
        packageName: packageName,
      );
      declarations.add(element);
    }
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

  List<String> _extractAnnotations(NodeList<Annotation> metadata) {
    return metadata.map((a) => a.name.name).toList();
  }

  bool _hasOverrideAnnotation(NodeList<Annotation> metadata) {
    return metadata.any((a) => a.name.name == 'override');
  }

  String? _extractDocumentation(AnnotatedNode node) {
    final comment = node.documentationComment;
    if (comment == null) return null;
    return comment.tokens.map((t) => t.lexeme).join('\n');
  }
}

/// Result of declaration collection
class DeclarationResult {
  final List<CodeElement> declarations;
  final String filePath;
  final String? packageName;

  const DeclarationResult({
    required this.declarations,
    required this.filePath,
    this.packageName,
  });

  /// Merge multiple results
  static DeclarationResult merge(List<DeclarationResult> results) {
    final allDeclarations = <CodeElement>[];
    for (final result in results) {
      allDeclarations.addAll(result.declarations);
    }
    return DeclarationResult(declarations: allDeclarations, filePath: '');
  }
}
