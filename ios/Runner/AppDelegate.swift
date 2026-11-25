import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// Retained so its method-channel handler and document-picker delegate stay
  /// alive for the app's lifetime.
  private var cloudBackupFolderPlugin: CloudBackupFolderPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "de.autoexplore.auto_explore/cloud_backup_folder",
        binaryMessenger: controller.binaryMessenger
      )
      cloudBackupFolderPlugin = CloudBackupFolderPlugin(
        channel: channel,
        viewController: controller
      )
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
