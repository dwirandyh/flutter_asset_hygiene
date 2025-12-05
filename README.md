# Flutter Asset Hygiene

CLI utility that finds unused assets and dead code in Flutter/Dart projects, including Melos workspaces. Export results in multiple formats or clean up automatically.

## Features

### Asset Scanner (`assets` command)
- Parses `pubspec.yaml` assets and fonts (files, directories, globs).
- Understands generated asset classes (flutter_gen/spider-style `*.gen.dart`).
- Cross-package scanning for Melos workspaces with package path resolution.
- Detects dynamic references and reports them as "potentially used".
- Multiple outputs: console (colored), JSON, or CSV with optional file write.
- Optional deletion flow with confirmation prompt.

### Unused Code Detector (`unused-code` command)
- Detects unused classes, mixins, extensions, enums, and typedefs.
- Finds unused functions, methods, getters, setters, and constructors.
- Identifies unused imports, exports, parameters, and fields.
- Respects `@override`, `@visibleForTesting`, and other annotations.
- Cross-package analysis for Melos monorepos.
- YAML configuration support for fine-grained control.
- Multiple outputs: console, JSON, CSV, and HTML reports.

## Requirements
- Dart SDK ^3.8.1

## Installation
```sh
dart pub get
```

## Usage

### General Help
```sh
dart run lib/main.dart --help
```

### Asset Scanner

Scan for unused assets:
```sh
# Scan current project
dart run lib/main.dart assets

# Scan another path
dart run lib/main.dart assets --path /path/to/app

# JSON output to file
dart run lib/main.dart assets --format json --output build/unused_assets.json

# Delete unused assets (with confirmation)
dart run lib/main.dart assets --delete
```

Asset scanner flags:
- `--path, -p` path to the project root (default `.`)
- `--include-tests, -t` include test files in the scan (default `false`)
- `--include-generated, -g` include generated files (default `false`)
- `--exclude, -e` comma-separated glob patterns to exclude
- `--format, -f` output format: `console|json|csv` (default `console`)
- `--output, -o` output file path (for json/csv formats)
- `--verbose, -v` show verbose output
- `--delete, -d` delete unused assets with confirmation
- `--no-color` disable colored output
- `--show-used` also show used assets in the output
- `--show-potential` show potentially used assets (default `true`)
- `--scan-workspace, -w` scan entire Melos workspace (default `true`)

### Unused Code Detector

Detect unused code:
```sh
# Basic scan
dart run lib/main.dart unused-code

# Scan specific path
dart run lib/main.dart unused-code --path /path/to/project

# Include info-level issues (parameters, imports)
dart run lib/main.dart unused-code --severity info

# JSON output
dart run lib/main.dart unused-code --format json --output report.json

# HTML report
dart run lib/main.dart unused-code --format html --output report.html

# With custom config
dart run lib/main.dart unused-code --config unused_code.yaml
```

Unused code flags:
- `--path, -p` path to the project root (default `.`)
- `--config, -c` path to YAML configuration file (default `unused_code.yaml`)
- `--include-tests, -t` include test files in analysis
- `--exclude-public-api` skip public API (exported symbols)
- `--exclude-overrides` skip @override methods (default `true`)
- `--scan-workspace, -w` scan entire Melos workspace (default `true`)
- `--cross-package` detect cross-package usage in monorepo (default `true`)
- `--format, -f` output format: `console|json|csv|html` (default `console`)
- `--output, -o` output file path
- `--severity` minimum severity: `info|warning|error` (default `warning`)
- `--fix-dry-run` show what would be removed without making changes
- `--fix` auto-remove unused code (dangerous!)
- `--verbose, -v` show verbose output
- `--exclude, -e` comma-separated glob patterns to exclude

## YAML Configuration

Create `unused_code.yaml` in your project root for fine-grained control:

```yaml
unused_code:
  # Directories to analyze
  include:
    - lib/
    - bin/

  # Patterns to exclude
  exclude:
    - "**/*.g.dart"
    - "**/*.freezed.dart"
    - "**/generated/**"

  # Detection rules
  rules:
    unused_classes:
      enabled: true
      exclude_patterns:
        - "*Widget"
        - "*State"
        - "*Bloc"
      exclude_annotations:
        - "@immutable"
        - "@JsonSerializable"

    unused_functions:
      enabled: true
      exclude_public: false
      exclude_patterns:
        - "main"
        - "build*"

    unused_parameters:
      enabled: true
      exclude_overrides: true

    unused_imports:
      enabled: true

    unused_members:
      enabled: true
      exclude_private: false
      exclude_static: false

  # Public API handling
  public_api:
    consider_exports_as_used: true
    entry_points:
      - lib/main.dart

  # Monorepo settings
  monorepo:
    enabled: true
    cross_package_analysis: true
    exclude_packages:
      - example
```

## Exit Codes
- `0` - No issues found
- `1` - Unused assets/code found (warning level)
- `2` - Errors found (error level, unused-code only)
- `64` - Usage errors (invalid arguments)

## How It Works

### Asset Scanner
1. Parses `pubspec.yaml` for declared assets/fonts and validates their existence.
2. Reads generated asset files to map property accessors to real paths.
3. Walks Dart files with an AST visitor to detect references.
4. Matches detections back to declared assets.
5. In Melos workspaces, merges assets across packages and scans for cross-package usage.

### Unused Code Detector
1. **Collection Phase**: Scans all Dart files and collects declarations (classes, functions, etc.).
2. **Resolution Phase**: Re-scans to resolve all references and track usage.
3. **Detection Phase**: Compares declarations vs references, applying exclusion rules.
4. **Reporting Phase**: Generates reports in the requested format.

## License
MIT
