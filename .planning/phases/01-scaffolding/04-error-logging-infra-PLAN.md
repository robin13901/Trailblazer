---
plan: "04"
name: "error-logging-infra"
wave: 2
depends_on: ["01"]
files_modified:
  - "lib/core/logging/app_logger.dart"      # replaces Plan 01 stub
  - "lib/core/errors/domain_error.dart"
  - "lib/core/errors/result.dart"
  - "lib/main.dart"                         # updated to add global error hooks
  - "test/core/logging/app_logger_test.dart"
  - "test/core/errors/domain_error_test.dart"
autonomous: true
requirements: ["FND-10"]
must_haves:
  truths:
    - "Debug builds log at `Level.ALL`; release builds log at `Level.WARNING` or above."
    - "`FlutterError.onError` and `PlatformDispatcher.instance.onError` both funnel into the AppLogger."
    - "A typed `DomainError` sealed hierarchy exists in `lib/core/errors/` with at least four concrete subtypes covering DB, storage, permission, and network categories."
    - "A `Result<T>` sum type is available for use cases that must return failure without throwing."
  artifacts:
    - path: "lib/core/logging/app_logger.dart"
      provides: "setupLogging() + kDebugMode gate + plain-text sink"
      contains: "setupLogging"
    - path: "lib/core/errors/domain_error.dart"
      provides: "Sealed DomainError hierarchy (DatabaseError, StorageError, PermissionDeniedError, NetworkError, UnknownError)"
      contains: "sealed class DomainError"
    - path: "lib/core/errors/result.dart"
      provides: "sealed Result<T> with Ok<T> / Err<T>"
      contains: "sealed class Result"
    - path: "lib/main.dart"
      provides: "Wires FlutterError.onError + PlatformDispatcher.instance.onError to AppLogger"
      contains: "FlutterError.onError"
  key_links:
    - from: "lib/main.dart"
      to: "lib/core/logging/app_logger.dart"
      via: "setupLogging() called before runApp"
      pattern: "setupLogging\\(\\)"
    - from: "lib/main.dart"
      to: "lib/core/errors/domain_error.dart"
      via: "onError handlers reference DomainError.wrap"
      pattern: "DomainError"
---

<objective>
Deliver the error and logging foundation for every downstream phase: a `logging`-backed AppLogger with a debug-vs-release level gate, global Flutter + Dart error hooks that funnel exceptions into the logger, a sealed `DomainError` hierarchy, and a small `Result<T>` type for repositories/use cases that must return failure without throwing.
</objective>

<context>
- **Package:** `logging: ^1.3.0` (pinned in Plan 01). NOT `logger` — RESEARCH.md compared both and picked `logging` (line 1135).
- **AppLogger pattern:** RESEARCH.md lines 686-716.
- **Global error hooks:** RESEARCH.md lines 736-751, 1017-1028.
- **CONTEXT.md decisions:** no crash reporting (dev logs only); debug = verbose, release = warnings+errors; log format = Claude's discretion → plain text (RESEARCH.md line 754); global handler = Claude's discretion → yes, use `FlutterError.onError` + `PlatformDispatcher.instance.onError`.
- **DomainError design:** New — no direct RESEARCH.md snippet. Use Dart 3 `sealed class` syntax (`sdk >=3.10.0` supports pattern matching). Categories mirror the errors Phase 2+ will encounter: database (Drift), storage (path_provider/filesystem), permission (permission_handler in Phase 3), network (OSM download in Phase 5).
</context>

<tasks>

