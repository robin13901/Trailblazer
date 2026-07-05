// runtimeType is retained in toString() for diagnostic clarity, mirroring
// the app-side DomainError convention documented in STATE.md (Plan 01-04).
// ignore_for_file: no_runtimetype_tostring

/// Pipeline-side counterpart to the app's `DomainError`.
///
/// The pipeline lives under `tool/` outside `lib/`, so it cannot import the
/// app package's `DomainError`. This sealed hierarchy mirrors the same shape
/// (message + optional cause + optional stackTrace) so the CLI's boundary
/// discipline stays consistent: wrap raw throwables at parse/IO boundaries,
/// unwrap at the CLI edge, exit with a non-zero code.
sealed class PipelineError implements Exception {
  /// Create a pipeline error.
  const PipelineError(this.message, {this.cause, this.stackTrace});

  /// Human-readable summary of what went wrong.
  final String message;

  /// Optional underlying cause (typically the caught throwable).
  final Object? cause;

  /// Optional stack trace captured at the wrap point.
  final StackTrace? stackTrace;

  @override
  String toString() {
    final buffer = StringBuffer('$runtimeType: $message');
    if (cause != null) {
      buffer.write(' (cause: $cause)');
    }
    return buffer.toString();
  }
}

/// Raised when CLI arguments are missing, malformed, or out of range.
final class PipelineArgsError extends PipelineError {
  /// Create an args error.
  const PipelineArgsError(super.message, {super.cause, super.stackTrace});
}

/// Raised when a required input file is absent or unreadable.
final class PipelineIoError extends PipelineError {
  /// Create an IO error.
  const PipelineIoError(super.message, {super.cause, super.stackTrace});
}
