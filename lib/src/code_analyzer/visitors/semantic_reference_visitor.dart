import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';

import '../../models/code_element.dart';
import '../../utils/logger.dart';
import '../semantic_analyzer.dart';

/// AST Visitor that uses semantic analysis for accurate reference tracking.
///
/// Unlike the basic ReferenceVisitor, this visitor:
/// - Uses staticElement for exact element binding
/// - Tracks extension method usage (implicit calls)
/// - Detects DI registrations
/// - Provides granular import usage tracking
class SemanticReferenceVisitor extends RecursiveAstVisitor<void> {
  /// Collected semantic references
  final List<SemanticReference> references = [];

  /// Set of used element IDs (fully qualified)
  final Set<String> usedElementIds = {};

  /// Set of used extension names
  final Set<String> usedExtensions = {};

  /// Import usage tracking
  final Map<String, ImportUsageInfo> importUsage = {};

  /// DI registrations found
  final List<DIRegistration> diRegistrations = [];

  /// The file being visited
  final String filePath;

  /// Package name (for monorepo support)
  final String? packageName;

  /// The resolved unit for semantic information
  final ResolvedUnitResult resolvedUnit;

  /// Logger for debug output
  final Logger logger;

  /// Map of import prefix to URI
  final Map<String, String> _importPrefixes = {};

  /// Map of import URI to ImportInfo
  final Map<String, _ImportInfo> _imports = {};

  SemanticReferenceVisitor({
    required this.filePath,
    required this.resolvedUnit,
    required this.logger,
    this.packageName,
  });

