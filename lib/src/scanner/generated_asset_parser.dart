import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

/// Parser for generated asset files (flutter_gen, spider, etc.)
/// Extracts mapping between property names and actual asset paths
class GeneratedAssetParser {
  final String projectRoot;

  GeneratedAssetParser({required this.projectRoot});

  /// Find and parse generated asset files
  Future<GeneratedAssetMapping> parseGeneratedAssets() async {
    final mapping = GeneratedAssetMapping();

    // Common locations for generated asset files
    final possiblePaths = [
      'lib/gen/assets.gen.dart',
      'lib/generated/assets.gen.dart',
      'lib/src/gen/assets.gen.dart',
      'lib/assets.gen.dart',
      'lib/gen/fonts.gen.dart',
      'lib/generated/fonts.gen.dart',
      // spider package
      'lib/src/res/assets.dart',
      'lib/res/assets.dart',
      // Custom patterns
      'lib/core/assets/assets.gen.dart',
      'lib/shared/assets/assets.gen.dart',
    ];

    for (final relativePath in possiblePaths) {
      final file = File(p.join(projectRoot, relativePath));
      if (file.existsSync()) {
        final result = await _parseGeneratedFile(file);
        mapping.merge(result);
      }
    }

    // Also search for any *.gen.dart files that might contain assets
    final libDir = Directory(p.join(projectRoot, 'lib'));
    if (libDir.existsSync()) {
      await for (final entity in libDir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.gen.dart')) {
          // Skip if already parsed
          final relativePath = p.relative(entity.path, from: projectRoot);
          if (!possiblePaths.contains(relativePath)) {
            final result = await _parseGeneratedFile(entity);
            if (result.hasAssetMappings) {
              mapping.merge(result);
            }
          }
        }
      }
    }

    return mapping;
  }

  /// Parse a single generated file
  Future<GeneratedAssetMapping> _parseGeneratedFile(File file) async {
    try {
      final content = await file.readAsString();
      final parseResult = parseString(content: content);

      final visitor = GeneratedAssetVisitor();
      parseResult.unit.visitChildren(visitor);

      return visitor.mapping;
    } catch (e) {
      return GeneratedAssetMapping();
    }
  }
}

/// Visitor for generated asset files
class GeneratedAssetVisitor extends RecursiveAstVisitor<void> {
  final GeneratedAssetMapping mapping = GeneratedAssetMapping();

  // Track current class context
  String? _currentClassName;
  final List<String> _classHierarchy = [];

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final previousClass = _currentClassName;
    _currentClassName = node.name.lexeme;
    _classHierarchy.add(_currentClassName!);

    super.visitClassDeclaration(node);

