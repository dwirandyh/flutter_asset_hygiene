# Repository Guidelines

## Project Structure & Module Organization
The CLI entrypoint lives in `lib/main.dart` and hands off to feature folders inside `lib/src`: CLI plumbing in `cli/`, analyzers in `code_analyzer/`, scanners in `scanner/`, and shared DTOs or helpers in `models/` and `utils/`. Tests mirror this map under `test/code_analyzer`, with an end-to-end fixture app in `test/fixtures/unused_code_project`. Keep generated artifacts inside `build/` or `.dart_tool/` so the analyzer ignores them.

## Build, Test, and Development Commands
- `dart pub get` — install or refresh dependencies.
- `dart run lib/main.dart assets --help` — review the asset-scan surface before adding flags.
- `dart run lib/main.dart unused-code --format json --output build/report.json` — sanity-check detector changes and export formats.
- `dart analyze` — enforce `analysis_options.yaml` lints.
- `dart test --reporter expanded` — run the package:test suite with verbose diffs for analyzer assertions.

## Coding Style & Naming Conventions
Linting sticks to `package:lints/recommended` plus `prefer_single_quotes`, so keep two-space indentation, trailing commas for multiline literals, and single quotes unless interpolation demands otherwise. Files remain snake_case (for example `unused_code_runner.dart`), public symbols use lowerCamelCase, and CLI flags stay kebab-case to match current help output. Run `dart format .` and `dart analyze` before review.

## Testing Guidelines
Place specs under `test/` with `_test.dart` filenames that mirror the source modules. Use `test/fixtures/unused_code_project` whenever a scenario spans packages or analyzer phases, documenting any new fixtures. Every regression test should prove a true positive and the false-positive guardrail it protects, keeping the false-positive rate below ~5%. Run `dart test` locally and mention notable CLI invocations in the test description.

## Commit & Pull Request Guidelines
Commits should use a short, imperative summary (`Enhance unused code detection logic...`) and contain one logical change plus the CLI command or test that proves it. PR descriptions explain the workflow, list new flags or config keys, link issues, and attach `dart run` output or screenshots for report tweaks. Note whether the change touches semantic analysis, AST mode, or both so reviewers can focus regression testing.

## Configuration Tips
Limit analyzer exclusions to generated directories (`build/**`, `.dart_tool/**`) to preserve coverage. When features need configuration, add `unused_code.yaml` snippets to the README or doc comments so users have a single canonical source.
