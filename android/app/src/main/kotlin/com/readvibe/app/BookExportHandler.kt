package com.readvibe.app

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/** Copies a prepared private file to the document explicitly chosen by the user. */
class BookExportHandler(private val activity: Activity, messenger: BinaryMessenger) {
    companion object { private const val REQUEST_EXPORT = 0x7256 }
    private val channel = MethodChannel(messenger, "com.readvibe.app/book_export")
    private val executor = Executors.newSingleThreadExecutor()
    @Volatile private var disposed = false
    private data class Pending(val file: File, val result: MethodChannel.Result)
    private var pending: Pending? = null

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "save") {
                result.notImplemented()
            } else if (disposed || pending != null) {
                result.error("EXPORT_BUSY", "已有文件正在导出，请稍后重试", null)
            } else {
                try {
                    val path = call.argument<String>("sourcePath") ?: error("导出文件缺失")
                    val name = call.argument<String>("fileName") ?: error("文件名缺失")
                    val mime = call.argument<String>("mimeType") ?: error("文件类型缺失")
                    val source = File(path).canonicalFile
                    val root = File(activity.cacheDir, "readvibe_exports").canonicalFile
                    require(source.path.startsWith(root.path + File.separator) && source.isFile) {
                        "导出文件不可用"
                    }
                    require(name.isNotBlank() && !name.contains('/') && !name.contains('\\')) {
                        "文件名无效"
                    }
                    require(mime == "text/plain" || mime == "application/pdf") { "文件类型无效" }
                    pending = Pending(source, result)
                    activity.startActivityForResult(
                        Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = mime
                            putExtra(Intent.EXTRA_TITLE, name)
                        },
                        REQUEST_EXPORT,
                    )
                } catch (error: Exception) {
                    pending = null
                    result.error("EXPORT_OPEN_FAILED", error.message ?: "无法打开保存位置", null)
                }
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_EXPORT) return false
        val request = pending ?: return true
        if (resultCode != Activity.RESULT_OK) {
            pending = null
            request.result.success(false)
            return true
        }
        val uri = data?.data
        if (uri == null) {
            pending = null
            request.result.error("EXPORT_TARGET_MISSING", "未取得保存位置", null)
            return true
        }
        executor.execute {
            val error = runCatching {
                activity.contentResolver.openOutputStream(uri, "wt")?.use { output ->
                    request.file.inputStream().use { input ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            if (disposed) throw IOException("导出已中止")
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                        }
                        output.flush()
                    }
                } ?: throw IOException("无法写入所选位置")
            }.exceptionOrNull()
            activity.runOnUiThread {
                if (!disposed && pending === request) {
                    pending = null
                    if (error == null) request.result.success(true)
                    else request.result.error(
                        "EXPORT_WRITE_FAILED", "写入失败，请检查所选位置和目标文件", null,
                    )
                }
            }
        }
        return true
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        val request = pending
        pending = null
        request?.result?.error("EXPORT_ABORTED", "导出已中止", null)
        executor.shutdown()
    }
}
