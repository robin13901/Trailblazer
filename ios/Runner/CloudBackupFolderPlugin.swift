import Flutter
import UIKit
import UniformTypeIdentifiers

/// Native handler for persistent write access to a user-chosen folder
/// (intended to be a OneDrive-synced folder) used by the automatic-backup
/// feature.
///
/// `file_picker` cannot do this on iOS: its directory pick returns a transient
/// path with no security-scoped bookmark, worthless after an app restart. This
/// handler saves a security-scoped bookmark on pick and resolves it on every
/// write, so access survives relaunches.
///
/// Method channel: `de.autoexplore.auto_explore/cloud_backup_folder`
///   - pickFolder() -> Bool            (true = folder chosen, false = cancelled)
///   - hasFolder() -> Bool             (bookmark resolvable & accessible)
///   - writeBackup({localFilePath, destFileName}) -> Void  (FlutterError on failure)
///   - folderDisplayName() -> String?  (folder's last path component)
final class CloudBackupFolderPlugin: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private weak var viewController: UIViewController?

  /// In-flight pick result; set while the document picker is presented.
  private var pendingPickResult: FlutterResult?

  /// Error code mapped by Dart to a "folder access lost — re-pick" prompt.
  private static let lostAccessCode = "stale_bookmark"

  init(channel: FlutterMethodChannel, viewController: UIViewController?) {
    self.channel = channel
    self.viewController = viewController
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  // MARK: - Bookmark persistence

  /// Location of the security-scoped bookmark blob in Application Support.
  private func bookmarkURL() -> URL {
    let dir = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    )[0]
    // Application Support is not guaranteed to exist on a fresh install.
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true
    )
    return dir.appendingPathComponent("cloud_backup_bookmark.dat")
  }

  private func saveBookmark(_ data: Data) {
    try? data.write(to: bookmarkURL(), options: .atomic)
  }

  private func loadBookmark() -> Data? {
    try? Data(contentsOf: bookmarkURL())
  }

  /// Resolves the stored bookmark to a folder URL, refreshing it when stale.
  /// Returns nil when no bookmark exists or it cannot be resolved.
  private func resolveFolderURL() -> URL? {
    guard let data = loadBookmark() else { return nil }
    var isStale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    else { return nil }
    if isStale {
      // Re-write a fresh bookmark while we briefly hold access.
      if url.startAccessingSecurityScopedResource() {
        defer { url.stopAccessingSecurityScopedResource() }
        if let fresh = try? url.bookmarkData(
          options: .minimalBookmark,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        ) {
          saveBookmark(fresh)
        }
      }
    }
    return url
  }

  // MARK: - Method dispatch

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickFolder":
      presentPicker(result: result)
    case "hasFolder":
      result(hasFolder())
    case "writeBackup":
      writeBackup(call.arguments, result: result)
    case "folderDisplayName":
      result(resolveFolderURL()?.lastPathComponent)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - pickFolder

  private func presentPicker(result: @escaping FlutterResult) {
    guard let vc = viewController else {
      result(false)
      return
    }
    pendingPickResult = result
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    } else {
      picker = UIDocumentPickerViewController(
        documentTypes: ["public.folder"], in: .open
      )
    }
    picker.delegate = self
    picker.allowsMultipleSelection = false
    vc.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    let result = pendingPickResult
    pendingPickResult = nil
    guard let folderURL = urls.first else {
      result?(false)
      return
    }
    let didAccess = folderURL.startAccessingSecurityScopedResource()
    defer { if didAccess { folderURL.stopAccessingSecurityScopedResource() } }
    if let data = try? folderURL.bookmarkData(
      options: .minimalBookmark,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    ) {
      saveBookmark(data)
      result?(true)
    } else {
      result?(false)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pendingPickResult
    pendingPickResult = nil
    result?(false)
  }

  // MARK: - hasFolder

  private func hasFolder() -> Bool {
    guard let url = resolveFolderURL() else { return false }
    let ok = url.startAccessingSecurityScopedResource()
    if ok { url.stopAccessingSecurityScopedResource() }
    return ok
  }

  // MARK: - writeBackup

  private func writeBackup(_ arguments: Any?, result: @escaping FlutterResult) {
    guard
      let args = arguments as? [String: Any],
      let localFilePath = args["localFilePath"] as? String,
      let destFileName = args["destFileName"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "missing arguments", details: nil))
      return
    }

    guard let folderURL = resolveFolderURL() else {
      result(FlutterError(
        code: Self.lostAccessCode,
        message: "no folder bookmark / unresolvable",
        details: nil
      ))
      return
    }

    guard folderURL.startAccessingSecurityScopedResource() else {
      result(FlutterError(
        code: Self.lostAccessCode,
        message: "security-scoped access denied",
        details: nil
      ))
      return
    }
    defer { folderURL.stopAccessingSecurityScopedResource() }

    let srcURL = URL(fileURLWithPath: localFilePath)
    let destURL = folderURL.appendingPathComponent(destFileName)

    // Coordinated write — OneDrive/Files providers expect coordinated access.
    var coordinatorError: NSError?
    var writeError: Error?
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(
      writingItemAt: destURL, options: .forReplacing, error: &coordinatorError
    ) { (writeURL) in
      do {
        if FileManager.default.fileExists(atPath: writeURL.path) {
          try FileManager.default.removeItem(at: writeURL)
        }
        try FileManager.default.copyItem(at: srcURL, to: writeURL)
      } catch {
        writeError = error
      }
    }

    if let err = coordinatorError ?? (writeError as NSError?) {
      result(FlutterError(
        code: "write_failed",
        message: err.localizedDescription,
        details: nil
      ))
      return
    }
    result(nil)
  }
}
