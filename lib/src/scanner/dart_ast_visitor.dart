import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../models/models.dart';

/// AST Visitor to detect asset usage patterns in Dart code
class AssetReferenceVisitor extends RecursiveAstVisitor<void> {
  /// Set of detected asset paths (direct references)
  final Set<String> detectedAssets = {};

  /// Set of potentially used asset directories (from dynamic references)
  final Set<String> potentialDirectories = {};

  /// Set of font family names used
  final Set<String> usedFontFamilies = {};

  /// Set of generated asset class property accesses (e.g., Assets.images.logo)
  final Set<String> generatedAssetAccesses = {};

  /// Warnings generated during visit
  final List<ScanWarning> warnings = [];

  /// The file being visited
  final String filePath;

  /// Known asset extensions
  final Set<String> assetExtensions;

  /// Known asset path prefixes
  static const _assetPrefixes = [
    'assets/',
    'asset/',
    'images/',
    'icons/',
    'fonts/',
    'animations/',
    'lottie/',
    'json/',
    'res/',
    'resources/',
  ];

  /// Asset loading method patterns
  static const _assetLoadMethods = {
    'asset': true, // Image.asset, SvgPicture.asset, Lottie.asset
    'load': true, // rootBundle.load
    'loadString': true, // rootBundle.loadString
    'loadBuffer': true, // rootBundle.loadBuffer
    'loadStructuredData': true,
  };

  /// Asset class constructors
  static const _assetConstructors = {
    'AssetImage',
    'ExactAssetImage',
    'AssetBundleImageProvider',
  };

