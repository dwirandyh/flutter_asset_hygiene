import 'dart:io';

import 'package:yaml/yaml.dart';

import 'code_element.dart';

/// Configuration for unused code scanning
class CodeScanConfig {
  /// Root path to scan
  final String rootPath;

  /// Whether to include test files
  final bool includeTests;

  /// Patterns to exclude from scanning
  final List<String> excludePatterns;

  /// Patterns to include (if empty, include all)
  final List<String> includePatterns;

  /// Whether to exclude public API (exported symbols)
  final bool excludePublicApi;

  /// Whether to exclude @override methods
  final bool excludeOverrides;

  /// Whether to scan entire Melos workspace
  final bool scanWorkspace;

  /// Whether to analyze cross-package usage
  final bool crossPackageAnalysis;

  /// Output format
  final CodeOutputFormat outputFormat;

  /// Minimum severity to report
  final IssueSeverity minSeverity;

  /// Whether to run in verbose mode
  final bool verbose;

  /// Whether to auto-fix issues
  final bool fix;

  /// Whether to show what would be fixed without making changes
  final bool fixDryRun;

  /// Rule-specific configurations
  final RulesConfig rules;

  /// Public API configuration
  final PublicApiConfig publicApi;

  /// Monorepo-specific configuration
  final MonorepoConfig monorepo;

  const CodeScanConfig({
    required this.rootPath,
    this.includeTests = false,
    this.excludePatterns = const [],
    this.includePatterns = const [],
    this.excludePublicApi = false,
    this.excludeOverrides = true,
    this.scanWorkspace = true,
    this.crossPackageAnalysis = true,
    this.outputFormat = CodeOutputFormat.console,
    this.minSeverity = IssueSeverity.warning,
    this.verbose = false,
    this.fix = false,
    this.fixDryRun = false,
    this.rules = const RulesConfig(),
    this.publicApi = const PublicApiConfig(),
    this.monorepo = const MonorepoConfig(),
  });

  /// Load configuration from YAML file
  static Future<CodeScanConfig> fromYamlFile(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw ArgumentError('Config file not found: $path');
    }

    final content = await file.readAsString();
    final yaml = loadYaml(content) as YamlMap?;

    if (yaml == null) {
      return CodeScanConfig(rootPath: '.');
    }

    final unusedCode = yaml['unused_code'] as YamlMap? ?? yaml;

    return CodeScanConfig(
      rootPath: '.',
      includePatterns: _parseStringList(unusedCode['include']),
      excludePatterns: _parseStringList(unusedCode['exclude']),
      rules: RulesConfig.fromYaml(unusedCode['rules'] as YamlMap?),
      publicApi: PublicApiConfig.fromYaml(unusedCode['public_api'] as YamlMap?),
      monorepo: MonorepoConfig.fromYaml(unusedCode['monorepo'] as YamlMap?),
      outputFormat: _parseOutputFormat(unusedCode['output']),
      minSeverity: _parseSeverity(unusedCode['severity']),
    );
  }

  static List<String> _parseStringList(dynamic value) {
    if (value == null) return [];
    if (value is YamlList) {
      return value.map((e) => e.toString()).toList();
    }
    if (value is String) return [value];
    return [];
  }

  static CodeOutputFormat _parseOutputFormat(dynamic value) {
    if (value == null) return CodeOutputFormat.console;
    if (value is YamlMap) {
      final format = value['format']?.toString();
      return CodeOutputFormat.fromString(format ?? 'console');
    }
    return CodeOutputFormat.fromString(value.toString());
  }

  static IssueSeverity _parseSeverity(dynamic value) {
    if (value == null) return IssueSeverity.warning;
    if (value is YamlMap) {
      // Return the lowest severity from the map
      return IssueSeverity.warning;
    }
    return IssueSeverity.fromString(value.toString());
  }

  /// Default exclude patterns for generated files
  static const List<String> defaultExcludePatterns = [
    '**/*.g.dart',
    '**/*.freezed.dart',
    '**/*.gr.dart',
    '**/*.gen.dart',
    '**/*.mocks.dart',
    '**/generated/**',
    '**/.dart_tool/**',
  ];

  /// Get effective exclude patterns
  List<String> get effectiveExcludePatterns {
    return [...defaultExcludePatterns, ...excludePatterns];
  }

  CodeScanConfig copyWith({
    String? rootPath,
    bool? includeTests,
    List<String>? excludePatterns,
    List<String>? includePatterns,
    bool? excludePublicApi,
    bool? excludeOverrides,
    bool? scanWorkspace,
    bool? crossPackageAnalysis,
    CodeOutputFormat? outputFormat,
    IssueSeverity? minSeverity,
    bool? verbose,
    bool? fix,
    bool? fixDryRun,
    RulesConfig? rules,
    PublicApiConfig? publicApi,
    MonorepoConfig? monorepo,
  }) {
    return CodeScanConfig(
      rootPath: rootPath ?? this.rootPath,
      includeTests: includeTests ?? this.includeTests,
      excludePatterns: excludePatterns ?? this.excludePatterns,
      includePatterns: includePatterns ?? this.includePatterns,
      excludePublicApi: excludePublicApi ?? this.excludePublicApi,
      excludeOverrides: excludeOverrides ?? this.excludeOverrides,
      scanWorkspace: scanWorkspace ?? this.scanWorkspace,
      crossPackageAnalysis: crossPackageAnalysis ?? this.crossPackageAnalysis,
      outputFormat: outputFormat ?? this.outputFormat,
      minSeverity: minSeverity ?? this.minSeverity,
      verbose: verbose ?? this.verbose,
      fix: fix ?? this.fix,
      fixDryRun: fixDryRun ?? this.fixDryRun,
      rules: rules ?? this.rules,
      publicApi: publicApi ?? this.publicApi,
      monorepo: monorepo ?? this.monorepo,
    );
  }
}

