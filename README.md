# Unused Assets Scanner

CLI utility that finds unused assets in Flutter/Dart projects, including Melos workspaces, and can export results or delete the leftovers for you.

## Features
- Parses `pubspec.yaml` assets and fonts (files, directories, globs).
- Understands generated asset classes (flutter_gen/spider-style `*.gen.dart`).
- Cross-package scanning for Melos workspaces with package path resolution.
- Detects dynamic references and reports them as “potentially used”.
- Multiple outputs: console (colored), JSON, or CSV with optional file write.
- Optional deletion flow with confirmation prompt.

## Requirements
- Dart SDK ^3.8.1

## Installation
```sh
dart pub get
```

## Usage
Run the CLI from the repository root:
```sh
dart run lib/main.dart --help
```

Common examples:
- Scan current project: `dart run lib/main.dart`
- Scan another path: `dart run lib/main.dart --path /path/to/app`
- Disable workspace-wide scan: `dart run lib/main.dart --no-scan-workspace`
- Include tests / generated files: `dart run lib/main.dart --include-tests --include-generated`
- Exclude patterns: `dart run lib/main.dart --exclude "*.g.dart,**/generated/**"`
- JSON output to file: `dart run lib/main.dart --format json --output build/unused_assets.json`
- CSV output: `dart run lib/main.dart --format csv`
- Show used assets too: `dart run lib/main.dart --show-used`
- Hide potential matches: `dart run lib/main.dart --no-show-potential`
- Delete unused assets (with confirmation): `dart run lib/main.dart --delete`

Flags and defaults:
- `--path, -p` project root (default `.`)
- `--include-tests, -t` scan tests (default `false`)
- `--include-generated, -g` scan generated Dart files (default `false`)
- `--exclude, -e` comma-separated globs to skip
- `--format, -f` `console|json|csv` (default `console`)
- `--output, -o` file path for JSON/CSV
- `--verbose, -v` verbose logs (default `false`)
- `--delete, -d` delete unused assets after scan (default `false`)
- `--no-color` disable ANSI colors
- `--show-used` include used assets in output (default `false`)
- `--show-potential` include dynamic/potential assets (default `true`)
- `--scan-workspace, -w` cross-package scan in Melos workspaces (default `true`)
- `--help, -h`, `--version`

Exit codes:
- `0` when no unused assets are found
- `1` when unused assets exist or an unexpected error occurs
- `64` for usage errors (invalid arguments)

## How it works (high level)
1) Parses `pubspec.yaml` for declared assets/fonts (files, directories, and globs) and validates their existence.  
2) Reads generated asset files to map property accessors to real paths (e.g., `Assets.images.logo`).  
3) Walks Dart files with an AST visitor to detect string references, generated class usages, font families, and dynamic directory hints (flagged as “potential”).  
4) Matches detections back to declared assets, producing used/unused/potential sets and optional size summaries.  
5) In Melos workspaces, merges declared assets across packages and scans each package (and root lib) for cross-package usage.

## License
MIT
