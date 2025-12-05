import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';

import '../../models/code_element.dart';

/// AST Visitor to analyze import/export directives with granular tracking.
///
/// Supports two modes:
/// - AST-only mode (default): Basic unused import detection
/// - Semantic mode: Per-symbol usage tracking for show/hide combinators
class ImportVisitor extends RecursiveAstVisitor<void> {
  /// All import directives found
  final List<ImportInfo> imports = [];

  /// All export directives found
  final List<ExportInfo> exports = [];

  /// Set of identifiers used in the file (excluding imports)
  final Set<String> usedIdentifiers = {};

  /// Per-import symbol usage tracking (semantic mode)
  final Map<String, ImportSymbolUsage> importSymbolUsage = {};

  /// The file being visited
  final String filePath;

  /// Package name (for monorepo support)
  final String? packageName;

  /// Resolved unit for semantic analysis (optional)
  final ResolvedUnitResult? resolvedUnit;

  /// Map of prefix to import URI
  final Map<String, String> _prefixToUri = {};

  ImportVisitor({required this.filePath, this.packageName, this.resolvedUnit});

  /// Whether semantic analysis is available
  bool get hasSemanticInfo => resolvedUnit != null;

  @override
  void visitImportDirective(ImportDirective node) {
    final uri = node.uri.stringValue ?? '';
    final prefix = node.prefix?.name;
    final isDeferred = node.deferredKeyword != null;

    // Track prefix mapping
    if (prefix != null) {
      _prefixToUri[prefix] = uri;
    }

    // Collect show/hide combinators
    final shownNames = <String>[];
    final hiddenNames = <String>[];

    for (final combinator in node.combinators) {
      if (combinator is ShowCombinator) {
        shownNames.addAll(combinator.shownNames.map((n) => n.name));
      } else if (combinator is HideCombinator) {
        hiddenNames.addAll(combinator.hiddenNames.map((n) => n.name));
      }
    }

    imports.add(
      ImportInfo(
        uri: uri,
        prefix: prefix,
        isDeferred: isDeferred,
        shownNames: shownNames,
        hiddenNames: hiddenNames,
        location: _locationFromNode(node),
      ),
    );

    // Initialize per-symbol tracking
    importSymbolUsage[uri] = ImportSymbolUsage(
      uri: uri,
      prefix: prefix,
      shownSymbols: shownNames.toSet(),
      hiddenSymbols: hiddenNames.toSet(),
      usedSymbols: {},
      location: _locationFromNode(node),
    );

    super.visitImportDirective(node);
  }

