/// Represents an asset file in the project
class Asset {
  /// The path to the asset file (relative to project root)
  final String path;

  /// The type of asset
  final AssetType type;

  /// The package this asset belongs to (for monorepo support)
  final String? packageName;

  /// Whether this asset is declared via glob pattern
  final bool isDeclaredViaGlob;

  /// The original declaration in pubspec.yaml
  final String declaration;

  const Asset({
    required this.path,
    required this.type,
    this.packageName,
    this.isDeclaredViaGlob = false,
    required this.declaration,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Asset &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          packageName == other.packageName;

  @override
  int get hashCode => path.hashCode ^ (packageName?.hashCode ?? 0);

  @override
  String toString() => 'Asset(path: $path, type: $type, package: $packageName)';

  /// Get the normalized path for comparison
  String get normalizedPath => path.replaceAll('\\', '/').toLowerCase();

  /// Get just the filename
  String get filename => path.split('/').last;

  /// Get the directory containing this asset
  String get directory {
    final parts = path.split('/');
    if (parts.length <= 1) return '';
    return parts.sublist(0, parts.length - 1).join('/');
  }
}

/// Types of assets supported
enum AssetType {
  image,
  font,
  json,
  lottie,
  other;

  static AssetType fromExtension(String extension) {
    final ext = extension.toLowerCase().replaceAll('.', '');
    switch (ext) {
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'bmp':
      case 'svg':
        return AssetType.image;
      case 'ttf':
      case 'otf':
      case 'woff':
      case 'woff2':
        return AssetType.font;
      case 'json':
        // Could be JSON or Lottie - we'll determine based on content/path
        return AssetType.json;
      default:
        return AssetType.other;
    }
  }

  /// Check if this is a Lottie file based on path patterns
  static AssetType fromPath(String path) {
    final ext = path.split('.').last;
    final type = fromExtension(ext);

    // Check if it's likely a Lottie animation
    if (type == AssetType.json) {
      final lowerPath = path.toLowerCase();
      if (lowerPath.contains('lottie') || lowerPath.contains('animation')) {
        return AssetType.lottie;
      }
    }

    return type;
  }
}

/// Extension to get file extension
extension StringExtension on String {
  String get fileExtension {
    final parts = split('.');
    if (parts.length < 2) return '';
    return parts.last;
  }
}
