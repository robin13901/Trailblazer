# Trailblazer — Claude notes

Project-scoped rules layered on top of `~/.claude/CLAUDE.md`.

## Ralph Loop tiering (adopted 2026-07-03)

This project runs the **tiered Ralph Loop** — matches Option A in the global CLAUDE.md.

### On every code change (tight loop)
```
flutter analyze
```
Fast (~5s once warm). Catches type errors, unused imports, lint violations, `very_good_analysis` rules. Commit only when green.

### Once, at the push boundary
```
.githooks/pre-push
  → flutter analyze --fatal-infos
  → flutter test
```
Wired via `git config core.hooksPath .githooks` (one-time per clone; hook is tracked in `.githooks/`, see `.githooks/README.md`).

Push is **blocked** on failure. Bypass paths:
- `git push --no-verify` (git-native)
- `TRAILBLAZER_SKIP_PREPUSH=1 git push` (env-guarded — logs the skip)

### When to still run `flutter test` inside the tight loop
- Change touches logic in `lib/core/**` (DB, routing, errors, logging)
- Change modifies a widget with existing tests
- Change alters generated `.g.dart` code (Drift/Riverpod)
- Any time you *suspect* a behavior regression — don't wait for pre-push to catch what you already know

For pure UI polish, docs, config, `.planning/**` edits: `flutter analyze` in the loop is enough — pre-push covers the tests.

## Phase 1 patterns to preserve (do not regress)

These are already in `.planning/STATE.md`, but surfaced here for the tight loop:

- **Riverpod codegen OFF** — use plain `Provider<T>` / `Notifier`, no `@Riverpod` annotations
- **Package imports only** — `package:auto_explore/…` (never relative imports); `very_good_analysis` enforces
- **`sort_pub_dependencies`** — new deps must be alphabetized in `pubspec.yaml`
- **`DomainError` + `Result<T>`** — wrap non-DomainError throwables at boundaries via `DomainError.wrap()`
- **Codegen order in CI** — `build_runner build` and `drift_dev schema generate` MUST run before `flutter analyze` / `flutter test` (the `.g.dart` and `test/generated_migrations/` files are gitignored)
- **`withValues(alpha:)`** — never `withOpacity()` (Flutter 3.44+ preferred API)
- **No `custom_lint` / `riverpod_lint`** — analyzer version conflict with `drift_dev 2.34`; re-adopt when upstream `custom_lint` bumps to analyzer 13