<task id="4.1" type="auto">
  <name>Replace app_logger stub with real setupLogging() + tests</name>
  <files>
    - `lib/core/logging/app_logger.dart`
    - `test/core/logging/app_logger_test.dart`
  </files>
  <action>

    **Replace `lib/core/logging/app_logger.dart`:**

    ```dart
    import 'dart:developer' as developer;

    import 'package:flutter/foundation.dart';
    import 'package:logging/logging.dart';

    /// Configure the root logger. Call ONCE from `main()` before `runApp`.
    ///
    /// * Debug builds: `Level.ALL` (everything).
    /// * Release builds: `Level.WARNING` (warnings + severe only).
    ///
    /// Sink is `dart:developer` `log()` in debug (structured DevTools output)
    /// and `debugPrint` in release for CI-visible logs. No remote sink —
    /// diagnostics screen (Phase 10) will surface these locally.
    void setupLogging() {
      Logger.root.level = kDebugMode ? Level.ALL : Level.WARNING;
      Logger.root.onRecord.listen(_emit);
    }

    void _emit(LogRecord r) {
      final line =
          '${r.level.name}: [${r.loggerName}] ${r.time.toIso8601String()} ${r.message}';
      if (kDebugMode) {
        developer.log(
          r.message,
          name: r.loggerName,
          level: r.level.value,
          time: r.time,
          error: r.error,
          stackTrace: r.stackTrace,
        );
      } else {
        debugPrint(line);
        if (r.error != null) {
          debugPrint('  ERROR: ${r.error}');
        }
        if (r.stackTrace != null) {
          debugPrint('  STACK: ${r.stackTrace}');
        }
      }
    }
    ```

    **`test/core/logging/app_logger_test.dart`:**

    ```dart
    import 'package:auto_explore/core/logging/app_logger.dart';
    import 'package:flutter_test/flutter_test.dart';
    import 'package:logging/logging.dart';

    void main() {
      setUp(() {
        // Reset in case another test in the isolate configured it.
        Logger.root.clearListeners();
        Logger.root.level = Level.OFF;
      });

      test('setupLogging enables logging and root has listeners', () {
        setupLogging();
        expect(Logger.root.level, isNot(Level.OFF));
        // At least one onRecord listener has been attached.
        var received = 0;
        Logger('unit-test').onRecord.listen((_) => received++);
        Logger('unit-test').warning('probe');
        // Give the stream a tick.
        return Future<void>.delayed(Duration.zero).then((_) {
          expect(received, greaterThanOrEqualTo(1));
        });
      });
    }
    ```
  </action>
  <verify>
    ```bash
    flutter analyze --fatal-infos lib/core/logging/ test/core/logging/
    flutter test test/core/logging/
    ```
  </verify>
  <done>AppLogger compiles clean; test proves logging is enabled after `setupLogging()`.</done>
</task>

<task id="4.2" type="auto">
  <name>Create sealed DomainError hierarchy + Result<T> + tests</name>
  <files>
    - `lib/core/errors/domain_error.dart`
    - `lib/core/errors/result.dart`
    - `test/core/errors/domain_error_test.dart`
  </files>
  <action>

    **`lib/core/errors/domain_error.dart`:**

    ```dart
    /// Sealed error hierarchy — every layer above `core/` should surface
    /// failures as one of these subtypes (or wrap unknown throwables via
    /// [DomainError.wrap]) rather than leaking driver-specific exceptions.
    ///
    /// Downstream phases add subtypes as needed (extend one of the categories
    /// below, do not add new top-level branches lightly).
    sealed class DomainError implements Exception {
      const DomainError(this.message, {this.cause, this.stackTrace});

      final String message;
      final Object? cause;
      final StackTrace? stackTrace;

      /// Wrap an arbitrary throwable as an [UnknownError] unless it is
      /// already a [DomainError].
      static DomainError wrap(Object error, [StackTrace? stackTrace]) {
        if (error is DomainError) return error;
        return UnknownError(
          error.toString(),
          cause: error,
          stackTrace: stackTrace,
        );
      }

      @override
      String toString() => '$runtimeType: $message'
          '${cause == null ? '' : ' (caused by: $cause)'}';
    }

    /// Failure originating in the App DB layer (Drift / SQLite).
    final class DatabaseError extends DomainError {
      const DatabaseError(super.message, {super.cause, super.stackTrace});
    }

    /// Failure originating in filesystem or app-directory access.
    final class StorageError extends DomainError {
      const StorageError(super.message, {super.cause, super.stackTrace});
    }

    /// A required OS permission was not granted (location, motion, bluetooth).
    final class PermissionDeniedError extends DomainError {
      const PermissionDeniedError(
        super.message, {
        required this.permission,
        super.cause,
        super.stackTrace,
      });

      final String permission;
    }

    /// Network / HTTP failure (OSM extract download, future syncs).
    final class NetworkError extends DomainError {
      const NetworkError(
        super.message, {
        this.statusCode,
        super.cause,
        super.stackTrace,
      });

      final int? statusCode;
    }

    /// Catch-all for genuinely unexpected failures.
    final class UnknownError extends DomainError {
      const UnknownError(super.message, {super.cause, super.stackTrace});
    }
    ```

    **`lib/core/errors/result.dart`:**

    ```dart
    import 'domain_error.dart';

    /// Minimal sum type for use cases that must return failure without
    /// throwing (e.g. inbox actions, matcher outcomes).
    sealed class Result<T> {
      const Result();

      bool get isOk => this is Ok<T>;
      bool get isErr => this is Err<T>;

      /// Fold on the two cases.
      R when<R>({
        required R Function(T value) ok,
        required R Function(DomainError error) err,
      }) {
        final self = this;
        return switch (self) {
          Ok<T>(:final value) => ok(value),
          Err<T>(:final error) => err(error),
        };
      }
    }

    final class Ok<T> extends Result<T> {
      const Ok(this.value);
      final T value;
    }

    final class Err<T> extends Result<T> {
      const Err(this.error);
      final DomainError error;
    }
    ```

    **`test/core/errors/domain_error_test.dart`:**

    ```dart
    import 'package:auto_explore/core/errors/domain_error.dart';
    import 'package:auto_explore/core/errors/result.dart';
    import 'package:flutter_test/flutter_test.dart';

    void main() {
      group('DomainError.wrap', () {
        test('passes DomainError through unchanged', () {
          const original = DatabaseError('foo');
          expect(DomainError.wrap(original), same(original));
        });

        test('wraps arbitrary throwables as UnknownError', () {
          final wrapped = DomainError.wrap(StateError('boom'));
          expect(wrapped, isA<UnknownError>());
          expect(wrapped.cause, isA<StateError>());
        });
      });

      group('Result', () {
        test('Ok maps via when()', () {
          const r = Ok<int>(42);
          final label = r.when(
            ok: (v) => 'ok:$v',
            err: (e) => 'err:${e.message}',
          );
          expect(label, 'ok:42');
        });

        test('Err maps via when()', () {
          const r = Err<int>(NetworkError('offline'));
          final label = r.when(
            ok: (v) => 'ok:$v',
            err: (e) => 'err:${e.message}',
          );
          expect(label, 'err:offline');
        });
      });
    }
    ```
  </action>
  <verify>
    ```bash
    flutter analyze --fatal-infos lib/core/errors/ test/core/errors/
    flutter test test/core/errors/
    ```
  </verify>
  <done>Sealed hierarchy compiles under Dart 3.10 pattern-matching; Result<T> switch-exhaustive; four tests green.</done>
