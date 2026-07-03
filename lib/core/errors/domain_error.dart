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
  String toString() =>
      // Diagnostic output — runtimeType surfaces the concrete subtype in
      // logs, which is essential when scanning production log lines.
      // ignore: no_runtimetype_tostring
      '$runtimeType: $message'
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
