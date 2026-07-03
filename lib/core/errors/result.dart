import 'package:auto_explore/core/errors/domain_error.dart';

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