  @override
  void visitExportDirective(ExportDirective node) {
    final uri = node.uri.stringValue ?? '';

    // Collect show/hide combinators
    final shownNames = <String>[];
    final hiddenNames = <String>[];

    for (final combinator in node.combinators) {
      if (combinator is ShowCombinator) {
        shownNames.addAll(combinator.shownNames.map((n) => n.name));
      } else if (combinator is HideCombinator) {
        hiddenNames.addAll(combinator.hiddenNames.map((n) => n.name));
      }
    }

    exports.add(
      ExportInfo(
        uri: uri,
        shownNames: shownNames,
        hiddenNames: hiddenNames,
        location: _locationFromNode(node),
      ),
    );

    super.visitExportDirective(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // Skip if this is a declaration
    if (!node.inDeclarationContext()) {
      usedIdentifiers.add(node.name);

      // Semantic mode: track which import provides this symbol
      if (hasSemanticInfo) {
        final element = node.staticElement;
        if (element != null) {
          _trackSymbolUsage(element, node.name);
        }
      }
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final prefix = node.prefix.name;
    final identifier = node.identifier.name;

    // Track both the prefix and the full identifier
    usedIdentifiers.add(prefix);
    usedIdentifiers.add('$prefix.$identifier');

    // Track symbol usage for prefixed imports
    if (_prefixToUri.containsKey(prefix)) {
      final uri = _prefixToUri[prefix]!;
      _markSymbolUsed(uri, identifier);
    }

    // Semantic mode: track element
    if (hasSemanticInfo) {
      final element = node.staticElement;
      if (element != null) {
        _trackSymbolUsage(element, identifier);
      }
    }

    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final name = node.name2.lexeme;
    usedIdentifiers.add(name);

    // Track prefixed types
    final importPrefix = node.importPrefix;
    if (importPrefix != null) {
      final prefix = importPrefix.name.lexeme;
      usedIdentifiers.add(prefix);

      // Track symbol usage for prefixed imports
      if (_prefixToUri.containsKey(prefix)) {
        final uri = _prefixToUri[prefix]!;
        _markSymbolUsed(uri, name);
      }
    }

    // Semantic mode: track element
    if (hasSemanticInfo) {
      final element = node.element;
      if (element != null) {
        _trackSymbolUsage(element, name);
      }
    }

    super.visitNamedType(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    // Semantic mode: track method invocation source
    if (hasSemanticInfo) {
      final element = node.methodName.staticElement;
      if (element != null) {
        _trackSymbolUsage(element, node.methodName.name);
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    // Semantic mode: track property access source
    if (hasSemanticInfo) {
      final element = node.propertyName.staticElement;
      if (element != null) {
        _trackSymbolUsage(element, node.propertyName.name);
      }
    }
    super.visitPropertyAccess(node);
  }

  /// Track symbol usage from an element (semantic mode).
  void _trackSymbolUsage(Element element, String symbolName) {
    final library = element.library;
    if (library == null) return;

    final libraryUri = library.source.uri.toString();

    // Find matching import
    for (final import in imports) {
      if (_uriMatches(import.uri, libraryUri)) {
        _markSymbolUsed(import.uri, symbolName);
        break;
      }
    }
  }

  /// Check if import URI matches library URI.
  bool _uriMatches(String importUri, String libraryUri) {
    // Direct match
    if (importUri == libraryUri) return true;

    // Package import matching
    if (importUri.startsWith('package:') && libraryUri.startsWith('package:')) {
      return importUri == libraryUri;
    }

    return false;
  }

  /// Mark a symbol as used from an import.
  void _markSymbolUsed(String uri, String symbolName) {
    final usage = importSymbolUsage[uri];
    if (usage != null) {
      importSymbolUsage[uri] = usage.copyWith(
        usedSymbols: {...usage.usedSymbols, symbolName},
      );
    }
  }

  /// Check which imports are unused
  List<ImportInfo> getUnusedImports() {
    final unused = <ImportInfo>[];

    for (final import in imports) {
      if (_isImportUnused(import)) {
        unused.add(import);
      }
    }

    return unused;
  }

  bool _isImportUnused(ImportInfo import) {
    // dart:core is always used implicitly
    if (import.uri == 'dart:core') {
      return false;
    }

    // Semantic mode: check actual symbol usage
    if (hasSemanticInfo) {
      final usage = importSymbolUsage[import.uri];
      if (usage != null) {
        return usage.usedSymbols.isEmpty;
      }
    }

    // AST-only mode fallback
    // If import has a prefix, check if prefix is used
    if (import.prefix != null) {
      return !usedIdentifiers.contains(import.prefix);
    }

    // If import has show combinator, check if any shown name is used
    if (import.shownNames.isNotEmpty) {
      return !import.shownNames.any((name) => usedIdentifiers.contains(name));
    }

    // For imports without prefix or show, we can't easily determine if unused
    // without semantic analysis. Mark as potentially used.
    return false;
  }

  /// Get partially used imports (imports with show combinator where not all symbols are used).
  List<PartiallyUsedImportInfo> getPartiallyUsedImports() {
    final result = <PartiallyUsedImportInfo>[];

    for (final import in imports) {
      if (import.shownNames.isEmpty) continue;

      final usage = importSymbolUsage[import.uri];
      if (usage == null) continue;

      final shownSet = import.shownNames.toSet();
      final unusedSymbols = shownSet.difference(usage.usedSymbols);

      // Only report if some symbols are used and some are not
      if (unusedSymbols.isNotEmpty && usage.usedSymbols.isNotEmpty) {
        result.add(
          PartiallyUsedImportInfo(
            uri: import.uri,
            usedSymbols: usage.usedSymbols.intersection(shownSet).toList(),
            unusedSymbols: unusedSymbols.toList(),
            location: import.location,
          ),
        );
      }
    }

    return result;
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
}

/// Information about an import directive
class ImportInfo {
  final String uri;
  final String? prefix;
  final bool isDeferred;
  final List<String> shownNames;
  final List<String> hiddenNames;
  final SourceLocation location;

  const ImportInfo({
    required this.uri,
    this.prefix,
    this.isDeferred = false,
    this.shownNames = const [],
    this.hiddenNames = const [],
    required this.location,
  });

  /// Get a display name for this import
  String get displayName {
    if (prefix != null) {
      return '$uri as $prefix';
    }
    return uri;
  }

  /// Check if this is a Dart SDK import
  bool get isDartSdk => uri.startsWith('dart:');

  /// Check if this is a package import
  bool get isPackage => uri.startsWith('package:');

  /// Check if this is a relative import
  bool get isRelative => !isDartSdk && !isPackage;

  /// Get the package name from a package import
  String? get packageName {
    if (!isPackage) return null;
    final parts = uri.substring('package:'.length).split('/');
    return parts.isNotEmpty ? parts.first : null;
  }
}

/// Information about an export directive
class ExportInfo {
  final String uri;
  final List<String> shownNames;
  final List<String> hiddenNames;
  final SourceLocation location;

  const ExportInfo({
    required this.uri,
    this.shownNames = const [],
    this.hiddenNames = const [],
    required this.location,
  });

  /// Get a display name for this export
  String get displayName => uri;

  /// Check if this is a package export
  bool get isPackage => uri.startsWith('package:');

  /// Check if this is a relative export
  bool get isRelative => !isPackage;
}

/// Result of import analysis
class ImportAnalysisResult {
  final List<ImportInfo> imports;
  final List<ExportInfo> exports;
  final List<ImportInfo> unusedImports;
  final List<PartiallyUsedImportInfo> partiallyUsedImports;
  final String filePath;

  const ImportAnalysisResult({
    required this.imports,
    required this.exports,
    required this.unusedImports,
    this.partiallyUsedImports = const [],
    required this.filePath,
  });
}

/// Per-import symbol usage tracking.
class ImportSymbolUsage {
  final String uri;
  final String? prefix;
  final Set<String> shownSymbols;
  final Set<String> hiddenSymbols;
  final Set<String> usedSymbols;
  final SourceLocation location;

  const ImportSymbolUsage({
    required this.uri,
    this.prefix,
    required this.shownSymbols,
    required this.hiddenSymbols,
    required this.usedSymbols,
    required this.location,
  });

  ImportSymbolUsage copyWith({
    String? uri,
    String? prefix,
    Set<String>? shownSymbols,
    Set<String>? hiddenSymbols,
    Set<String>? usedSymbols,
    SourceLocation? location,
  }) {
    return ImportSymbolUsage(
      uri: uri ?? this.uri,
      prefix: prefix ?? this.prefix,
      shownSymbols: shownSymbols ?? this.shownSymbols,
      hiddenSymbols: hiddenSymbols ?? this.hiddenSymbols,
      usedSymbols: usedSymbols ?? this.usedSymbols,
      location: location ?? this.location,
    );
  }

  /// Get unused symbols from show combinator
  Set<String> get unusedShownSymbols => shownSymbols.difference(usedSymbols);

  /// Check if this import is completely unused
  bool get isUnused => usedSymbols.isEmpty;

  /// Check if this import is partially used
  bool get isPartiallyUsed =>
      shownSymbols.isNotEmpty &&
      usedSymbols.isNotEmpty &&
      unusedShownSymbols.isNotEmpty;
}

/// Information about a partially used import.
class PartiallyUsedImportInfo {
  final String uri;
  final List<String> usedSymbols;
  final List<String> unusedSymbols;
  final SourceLocation location;

  const PartiallyUsedImportInfo({
    required this.uri,
    required this.usedSymbols,
    required this.unusedSymbols,
    required this.location,
  });

  /// Get suggestion for fixing the import
  String get suggestion {
    if (usedSymbols.isEmpty) {
      return 'Remove the unused import';
    }
    return 'Update to: import \'$uri\' show ${usedSymbols.join(', ')};';
  }

  /// Get the message for this issue
  String get message {
    return 'Import \'$uri\' has unused symbols: ${unusedSymbols.join(', ')}';
  }
}
