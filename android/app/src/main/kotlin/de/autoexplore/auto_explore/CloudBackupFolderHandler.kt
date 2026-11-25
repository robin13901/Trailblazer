package de.autoexplore.auto_explore

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File

/**
 * Native handler for persistent write access to a user-chosen folder
 * (intended to be a OneDrive-synced folder) used by the automatic-backup
 * feature.
 *
 * Uses the Storage Access Framework: [Intent.ACTION_OPEN_DOCUMENT_TREE] +
 * [android.content.ContentResolver.takePersistableUriPermission] so the grant
 * survives reboots. The tree URI is persisted in SharedPreferences.
 *
 * Method channel: `de.autoexplore.auto_explore/cloud_backup_folder`
 *   - pickFolder() -> Boolean
 *   - hasFolder() -> Boolean
 *   - writeBackup({localFilePath, destFileName}) -> null  (MethodChannel error on failure)
 *   - folderDisplayName() -> String?
 */
class CloudBackupFolderHandler(
    private val context: Context,
) : MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {

    /** Set by [MainActivity] so the picker can be launched from the activity. */
    var activity: Activity? = null

    private var pendingResult: MethodChannel.Result? = null

    companion object {
        const val CHANNEL = "de.autoexplore.auto_explore/cloud_backup_folder"
        private const val REQ_PICK_TREE = 0x7B10
        private const val PREFS = "cloud_backup_prefs"
        private const val KEY_TREE_URI = "cloud_backup_tree_uri"
        /** Error code Dart maps to a "folder access lost — re-pick" prompt. */
        private const val LOST_ACCESS = "lost_permission"
    }

    private fun prefs() =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun storedTreeUri(): android.net.Uri? {
        val s = prefs().getString(KEY_TREE_URI, null) ?: return null
        return android.net.Uri.parse(s)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFolder" -> pickFolder(result)
            "hasFolder" -> result.success(hasFolder())
            "writeBackup" -> writeBackup(call, result)
            "folderDisplayName" -> result.success(folderDisplayName())
            else -> result.notImplemented()
        }
    }

    // ── pickFolder ──────────────────────────────────────────────────────────

    private fun pickFolder(result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.success(false)
            return
        }
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        act.startActivityForResult(intent, REQ_PICK_TREE)
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        if (requestCode != REQ_PICK_TREE) return false
        val result = pendingResult
        pendingResult = null

        val treeUri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (treeUri == null) {
            result?.success(false)
            return true
        }
        try {
            context.contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            prefs().edit().putString(KEY_TREE_URI, treeUri.toString()).apply()
            result?.success(true)
        } catch (e: SecurityException) {
            result?.success(false)
        }
        return true
    }

    // ── hasFolder ───────────────────────────────────────────────────────────

    private fun hasFolder(): Boolean {
        val uri = storedTreeUri() ?: return false
        // The grant must still be held (survives reboot) AND the tree writable.
        val held = context.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isWritePermission
        }
        if (!held) return false
        val doc = DocumentFile.fromTreeUri(context, uri)
        return doc?.canWrite() == true
    }

    // ── writeBackup ─────────────────────────────────────────────────────────

    private fun writeBackup(call: MethodCall, result: MethodChannel.Result) {
        val localFilePath = call.argument<String>("localFilePath")
        val destFileName = call.argument<String>("destFileName")
        if (localFilePath == null || destFileName == null) {
            result.error("bad_args", "missing arguments", null)
            return
        }
        val uri = storedTreeUri()
        if (uri == null) {
            result.error(LOST_ACCESS, "no folder chosen", null)
            return
        }
        try {
            val tree = DocumentFile.fromTreeUri(context, uri)
            if (tree == null || !tree.canWrite()) {
                result.error(LOST_ACCESS, "tree not writable", null)
                return
            }
            // Replace an existing same-named child so re-runs overwrite cleanly.
            tree.findFile(destFileName)?.delete()
            val child = tree.createFile("application/octet-stream", destFileName)
            if (child == null) {
                result.error("write_failed", "createFile returned null", null)
                return
            }
            context.contentResolver.openOutputStream(child.uri).use { out ->
                if (out == null) {
                    result.error("write_failed", "no output stream", null)
                    return
                }
                File(localFilePath).inputStream().use { input ->
                    input.copyTo(out)
                }
            }
            result.success(null)
        } catch (e: SecurityException) {
            result.error(LOST_ACCESS, e.message, null)
        } catch (e: Exception) {
            result.error("write_failed", e.message, null)
        }
    }

    // ── folderDisplayName ─────────────────────────────────────────────────────

    private fun folderDisplayName(): String? {
        val uri = storedTreeUri() ?: return null
        return DocumentFile.fromTreeUri(context, uri)?.name
    }
}
