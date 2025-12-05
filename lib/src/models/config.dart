/// Configuration for the Flutter Asset Hygiene
class ScanConfig {
  /// The root path to scan
  final String rootPath;

  /// Whether to include test files in the scan
  final bool includeTests;

  /// File patterns to exclude from scanning
  final List<String> excludePatterns;

  /// Output format
  final OutputFormat outputFormat;

  /// Whether to run in verbose mode
  final bool verbose;

  /// Whether to delete unused assets (with confirmation)
  final bool deleteUnused;

  /// Asset file extensions to scan for
  final Set<String> assetExtensions;

  /// Whether to scan generated files (*.g.dart, *.freezed.dart)
  final bool includeGenerated;

  /// Whether to suppress console output (for JSON/CSV output)
  final bool silent;

  /// Whether to scan entire Melos workspace for cross-package asset usage
  final bool scanWorkspace;

  const ScanConfig({
    required this.rootPath,
    this.includeTests = false,
    this.excludePatterns = const [],
    this.outputFormat = OutputFormat.console,
    this.verbose = false,
    this.deleteUnused = false,
    this.assetExtensions = defaultAssetExtensions,
    this.includeGenerated = false,
    this.silent = false,
    this.scanWorkspace = true,
  });

  /// Default asset extensions to scan
  static const Set<String> defaultAssetExtensions = {
    // Images
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg',
    // Fonts
    'ttf', 'otf', 'woff', 'woff2',
    // Data
    'json',
    // Other
    'xml', 'txt',
  };

  /// Default patterns to exclude
  static const List<String> defaultExcludePatterns = [
    '*.g.dart',
    '*.freezed.dart',
    '*.gr.dart',
    '*.gen.dart',
    '*.mocks.dart',
  ];

  /// Create config with defaults merged with provided exclude patterns
  ScanConfig copyWith({
    String? rootPath,
    bool? includeTests,
    List<String>? excludePatterns,
    OutputFormat? outputFormat,
    bool? verbose,
    bool? deleteUnused,
    Set<String>? assetExtensions,
    bool? includeGenerated,
    bool? silent,
    bool? scanWorkspace,
  }) {
    return ScanConfig(
      rootPath: rootPath ?? this.rootPath,
      includeTests: includeTests ?? this.includeTests,
      excludePatterns: excludePatterns ?? this.excludePatterns,
      outputFormat: outputFormat ?? this.outputFormat,
      verbose: verbose ?? this.verbose,
      deleteUnused: deleteUnused ?? this.deleteUnused,
      assetExtensions: assetExtensions ?? this.assetExtensions,
      includeGenerated: includeGenerated ?? this.includeGenerated,
      silent: silent ?? this.silent,
      scanWorkspace: scanWorkspace ?? this.scanWorkspace,
    );
  }

  /// Get all exclude patterns including defaults if not including generated
  List<String> get effectiveExcludePatterns {
    if (includeGenerated) {
      return excludePatterns;
    }
    return [...defaultExcludePatterns, ...excludePatterns];
  }
}

/// Output format for scan results
enum OutputFormat {
  console,
  json,
  csv;

  static OutputFormat fromString(String value) {
    switch (value.toLowerCase()) {
      case 'json':
        return OutputFormat.json;
      case 'csv':
        return OutputFormat.csv;
      default:
        return OutputFormat.console;
    }
  }
}