/// Output format for code scan results
enum CodeOutputFormat {
  console,
  json,
  csv,
  html;

  static CodeOutputFormat fromString(String value) {
    switch (value.toLowerCase()) {
      case 'json':
        return CodeOutputFormat.json;
      case 'csv':
        return CodeOutputFormat.csv;
      case 'html':
        return CodeOutputFormat.html;
      default:
        return CodeOutputFormat.console;
    }
  }
}

/// Configuration for individual rules
class RulesConfig {
  final RuleConfig unusedClasses;
  final RuleConfig unusedFunctions;
  final RuleConfig unusedParameters;
  final RuleConfig unusedImports;
  final RuleConfig unusedMembers;
  final RuleConfig unusedExports;

  const RulesConfig({
    this.unusedClasses = const RuleConfig(),
    this.unusedFunctions = const RuleConfig(),
    this.unusedParameters = const RuleConfig(),
    this.unusedImports = const RuleConfig(),
    this.unusedMembers = const RuleConfig(),
    this.unusedExports = const RuleConfig(),
  });

  factory RulesConfig.fromYaml(YamlMap? yaml) {
    if (yaml == null) return const RulesConfig();

    return RulesConfig(
      unusedClasses: RuleConfig.fromYaml(yaml['unused_classes'] as YamlMap?),
      unusedFunctions: RuleConfig.fromYaml(yaml['unused_functions'] as YamlMap?),
      unusedParameters: RuleConfig.fromYaml(yaml['unused_parameters'] as YamlMap?),
      unusedImports: RuleConfig.fromYaml(yaml['unused_imports'] as YamlMap?),
      unusedMembers: RuleConfig.fromYaml(yaml['unused_members'] as YamlMap?),
      unusedExports: RuleConfig.fromYaml(yaml['unused_exports'] as YamlMap?),
    );
  }
}

/// Configuration for a single rule
class RuleConfig {
  final bool enabled;
  final List<String> excludePatterns;
  final List<String> excludeAnnotations;
  final bool excludePublic;
  final bool excludePrivate;
  final bool excludeStatic;
  final bool excludeOverrides;
  final bool excludeNamed;

  const RuleConfig({
    this.enabled = true,
    this.excludePatterns = const [],
    this.excludeAnnotations = const [],
    this.excludePublic = false,
    this.excludePrivate = false,
    this.excludeStatic = false,
    this.excludeOverrides = true,
    this.excludeNamed = false,
  });

  factory RuleConfig.fromYaml(YamlMap? yaml) {
    if (yaml == null) return const RuleConfig();

    return RuleConfig(
      enabled: yaml['enabled'] as bool? ?? true,
      excludePatterns: _parseStringList(yaml['exclude_patterns']),
      excludeAnnotations: _parseStringList(yaml['exclude_annotations']),
      excludePublic: yaml['exclude_public'] as bool? ?? false,
      excludePrivate: yaml['exclude_private'] as bool? ?? false,
      excludeStatic: yaml['exclude_static'] as bool? ?? false,
      excludeOverrides: yaml['exclude_overrides'] as bool? ?? true,
      excludeNamed: yaml['exclude_named'] as bool? ?? false,
    );
  }

  static List<String> _parseStringList(dynamic value) {
    if (value == null) return [];
    if (value is YamlList) {
      return value.map((e) => e.toString()).toList();
    }
    if (value is String) return [value];
    return [];
  }
}

/// Configuration for public API handling
class PublicApiConfig {
  /// Whether to consider exports as "used"
  final bool considerExportsAsUsed;

  /// Entry points that are always considered used
  final List<String> entryPoints;

  const PublicApiConfig({
    this.considerExportsAsUsed = true,
    this.entryPoints = const [],
  });

  factory PublicApiConfig.fromYaml(YamlMap? yaml) {
    if (yaml == null) return const PublicApiConfig();

    return PublicApiConfig(
      considerExportsAsUsed: yaml['consider_exports_as_used'] as bool? ?? true,
      entryPoints: _parseStringList(yaml['entry_points']),
    );
  }

  static List<String> _parseStringList(dynamic value) {
    if (value == null) return [];
    if (value is YamlList) {
      return value.map((e) => e.toString()).toList();
    }
    if (value is String) return [value];
    return [];
  }
}

/// Configuration for monorepo support
class MonorepoConfig {
  /// Whether monorepo mode is enabled
  final bool enabled;

  /// Whether to analyze cross-package usage
  final bool crossPackageAnalysis;

  /// Packages to include (empty = all)
  final List<String> includePackages;

  /// Packages to exclude
  final List<String> excludePackages;

  const MonorepoConfig({
    this.enabled = true,
    this.crossPackageAnalysis = true,
    this.includePackages = const [],
    this.excludePackages = const [],
  });

  factory MonorepoConfig.fromYaml(YamlMap? yaml) {
    if (yaml == null) return const MonorepoConfig();

    return MonorepoConfig(
      enabled: yaml['enabled'] as bool? ?? true,
      crossPackageAnalysis: yaml['cross_package_analysis'] as bool? ?? true,
      includePackages: _parseStringList(yaml['include_packages']),
      excludePackages: _parseStringList(yaml['exclude_packages']),
    );
  }

  static List<String> _parseStringList(dynamic value) {
    if (value == null) return [];
    if (value is YamlList) {
      return value.map((e) => e.toString()).toList();
    }
    if (value is String) return [value];
    return [];
  }
}

