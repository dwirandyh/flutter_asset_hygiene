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
/// - Handles part/part-of files correctly (shared imports)
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

  /// Map of import URI to the set of library URIs it provides access to
  final Map<String, Set<String>> _importToLibraries = {};

  /// Map of library URI to import URIs that provide access to it
  final Map<String, Set<String>> _libraryToImports = {};

  /// Whether this file is a part file (has `part of` directive)
  bool isPartFile = false;

  /// The library file path if this is a part file
  String? libraryFilePath;

  SemanticReferenceVisitor({
    required this.filePath,
    required this.resolvedUnit,
    required this.logger,
    this.packageName,
  });

  @override
  void visitPartOfDirective(PartOfDirective node) {
    isPartFile = true;
    // Extract the library path from the part-of directive
    final uri = node.uri?.stringValue;
    if (uri != null) {
      libraryFilePath = uri;
    } else if (node.libraryName != null) {
      // part of library_name; - we can't easily resolve this
      libraryFilePath = null;
    }
    logger.debug(
      'Found part-of directive in $filePath, library: $libraryFilePath',
    );
    super.visitPartOfDirective(node);
  }

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

    // Build mapping from import URI to the libraries it provides access to
    // This is crucial for tracking which import provides a given element
    final importElement = node.element;
    if (importElement != null) {
      final importedLibrary = importElement.importedLibrary;
      if (importedLibrary != null) {
        final libraryUris = <String>{};

        // Add the directly imported library
        libraryUris.add(importedLibrary.source.uri.toString());

        // Add all re-exported libraries (transitive exports)
        _collectExportedLibraries(
          importedLibrary,
          libraryUris,
          <LibraryElement>{},
        );

        _importToLibraries[uri] = libraryUris;

        // Build reverse mapping
        for (final libUri in libraryUris) {
          _libraryToImports.putIfAbsent(libUri, () => {}).add(uri);
        }
      }
    } else {
      // Fallback: if importElement is null (e.g., package not resolved),
      // use the import URI directly as the library URI
      // This ensures prefixed imports are tracked even without full resolution
      _importToLibraries[uri] = {uri};
      _libraryToImports.putIfAbsent(uri, () => {}).add(uri);
      logger.debug('Import element is null for $uri, using fallback mapping');
    }

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
    // This is crucial for patterns like: prefix.ClassName.staticMethod()
    // e.g., intl.Intl.canonicalizedLocale(locale)
    final prefix = node.prefix.name;
    if (_importPrefixes.containsKey(prefix)) {
      final uri = _importPrefixes[prefix]!;
      _markSymbolUsed(uri, node.identifier.name);

      // Also mark the import as implicitly used when prefix is accessed
      // This handles cases where the element can't be resolved but prefix is used
      _markImportAsUsed(uri);
    }

    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final element = node.methodName.staticElement;

    if (element != null) {
      _trackElementUsage(element, node);

      // Check for extension method usage
      try {
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
      } catch (_) {
        // Some element types don't support enclosingElement3
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
      try {
        final classElement = element.enclosingElement3;
        _trackElementUsage(classElement, node);
      } catch (_) {
        // Some element types don't support enclosingElement3
      }
    }

    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final element = node.element;
    if (element != null) {
      _trackElementUsage(element, node);
    }

    // Track prefixed type usage (e.g., intl.Intl, math.Random)
    // This ensures imports with prefixes are marked as used
    final importPrefix = node.importPrefix;
    if (importPrefix != null) {
      final prefix = importPrefix.name.lexeme;
      if (_importPrefixes.containsKey(prefix)) {
        final uri = _importPrefixes[prefix]!;
        _markSymbolUsed(uri, node.name2.lexeme);
        _markImportAsUsed(uri);
      }
    }

    super.visitNamedType(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final element = node.propertyName.staticElement;
    if (element != null) {
      _trackElementUsage(element, node);

      // Check for extension property usage
      try {
        final enclosing = element.enclosingElement3;
        if (enclosing is ExtensionElement) {
          final extensionName = enclosing.name;
          if (extensionName != null) {
            usedExtensions.add(extensionName);
          }
        }
      } catch (_) {
        // Some element types don't support enclosingElement3
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

  @override
  void visitBinaryExpression(BinaryExpression node) {
    // Track operator usage (e.g., a + b uses operator+)
    final element = node.staticElement;
    if (element != null) {
      _trackElementUsage(element, node);
    }

    // Also track the operator name for AST fallback
    final operatorName = 'operator${node.operator.lexeme}';
    usedElementIds.add(operatorName);
    usedElementIds.add(node.operator.lexeme);

    super.visitBinaryExpression(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    // Track operator[] usage
    final element = node.staticElement;
    if (element != null) {
      _trackElementUsage(element, node);
    }

    usedElementIds.add('operator[]');
    usedElementIds.add('[]');

    super.visitIndexExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    // Track prefix operator usage (e.g., -a, !a, ++a)
    final element = node.staticElement;
    if (element != null) {
      _trackElementUsage(element, node);
    }

    final operatorName = 'operator${node.operator.lexeme}';
    usedElementIds.add(operatorName);

    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    // Track postfix operator usage (e.g., a++, a--)
    final element = node.staticElement;
    if (element != null) {
      _trackElementUsage(element, node);
    }

    final operatorName = 'operator${node.operator.lexeme}';
    usedElementIds.add(operatorName);

    super.visitPostfixExpression(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    // Track field formal parameters (this.fieldName) as references to fields
    // This is crucial - fields used in constructors via this.fieldName ARE used
    for (final param in node.parameters.parameters) {
      _trackFieldFormalParameter(param, node);
    }
    super.visitConstructorDeclaration(node);
  }

  /// Track field formal parameters (this.fieldName) as references to fields
  void _trackFieldFormalParameter(FormalParameter param, AstNode context) {
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

      // Track the field element if available (semantic mode)
      final element = fieldParam.declaredElement;
      if (element is FieldFormalParameterElement) {
        // The field element itself - mark the field as used
        final fieldElement = element.field;
        if (fieldElement != null) {
          _trackElementUsage(fieldElement, fieldParam);
        }
      }

      // Also add the simple field name to usedElementIds for AST fallback
      usedElementIds.add(fieldName);
    }
  }

  /// Track element usage with full semantic information.
  void _trackElementUsage(Element element, AstNode node) {
    // Skip prefix elements (import prefixes like 'as foo')
    // They don't have a valid library and cause type cast errors
    if (element is PrefixElement) {
      return;
    }

    final elementId = _getElementId(element);
    usedElementIds.add(elementId);

    // Also add the simple name for backward compatibility
    usedElementIds.add(element.name ?? '');

    // Track import usage - find which import provides this element
    String? libraryUri;
    try {
      libraryUri = element.library?.source.uri.toString();
    } catch (_) {
      // Some element types don't support library property
    }

    if (libraryUri != null) {
      // Check if any import provides access to this library
      final importUris = _libraryToImports[libraryUri];
      if (importUris != null && importUris.isNotEmpty) {
        // Mark the symbol as used in all imports that provide it
        for (final importUri in importUris) {
          _markSymbolUsed(importUri, element.name ?? '');
        }
      } else {
        // Fallback: direct match (for dart: imports and relative imports)
        if (_imports.containsKey(libraryUri)) {
          _markSymbolUsed(libraryUri, element.name ?? '');
        }
      }
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

    try {
      // Add library URI
      final library = element.library;
      if (library != null) {
        parts.add(library.source.uri.toString());
      }

      // Add enclosing elements
      // Note: enclosingElement3 can throw for certain element types
      try {
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
      } catch (_) {
        // Some element types don't support enclosingElement3
      }

      // Add element name
      final name = element.name;
      if (name != null && name.isNotEmpty) {
        parts.add(name);
      }
    } catch (_) {
      // Fallback to just the element name
      final name = element.name;
      if (name != null && name.isNotEmpty) {
        return name;
      }
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

  /// Mark an import as implicitly used (e.g., when prefix is accessed).
  /// This is important for patterns like prefix.ClassName.staticMethod()
  /// where the import prefix is used even if individual symbols can't be tracked.
  void _markImportAsUsed(String uri) {
    final existing = importUsage[uri];
    if (existing != null && !existing.isUsedImplicitly) {
      importUsage[uri] = existing.copyWith(isUsedImplicitly: true);
    }
  }

  /// Recursively collect all libraries exported by a library.
  void _collectExportedLibraries(
    LibraryElement library,
    Set<String> collected,
    Set<LibraryElement> visited,
  ) {
    if (visited.contains(library)) return;
    visited.add(library);

    for (final exported in library.exportedLibraries) {
      collected.add(exported.source.uri.toString());
      // Recursively collect transitive exports
      _collectExportedLibraries(exported, collected, visited);
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