    _classHierarchy.removeLast();
    _currentClassName = previousClass;
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    // Look for static const fields that return asset paths
    if (node.isStatic) {
      for (final variable in node.fields.variables) {
        final name = variable.name.lexeme;
        final initializer = variable.initializer;

        if (initializer != null) {
          final assetPath = _extractAssetPath(initializer);
          if (assetPath != null) {
            final fullKey = _buildFullKey(name);
            mapping.addMapping(fullKey, assetPath);
          }
        }
      }
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    // Look for getters that return asset paths
    if (node.isGetter) {
      final body = node.body;
      if (body is ExpressionFunctionBody) {
        final assetPath = _extractAssetPath(body.expression);
        if (assetPath != null) {
          final fullKey = _buildFullKey(node.name.lexeme);
          mapping.addMapping(fullKey, assetPath);
        }
      } else if (body is BlockFunctionBody) {
        // Check for return statement
        for (final statement in body.block.statements) {
          if (statement is ReturnStatement && statement.expression != null) {
            final assetPath = _extractAssetPath(statement.expression!);
            if (assetPath != null) {
              final fullKey = _buildFullKey(node.name.lexeme);
              mapping.addMapping(fullKey, assetPath);
            }
          }
        }
      }
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    // Look for const constructors with asset path parameters
    // Common in flutter_gen: AssetGenImage('assets/images/logo.png')
    if (node.constKeyword != null) {
      for (final param in node.parameters.parameters) {
        if (param is DefaultFormalParameter) {
          final defaultValue = param.defaultValue;
          if (defaultValue is SimpleStringLiteral) {
            final value = defaultValue.value;
            if (_looksLikeAssetPath(value)) {
              // This is a default asset path
              final className = _currentClassName ?? '';
              mapping.addClassAssetPath(className, value);
            }
          }
        }
      }
    }
    super.visitConstructorDeclaration(node);
  }

  /// Build full key from class hierarchy and field name
  String _buildFullKey(String fieldName) {
    if (_classHierarchy.isEmpty) {
      return fieldName;
    }
    return [..._classHierarchy, fieldName].join('.');
  }

  /// Extract asset path from expression
  String? _extractAssetPath(Expression expr) {
    // Direct string literal
    if (expr is SimpleStringLiteral) {
      final value = expr.value;
      if (_looksLikeAssetPath(value)) {
        return value;
      }
    }

    // Constructor call like AssetGenImage('path')
    if (expr is InstanceCreationExpression) {
      final args = expr.argumentList.arguments;
      if (args.isNotEmpty) {
        final firstArg = args.first;
        if (firstArg is SimpleStringLiteral) {
          final value = firstArg.value;
          if (_looksLikeAssetPath(value)) {
            return value;
          }
        }
      }
    }

    // Method call like SvgGenImage('path')
    if (expr is MethodInvocation) {
      final args = expr.argumentList.arguments;
      if (args.isNotEmpty) {
        final firstArg = args.first;
        if (firstArg is SimpleStringLiteral) {
          final value = firstArg.value;
          if (_looksLikeAssetPath(value)) {
            return value;
          }
        }
      }
    }

    return null;
  }

  /// Check if a string looks like an asset path
  bool _looksLikeAssetPath(String value) {
    if (value.isEmpty) return false;

    final lowerValue = value.toLowerCase();
    final assetPrefixes = [
      'assets/',
      'asset/',
      'images/',
      'icons/',
      'fonts/',
      'res/',
    ];

    for (final prefix in assetPrefixes) {
      if (lowerValue.startsWith(prefix)) {
        return true;
      }
    }

    // Check for file extensions
    final assetExtensions = [
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.svg',
      '.ttf',
      '.otf',
      '.json',
    ];
    for (final ext in assetExtensions) {
      if (lowerValue.endsWith(ext)) {
        return true;
      }
    }

    return false;
  }
}

/// Mapping between generated asset property names and actual paths
class GeneratedAssetMapping {
  /// Map from property access chain to asset path
  /// e.g., "Assets.images.logo" -> "assets/images/logo.png"
  final Map<String, String> _propertyToPath = {};

  /// Map from class name to asset paths (for classes with default paths)
  final Map<String, Set<String>> _classAssetPaths = {};

  /// All discovered asset paths
  final Set<String> _allAssetPaths = {};

  void addMapping(String propertyChain, String assetPath) {
    _propertyToPath[propertyChain] = assetPath;
    _allAssetPaths.add(assetPath);
  }

  void addClassAssetPath(String className, String assetPath) {
    _classAssetPaths.putIfAbsent(className, () => {}).add(assetPath);
    _allAssetPaths.add(assetPath);
  }

  void merge(GeneratedAssetMapping other) {
    _propertyToPath.addAll(other._propertyToPath);
    for (final entry in other._classAssetPaths.entries) {
      _classAssetPaths.putIfAbsent(entry.key, () => {}).addAll(entry.value);
    }
    _allAssetPaths.addAll(other._allAssetPaths);
  }

  bool get hasAssetMappings =>
      _propertyToPath.isNotEmpty || _allAssetPaths.isNotEmpty;

