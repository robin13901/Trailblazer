package de.autoexplore.auto_explore

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var cloudBackupFolderHandler: CloudBackupFolderHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val handler = CloudBackupFolderHandler(applicationContext).also {
            it.activity = this
        }
        cloudBackupFolderHandler = handler

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CloudBackupFolderHandler.CHANNEL,
        ).setMethodCallHandler(handler)
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        // Forward the folder-tree pick result to the handler first; it returns
        // false for request codes it does not own.
        val consumed =
            cloudBackupFolderHandler?.onActivityResult(requestCode, resultCode, data)
                ?: false
        if (!consumed) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
