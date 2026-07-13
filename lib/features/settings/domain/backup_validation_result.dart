/// Sealed hierarchy representing the result of validating an incoming
/// backup file before a restore operation is performed.
///
/// Use [BackupValid] to proceed with a restore; use [BackupInvalid] to surface
/// the rejection reason to the user without touching the live database.
sealed class BackupValidationResult {
  const BackupValidationResult();
}

/// The backup file passed all validation checks and is safe to restore.
final class BackupValid extends BackupValidationResult {
  const BackupValid({required this.schemaVersion});

  /// The Drift `user_version` stored in the backup file (= app schemaVersion).
  /// Will be <= current schemaVersion (4); Drift runs onUpgrade if less.
  final int schemaVersion;
}

/// The backup file was rejected; [reason] describes why.
///
/// Reasons include: corrupt file, not a Trailblazer database, created by a
/// newer app version, or missing required tables.
final class BackupInvalid extends BackupValidationResult {
  const BackupInvalid(this.reason);

  /// Human-readable explanation of why the file was rejected.
  final String reason;
}