  /// Get asset path for a property access chain
  String? getAssetPath(String propertyChain) {
    // Exact match
    if (_propertyToPath.containsKey(propertyChain)) {
      return _propertyToPath[propertyChain];
    }

    // Try partial match (remove .path, .keyName, etc. suffixes)
    final withoutSuffix = _removeCommonSuffixes(propertyChain);
    if (_propertyToPath.containsKey(withoutSuffix)) {
      return _propertyToPath[withoutSuffix];
    }

    // Try matching by converting property name to asset path pattern
    return _fuzzyMatch(propertyChain);
  }

  /// Remove common suffixes like .path, .keyName, .provider
  String _removeCommonSuffixes(String chain) {
    final suffixes = ['.path', '.keyName', '.provider', '.image', '.svg'];
    var result = chain;
    for (final suffix in suffixes) {
      if (result.endsWith(suffix)) {
        result = result.substring(0, result.length - suffix.length);
      }
    }
    return result;
  }

  /// Try to fuzzy match property chain to asset path
  String? _fuzzyMatch(String propertyChain) {
    // Convert property chain to potential asset path patterns
    // e.g., "Assets.images.welcomePage1" -> look for "welcome_page_1" or "welcomePage1"
    final parts = propertyChain.split('.');
    if (parts.length < 2) return null;

    // Get the asset name (last meaningful part)
    var assetName = parts.last;
    // Remove common suffixes
    for (final suffix in ['path', 'keyName', 'provider', 'image', 'svg']) {
      if (assetName == suffix && parts.length > 1) {
        assetName = parts[parts.length - 2];
        break;
      }
    }

    // Convert camelCase to snake_case for matching
    final snakeCase = _camelToSnake(assetName);
    final lowerCamel = assetName.toLowerCase();

    for (final path in _allAssetPaths) {
      final fileName = p.basenameWithoutExtension(path).toLowerCase();
      final fileNameSnake = fileName.replaceAll('-', '_');

      if (fileName == lowerCamel ||
          fileName == snakeCase ||
          fileNameSnake == snakeCase ||
          fileName.replaceAll('_', '') == lowerCamel) {
        return path;
      }
    }

    return null;
  }

  /// Convert camelCase to snake_case
  String _camelToSnake(String input) {
    return input
        .replaceAllMapped(
          RegExp(r'[A-Z]'),
          (match) => '_${match.group(0)!.toLowerCase()}',
        )
        .replaceFirst(RegExp(r'^_'), '');
  }

  /// Get all asset paths that match a given property access pattern
  Set<String> getMatchingAssetPaths(String propertyAccess) {
    final matches = <String>{};

    // Direct match
    final direct = getAssetPath(propertyAccess);
    if (direct != null) {
      matches.add(direct);
    }

    // Only match category-wide if it's EXACTLY a category access (2 parts only)
    // e.g., "Assets.images" should match all images, but "Assets.icons.bell"
    // should only match bell.svg
    final parts = propertyAccess.split('.');
    if (parts.length == 2) {
      // This is a category-level access like "Assets.images" - match all in category
      final category = parts.join('.');

      for (final entry in _propertyToPath.entries) {
        if (entry.key.startsWith('$category.')) {
          matches.add(entry.value);
        }
      }

      // Also check by path pattern
      final categoryName = parts[1].toLowerCase();
      for (final path in _allAssetPaths) {
        if (path.toLowerCase().contains('/$categoryName/') ||
            path.toLowerCase().startsWith('$categoryName/')) {
          matches.add(path);
        }
      }
    }
    // For specific asset access (3+ parts), we already handled it via getAssetPath above

    return matches;
  }

  /// Get all discovered asset paths
  Set<String> get allAssetPaths => Set.unmodifiable(_allAssetPaths);

  /// Get all property mappings
  Map<String, String> get propertyToPath => Map.unmodifiable(_propertyToPath);
}