</task>

<task id="4.3" type="auto">
  <name>Wire global error hooks in lib/main.dart</name>
  <files>
    - `lib/main.dart`
  </files>
  <action>
    Replace `lib/main.dart` (from Plan 01) with:

    ```dart
    import 'dart:ui';

    import 'package:auto_explore/app.dart';
    import 'package:auto_explore/core/errors/domain_error.dart';
    import 'package:auto_explore/core/logging/app_logger.dart';
    import 'package:flutter/foundation.dart';
    import 'package:flutter/material.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'package:logging/logging.dart';

    final _log = Logger('main');

    void main() {
      WidgetsFlutterBinding.ensureInitialized();
      setupLogging();

      // Framework errors — build/layout/paint.
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        final wrapped = DomainError.wrap(details.exception, details.stack);
        _log.severe('FlutterError', wrapped, details.stack);
      };

      // Async errors outside Flutter's callback zone.
      PlatformDispatcher.instance.onError = (error, stack) {
        final wrapped = DomainError.wrap(error, stack);
        _log.severe('PlatformDispatcher.onError', wrapped, stack);
        return true; // Prevent OS-level crash.
      };

      runApp(const ProviderScope(child: App()));
    }
    ```

    Note: `dart:ui` is required for `PlatformDispatcher`. Do not remove the `import 'package:flutter/foundation.dart';` — kDebugMode reference in future edits will still need it (and no harm keeping it now for `debugPrint`).
  </action>
  <verify>
    ```bash
    flutter analyze --fatal-infos lib/main.dart
    dart format --set-exit-if-changed lib/main.dart
    flutter test test/widget_test.dart     # existing smoke test must still pass
    ```
  </verify>
  <done>`main.dart` compiles clean; smoke test still green; error hooks in place.</done>
</task>

</tasks>

<verification>
```bash
flutter analyze --fatal-infos
dart format --set-exit-if-changed .
flutter test
```
All exit 0.
</verification>

<must_haves>
Delivers FND-10 (logging, error boundaries, typed exceptions in `lib/core/`). Enables phase Success Criterion 1 (analyzer clean with real logging + error code present) and provides the foundation every later phase leans on when reporting failures.
</must_haves>
