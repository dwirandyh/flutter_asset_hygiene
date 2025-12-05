import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import '../../models/code_element.dart';

/// AST Visitor to analyze import/export directives
class ImportVisitor extends RecursiveAstVisitor<void> {
  /// All import directives found
  final List<ImportInfo> imports = [];

  /// All export directives found
  final List<ExportInfo> exports = [];

  /// Set of identifiers used in the file (excluding imports)
  final Set<String> usedIdentifiers = {};

  /// The file being visited
  final String filePath;

  /// Package name (for monorepo support)
  final String? packageName;

  ImportVisitor({required this.filePath, this.packageName});

  @override
  void visitImportDirective(ImportDirective node) {
    final uri = node.uri.stringValue ?? '';
    final prefix = node.prefix?.name;
    final isDeferred = node.deferredKeyword != null;

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

    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    usedIdentifiers.add(node.name2.lexeme);

    // Track prefixed types
    final importPrefix = node.importPrefix;
    if (importPrefix != null) {
      usedIdentifiers.add(importPrefix.name.lexeme);
    }

    super.visitNamedType(node);
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
  final String filePath;

  const ImportAnalysisResult({
    required this.imports,
    required this.exports,
    required this.unusedImports,
    required this.filePath,
  });
}