  AssetReferenceVisitor({
    required this.filePath,
    this.assetExtensions = ScanConfig.defaultAssetExtensions,
  });

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _checkStringForAssetPath(node.value, node);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    // Handle concatenated string literals
    final fullString = node.strings
        .whereType<SimpleStringLiteral>()
        .map((s) => s.value)
        .join();
    _checkStringForAssetPath(fullString, node);
    super.visitAdjacentStrings(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    // For interpolated strings, extract static parts and mark directory as potentially used
    final staticParts = <String>[];

    for (final element in node.elements) {
      if (element is InterpolationString) {
        staticParts.add(element.value);
      } else {
        staticParts.add('*'); // Placeholder for dynamic part
      }
    }

    final combinedPath = staticParts.join();

    if (_looksLikeAssetPath(combinedPath)) {
      // Extract the directory part before any dynamic segment
      final directory = _extractStaticDirectory(combinedPath);
      if (directory.isNotEmpty) {
        potentialDirectories.add(directory);
        warnings.add(
          ScanWarning(
            type: ScanWarningType.dynamicAssetPath,
            message: 'Dynamic asset path detected: $combinedPath',
            filePath: filePath,
            lineNumber: node.offset,
          ),
        );
      }
    }

    super.visitStringInterpolation(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final methodName = node.methodName.name;

    // Check for asset loading methods
    if (_assetLoadMethods.containsKey(methodName)) {
      _extractAssetFromArguments(node.argumentList);
    }

    // Check for Image.asset, SvgPicture.asset, Lottie.asset pattern
    if (methodName == 'asset') {
      final target = node.target;
      if (target is SimpleIdentifier) {
        final targetName = target.name;
        if ([
          'Image',
          'SvgPicture',
          'Lottie',
          'FlutterLogo',
          'Rive',
        ].contains(targetName)) {
          _extractAssetFromArguments(node.argumentList);
        }
      }
    }

    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final constructorName = node.constructorName.type.name2.lexeme;

    // Check for AssetImage, ExactAssetImage constructors
    if (_assetConstructors.contains(constructorName)) {
      _extractAssetFromArguments(node.argumentList);
    }

    // Check for TextStyle with fontFamily
    if (constructorName == 'TextStyle') {
      _extractFontFamily(node.argumentList);
    }

    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    // Check for generated asset class patterns like Assets.images.logo
    // Also handles aliased imports like game_assets.Assets.images.logo
    final fullAccess = _extractFullPropertyAccess(node);

    if (_startsWithAssetClass(fullAccess)) {
      generatedAssetAccesses.add(fullAccess);
    }

    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    // Handle chained property access like Assets.images.logo.path
    final fullAccess = _extractFullPropertyAccessFromPropertyAccess(node);

    // Check if it starts with a known asset class
    if (_startsWithAssetClass(fullAccess)) {
      generatedAssetAccesses.add(fullAccess);
    }

    super.visitPropertyAccess(node);
  }

  /// Extract full property access chain from PrefixedIdentifier
  String _extractFullPropertyAccess(AstNode node) {
    final parts = <String>[];
    var current = node;

    while (current is PrefixedIdentifier) {
      parts.insert(0, current.identifier.name);
      current = current.prefix;
    }

    if (current is SimpleIdentifier) {
      parts.insert(0, current.name);
    }

    // Check parent for more property accesses
    var parent = node.parent;
    while (parent is PropertyAccess) {
      parts.add(parent.propertyName.name);
      parent = parent.parent;
    }

    return parts.join('.');
  }

  /// Extract full property access from PropertyAccess node
  String _extractFullPropertyAccessFromPropertyAccess(PropertyAccess node) {
    final parts = <String>[];
    AstNode? current = node;

    while (current is PropertyAccess) {
      parts.insert(0, current.propertyName.name);
      current = current.target;
    }

    if (current is PrefixedIdentifier) {
      parts.insert(0, current.identifier.name);
      parts.insert(0, current.prefix.name);
    } else if (current is SimpleIdentifier) {
      parts.insert(0, current.name);
    }

    return parts.join('.');
  }

  /// Check if access chain starts with known asset class
  bool _startsWithAssetClass(String access) {
    final knownPrefixes = [
      'Assets.',
      'AppAssets.',
      'WKAssets.',
      'R.',
      'Res.',
      'Resources.',
    ];
    // Also match any pattern like XxxAssets. (custom asset class names)
    if (RegExp(r'^[A-Z][a-zA-Z]*Assets\.').hasMatch(access)) {
      return true;
    }
    // Handle import alias pattern: alias.Assets.xxx or alias.XxxAssets.xxx
    // e.g., game_assets.Assets.images.logo
    if (RegExp(r'^[a-z_][a-z0-9_]*\.[A-Z]').hasMatch(access)) {
      // Extract the part after the alias
      final dotIndex = access.indexOf('.');
      if (dotIndex != -1) {
        final afterAlias = access.substring(dotIndex + 1);
        // Recursively check if the part after alias is an asset class
        return _startsWithAssetClass(afterAlias);
      }
    }
    return knownPrefixes.any((p) => access.startsWith(p));
  }

  @override
  void visitAnnotation(Annotation node) {
    // Check for asset references in annotations
    if (node.arguments != null) {
      for (final arg in node.arguments!.arguments) {
        if (arg is SimpleStringLiteral) {
          _checkStringForAssetPath(arg.value, arg);
        }
      }
    }
    super.visitAnnotation(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    // Check const/final string declarations that might be asset paths
    final initializer = node.initializer;
    if (initializer is SimpleStringLiteral) {
      _checkStringForAssetPath(initializer.value, initializer);
    }
    super.visitVariableDeclaration(node);
  }

  /// Check if a string looks like an asset path
  void _checkStringForAssetPath(String value, AstNode node) {
    if (_looksLikeAssetPath(value)) {
      detectedAssets.add(_normalizePath(value));
    }
  }

  /// Determine if a string looks like an asset path
  bool _looksLikeAssetPath(String value) {
    if (value.isEmpty) return false;

    // Check for common asset prefixes
    final lowerValue = value.toLowerCase();
    for (final prefix in _assetPrefixes) {
      if (lowerValue.startsWith(prefix)) {
        return true;
      }
    }

    // Check for asset file extensions
    final extension = _getExtension(value);
    if (assetExtensions.contains(extension.toLowerCase())) {
      // Additional check: should look like a path (contains /)
      if (value.contains('/')) {
        return true;
      }
    }

    // Check for package asset syntax: packages/package_name/assets/...
    if (lowerValue.startsWith('packages/') && lowerValue.contains('/assets/')) {
      return true;
    }

    return false;
  }

  /// Extract asset path from method/constructor arguments
  void _extractAssetFromArguments(ArgumentList arguments) {
    if (arguments.arguments.isEmpty) return;

    // First positional argument is usually the asset path
    final firstArg = arguments.arguments.first;

    if (firstArg is SimpleStringLiteral) {
      final path = firstArg.value;
      if (_looksLikeAssetPath(path) || _hasAssetExtension(path)) {
        detectedAssets.add(_normalizePath(path));
      }
    } else if (firstArg is StringInterpolation) {
      // Handle dynamic paths
      visitStringInterpolation(firstArg);
    } else if (firstArg is NamedExpression) {
      // Check named arguments
      for (final arg in arguments.arguments) {
        if (arg is NamedExpression) {
          final name = arg.name.label.name;
          if (['name', 'path', 'asset', 'assetName'].contains(name)) {
            final expr = arg.expression;
            if (expr is SimpleStringLiteral) {
              final path = expr.value;
              if (_looksLikeAssetPath(path) || _hasAssetExtension(path)) {
                detectedAssets.add(_normalizePath(path));
              }
            }
          }
        }
      }
    }
  }

  /// Extract font family from TextStyle arguments
  void _extractFontFamily(ArgumentList arguments) {
    for (final arg in arguments.arguments) {
      if (arg is NamedExpression && arg.name.label.name == 'fontFamily') {
        final expr = arg.expression;
        if (expr is SimpleStringLiteral) {
          usedFontFamilies.add(expr.value);
        }
      }
    }
  }

  /// Extract the static directory part before any dynamic segment
  String _extractStaticDirectory(String path) {
    final dynamicIndex = path.indexOf('*');
    if (dynamicIndex == -1) return path;

    final staticPart = path.substring(0, dynamicIndex);
    final lastSlash = staticPart.lastIndexOf('/');
    if (lastSlash == -1) return '';

    return staticPart.substring(0, lastSlash + 1);
  }

  /// Get file extension from path
  String _getExtension(String path) {
    final lastDot = path.lastIndexOf('.');
    if (lastDot == -1 || lastDot == path.length - 1) return '';
    return path.substring(lastDot + 1);
  }

  /// Check if path has a known asset extension
  bool _hasAssetExtension(String path) {
    final ext = _getExtension(path).toLowerCase();
    return assetExtensions.contains(ext);
  }

  /// Normalize path for comparison
  String _normalizePath(String path) {
    return path.replaceAll('\\', '/').replaceAll('//', '/');
  }
}

/// Result of visiting a Dart file
class AssetVisitorResult {
  final Set<String> detectedAssets;
  final Set<String> potentialDirectories;
  final Set<String> usedFontFamilies;
  final Set<String> generatedAssetAccesses;
  final List<ScanWarning> warnings;

  const AssetVisitorResult({
    required this.detectedAssets,
    required this.potentialDirectories,
    required this.usedFontFamilies,
    required this.generatedAssetAccesses,
    required this.warnings,
  });

  /// Create from visitor
  factory AssetVisitorResult.fromVisitor(AssetReferenceVisitor visitor) {
    return AssetVisitorResult(
      detectedAssets: visitor.detectedAssets,
      potentialDirectories: visitor.potentialDirectories,
      usedFontFamilies: visitor.usedFontFamilies,
      generatedAssetAccesses: visitor.generatedAssetAccesses,
      warnings: visitor.warnings,
    );
  }

  /// Merge multiple results
  static AssetVisitorResult merge(List<AssetVisitorResult> results) {
    final detectedAssets = <String>{};
    final potentialDirectories = <String>{};
    final usedFontFamilies = <String>{};
    final generatedAssetAccesses = <String>{};
    final warnings = <ScanWarning>[];

    for (final result in results) {
      detectedAssets.addAll(result.detectedAssets);
      potentialDirectories.addAll(result.potentialDirectories);
      usedFontFamilies.addAll(result.usedFontFamilies);
      generatedAssetAccesses.addAll(result.generatedAssetAccesses);
      warnings.addAll(result.warnings);
    }

    return AssetVisitorResult(
      detectedAssets: detectedAssets,
      potentialDirectories: potentialDirectories,
      usedFontFamilies: usedFontFamilies,
      generatedAssetAccesses: generatedAssetAccesses,
      warnings: warnings,
    );
  }
}
