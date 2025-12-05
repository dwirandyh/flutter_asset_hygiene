# Repository Guidelines

## Project Structure & Module Organization
This package is a Dart CLI that scans Flutter/Dart projects for unused assets. `lib/main.dart` hosts the entry point and delegates to `lib/src/cli/cli_runner.dart` for option parsing and orchestration. Asset discovery lives in `lib/src/scanner/` (e.g., `asset_scanner.dart`, `generated_asset_parser.dart`, `melos_detector.dart`). Data models (`ScanConfig`, `ScanResult`, `AssetReference`) live under `lib/src/models/`, and helpers (logging, file access, YAML parsing) sit inside `lib/src/utils/`. Add tests under `test/`, mirroring the modules they exercise.

## Build, Test, and Development Commands
- `dart pub get` — install dependencies after cloning or updating `pubspec.yaml`.
- `dart run lib/main.dart --help` — view all CLI flags (path, workspace scan, output format, delete mode).
- `dart run lib/main.dart --path <project> --format json` — scan a target project, piping JSON/CSV to files with `--output`.
- `dart analyze` — run the static analyzer with `analysis_options.yaml` to enforce lint rules.
- `dart format lib test` — keep source consistent before reviews.
- `dart test` — execute unit and integration suites once they exist; keep the tree green before pushing.

## Coding Style & Naming Conventions
Follow the defaults from `package:lints` plus the local `prefer_single_quotes` rule; `dart format` with 2-space indents is the source of truth. Files and directories stay `snake_case`, classes `PascalCase`, and top-level constants `SCREAMING_SNAKE_CASE`. Keep CLI flag names lowercase with hyphenated words (`--include-tests`). Use the shared `Logger` for user output so verbosity and colors stay consistent, and funnel filesystem access through `FileUtils`.

## Testing Guidelines
Place unit tests under `test/`, mirroring the library path (e.g., `test/scanner/asset_scanner_test.dart`). Use `package:test` with descriptive `group` labels and fixture projects under `test/fixtures/` for realistic asset graphs. New code should include tests or justification if a scenario is untestable, and target >80% coverage on core scanners. Run `dart test -r expanded` locally and paste the command output into PR discussions for fixes.

## Commit & Pull Request Guidelines
The repo has no formal history yet, so follow Conventional Commits (`feat(scanner): report potential matches` or `fix(cli): guard delete flag`). Each PR should include a short description of the change, reproduction steps for bug fixes, and explicit CLI examples when flags are added or removed. Reference issues in the description (e.g., “Fixes #12”), attach screenshots or terminal snippets if the user experience changes, and check that `dart analyze`, `dart format`, and `dart test` succeed before requesting review. Flag risky operations such as `--delete` handling so reviewers can focus attention on safety-critical logic.