  @override
  void visitImportDirective(ImportDirective node) {
    final uri = node.uri.stringValue ?? '';
    final prefix = node.prefix?.name;

    // Track prefix mapping
    if (prefix != null) {
      _importPrefixes[prefix] = uri;
    }

    // Collect show/hide combinators
    final shownNames = <String>{};
    final hiddenNames = <String>{};

    for (final combinator in node.combinators) {
      if (combinator is ShowCombinator) {
        shownNames.addAll(combinator.shownNames.map((n) => n.name));
      } else if (combinator is HideCombinator) {
        hiddenNames.addAll(combinator.hiddenNames.map((n) => n.name));
      }
    }

    _imports[uri] = _ImportInfo(
      uri: uri,
      prefix: prefix,
      shownNames: shownNames,
      hiddenNames: hiddenNames,
      location: _locationFromNode(node),
    );

    // Initialize import usage tracking
    importUsage[uri] = ImportUsageInfo(
      uri: uri,
      prefix: prefix,
      shownSymbols: shownNames,
      hiddenSymbols: hiddenNames,
      usedSymbols: {},
      location: _locationFromNode(node),
    );

    super.visitImportDirective(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // Skip declarations
    if (node.inDeclarationContext()) {
      super.visitSimpleIdentifier(node);
      return;
    }

    final element = node.staticElement;
    if (element != null) {
      _trackElementUsage(element, node);
    }

    super.visitSimpleIdentifier(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final element = node.staticElement;
    if (element != null) {
      _trackElementUsage(element, node);
    }

    // Track prefix usage for import tracking
    final prefix = node.prefix.name;
    if (_importPrefixes.containsKey(prefix)) {
      final uri = _importPrefixes[prefix]!;
      _markSymbolUsed(uri, node.identifier.name);
    }

    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final element = node.methodName.staticElement;

    if (element != null) {
      _trackElementUsage(element, node);

      // Check for extension method usage
      final enclosing = element.enclosingElement3;
      if (enclosing is ExtensionElement) {
        final extensionName = enclosing.name;
        if (extensionName != null) {
          usedExtensions.add(extensionName);
          logger.debug(
            'Found extension usage: $extensionName.${node.methodName.name}',
          );

          // Track the extension as implicitly used
          references.add(
            SemanticReference(
              elementId: _getElementId(enclosing),
              libraryUri: enclosing.library.source.uri.toString(),
              location: _locationFromNode(node),
              type: ReferenceType.invocation,
              packageName: packageName,
              isImplicit: true,
            ),
          );
        }
      }
    }

    // Check for DI patterns
    _checkDIMethodInvocation(node);

    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final element = node.constructorName.staticElement;
    if (element != null) {
      _trackElementUsage(element, node);

      // Also track the class being instantiated
      final classElement = element.enclosingElement3;
      _trackElementUsage(classElement, node);
    }

    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final element = node.element;
    if (element != null) {
      _trackElementUsage(element, node);
    }

    super.visitNamedType(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final element = node.propertyName.staticElement;
    if (element != null) {
      _trackElementUsage(element, node);

      // Check for extension property usage
      final enclosing = element.enclosingElement3;
      if (enclosing is ExtensionElement) {
        final extensionName = enclosing.name;
        if (extensionName != null) {
          usedExtensions.add(extensionName);
        }
      }
    }

    super.visitPropertyAccess(node);
  }

  @override
  void visitAnnotation(Annotation node) {
    final element = node.element;
    if (element != null) {
      _trackElementUsage(element, node);
    }

    // Check for DI annotations
    _checkDIAnnotation(node);

    super.visitAnnotation(node);
  }

  @override
  void visitExtendsClause(ExtendsClause node) {
    final element = node.superclass.element;
    if (element != null) {
      _trackElementUsage(element, node);
    }
    super.visitExtendsClause(node);
  }

  @override
  void visitImplementsClause(ImplementsClause node) {
    for (final interface in node.interfaces) {
      final element = interface.element;
      if (element != null) {
        _trackElementUsage(element, node);
      }
    }
    super.visitImplementsClause(node);
  }

  @override
  void visitWithClause(WithClause node) {
    for (final mixin in node.mixinTypes) {
      final element = mixin.element;
      if (element != null) {
        _trackElementUsage(element, node);
      }
    }
    super.visitWithClause(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final element = node.staticElement;
    if (element != null) {
      _trackElementUsage(element, node);
    }
    super.visitFunctionExpressionInvocation(node);
  }

  /// Track element usage with full semantic information.
  void _trackElementUsage(Element element, AstNode node) {
    final elementId = _getElementId(element);
    usedElementIds.add(elementId);

    // Also add the simple name for backward compatibility
    usedElementIds.add(element.name ?? '');

    // Track import usage
    final libraryUri = element.library?.source.uri.toString();
    if (libraryUri != null && _imports.containsKey(libraryUri)) {
      _markSymbolUsed(libraryUri, element.name ?? '');
    }

    // Create semantic reference
    references.add(
      SemanticReference(
        elementId: elementId,
        libraryUri: libraryUri,
        location: _locationFromNode(node),
        type: _determineReferenceType(node),
        packageName: packageName,
      ),
    );
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

  /// Mark a symbol as used from an import.
  void _markSymbolUsed(String uri, String symbolName) {
    final existing = importUsage[uri];
    if (existing != null) {
      importUsage[uri] = existing.copyWith(
        usedSymbols: {...existing.usedSymbols, symbolName},
      );
    }
  }

  /// Check for DI method invocations (GetIt, locator, etc.).
  void _checkDIMethodInvocation(MethodInvocation node) {
    final methodName = node.methodName.name;
    final target = node.target;

    // GetIt patterns: GetIt.I<T>(), GetIt.instance<T>(), locator<T>()
    if (methodName == 'call' || methodName == 'get') {
      if (target is SimpleIdentifier) {
        final targetName = target.name;
        if (targetName == 'GetIt' ||
            targetName == 'locator' ||
            targetName == 'sl') {
          _extractDITypeArgument(node, DIFramework.getIt);
        }
      } else if (target is PrefixedIdentifier) {
        final identifier = target.identifier.name;
        if (identifier == 'I' || identifier == 'instance') {
          _extractDITypeArgument(node, DIFramework.getIt);
        }
      }
    }

    // Check for generic method calls on GetIt
    if (target is PrefixedIdentifier) {
      final prefix = target.prefix.name;
      final identifier = target.identifier.name;
      if (prefix == 'GetIt' &&
          (identifier == 'I' || identifier == 'instance')) {
        _extractDITypeArgument(node, DIFramework.getIt);
      }
    }
  }

  /// Extract type argument from DI call and mark as used.
  void _extractDITypeArgument(MethodInvocation node, DIFramework framework) {
    final typeArgs = node.typeArguments?.arguments;
    if (typeArgs != null && typeArgs.isNotEmpty) {
      for (final typeArg in typeArgs) {
        if (typeArg is NamedType) {
          final typeName = typeArg.name2.lexeme;
          final element = typeArg.element;

          if (element != null) {
            _trackElementUsage(element, node);
          }

          diRegistrations.add(
            DIRegistration(
              typeName: typeName,
              framework: framework,
              registrationType: DIRegistrationType.factory,
              location: _locationFromNode(node),
              packageName: packageName,
            ),
          );

          logger.debug('Found DI usage: $framework<$typeName>');
        }
      }
    }
  }

  /// Check for DI annotations (@injectable, @singleton, etc.).
  void _checkDIAnnotation(Annotation node) {
    final name = node.name.name;

    DIFramework? framework;
    DIRegistrationType? registrationType;

    switch (name) {
      case 'injectable':
      case 'Injectable':
        framework = DIFramework.injectable;
        registrationType = DIRegistrationType.factory;
        break;
      case 'singleton':
      case 'Singleton':
        framework = DIFramework.injectable;
        registrationType = DIRegistrationType.singleton;
        break;
      case 'lazySingleton':
      case 'LazySingleton':
        framework = DIFramework.injectable;
        registrationType = DIRegistrationType.lazySingleton;
        break;
      case 'riverpod':
      case 'Riverpod':
        framework = DIFramework.riverpod;
        registrationType = DIRegistrationType.provider;
        break;
    }

    if (framework != null && registrationType != null) {
      // Find the annotated class/function
      final parent = node.parent;
      String? typeName;

      if (parent is Declaration) {
        if (parent is ClassDeclaration) {
          typeName = parent.name.lexeme;
        } else if (parent is FunctionDeclaration) {
          typeName = parent.name.lexeme;
        }
      }

      if (typeName != null) {
        diRegistrations.add(
          DIRegistration(
            typeName: typeName,
            framework: framework,
            registrationType: registrationType,
            location: _locationFromNode(node),
            packageName: packageName,
          ),
        );

        logger.debug('Found DI annotation: @$name on $typeName');
      }
    }
  }

  ReferenceType _determineReferenceType(AstNode node) {
    if (node is MethodInvocation || node is InstanceCreationExpression) {
      return ReferenceType.invocation;
    }
    if (node is NamedType) {
      return ReferenceType.typeUsage;
    }
    if (node is ExtendsClause ||
        node is ImplementsClause ||
        node is WithClause) {
      return ReferenceType.inheritance;
    }
    if (node is PropertyAccess) {
      return ReferenceType.propertyAccess;
    }
    if (node is Annotation) {
      return ReferenceType.annotation;
    }
    return ReferenceType.read;
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
}

/// Internal import info for tracking.
class _ImportInfo {
  final String uri;
  final String? prefix;
  final Set<String> shownNames;
  final Set<String> hiddenNames;
  final SourceLocation location;

  const _ImportInfo({
    required this.uri,
    this.prefix,
    required this.shownNames,
    required this.hiddenNames,
    required this.location,
  });
}
