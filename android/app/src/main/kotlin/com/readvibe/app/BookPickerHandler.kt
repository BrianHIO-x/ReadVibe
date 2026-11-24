package com.readvibe.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Handles SAF document picking for single/multi book import, fonts, and backups. */
class BookPickerHandler(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        private const val REQUEST_PICK_DOCUMENT = 0x5242
        private const val ABANDONED_PICK_GRACE_MS = 1_500L
        private const val COPY_STALL_MS = 45_000L
        private const val COPY_STALL_CHECK_MS = 5_000L
        private const val COPY_STALL_MESSAGE =
            "读取所选文件长时间没有进展，请把文件保存到本机后重试"
    }

    private enum class PickMode { SINGLE_BOOK, MULTIPLE_BOOKS, FONT, BACKUP }

    private val channel = MethodChannel(messenger, "com.readvibe.app/book_picker")
    // Pool rather than a single thread so one stalled document provider never
    // blocks subsequent picks.
    private val worker = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingResult: MethodChannel.Result? = null
    private var pendingMode: PickMode? = null
    private var pickerTookForeground = false
    private var abandonedRunnable: Runnable? = null
    @Volatile private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            val mode = when (call.method) {
                "pick" -> PickMode.SINGLE_BOOK
                "pickBooks" -> PickMode.MULTIPLE_BOOKS
                "pickFont" -> PickMode.FONT
                "pickBackup" -> PickMode.BACKUP
                else -> {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
            }
            launchPicker(mode, result)
        }
    }

    private fun cancelAbandonedCheck() {
        abandonedRunnable?.let(mainHandler::removeCallbacks)
        abandonedRunnable = null
    }

    private fun launchPicker(mode: PickMode, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("already_active", "文件选择器已打开，请完成当前选择", null)
            return
        }
        cancelAbandonedCheck()
        pendingResult = result
        pendingMode = mode
        pickerTookForeground = false
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    if (mode == PickMode.MULTIPLE_BOOKS) {
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    }
                },
                REQUEST_PICK_DOCUMENT,
            )
        } catch (_: Exception) {
            pendingResult = null
            pendingMode = null
            result.error("invalid_format_type", "无法打开系统文件选择器", null)
        }
    }

    fun onPause() {
        if (pendingResult != null) pickerTookForeground = true
    }

    fun onResume() {
        if (!pickerTookForeground) return
        pickerTookForeground = false
        cancelAbandonedCheck()
        val runnable = Runnable {
            abandonedRunnable = null
            val abandoned = pendingResult ?: return@Runnable
            pendingResult = null
            pendingMode = null
            abandoned.success(null)
        }
        abandonedRunnable = runnable
        mainHandler.postDelayed(runnable, ABANDONED_PICK_GRACE_MS)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_DOCUMENT) return false
        cancelAbandonedCheck()
        pickerTookForeground = false
        val pending = pendingResult
        val mode = pendingMode
        pendingResult = null
        pendingMode = null
        if (pending == null || mode == null) return true
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.success(null)
            return true
        }
        val uris = extractUris(data)
        if (uris.isEmpty()) {
            pending.success(null)
            return true
        }
        when (mode) {
            PickMode.MULTIPLE_BOOKS -> copyMultipleBooks(uris, pending)
            PickMode.SINGLE_BOOK -> copySingle(pending) { lastProgress ->
                BookImportProbe.copyPickedBook(activity, uris.first()) {
                    lastProgress.set(System.currentTimeMillis())
                }
            }
            PickMode.FONT -> copySingle(pending) { lastProgress ->
                BookImportProbe.copyPickedFont(activity, uris.first()) {
                    lastProgress.set(System.currentTimeMillis())
                }
            }
            PickMode.BACKUP -> copySingle(pending) { lastProgress ->
                BookImportProbe.copyPickedBackup(activity, uris.first()) {
                    lastProgress.set(System.currentTimeMillis())
                }
            }
        }
        return true
    }

    private fun extractUris(data: Intent): List<Uri> {
        val clip = data.clipData
        if (clip != null && clip.itemCount > 0) {
            val result = ArrayList<Uri>(clip.itemCount)
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i)?.uri?.let(result::add)
            }
            if (result.isNotEmpty()) return result
        }
        return listOfNotNull(data.data)
    }

    private fun copySingle(
        pending: MethodChannel.Result,
        task: (AtomicLong) -> Map<String, String>,
    ) {
        val answered = AtomicBoolean(false)
        val lastProgress = AtomicLong(System.currentTimeMillis())
        watchCopyProgress(answered, lastProgress, pending)
        worker.execute {
            try {
                val copied = task(lastProgress)
                if (!disposed && answered.compareAndSet(false, true)) {
                    activity.runOnUiThread { pending.success(copied) }
                }
            } catch (error: Throwable) {
                val message = error.message ?: "无法读取所选文件"
                val code = errorCodeForMessage(message)
                if (!disposed && answered.compareAndSet(false, true)) {
                    activity.runOnUiThread { pending.error(code, message, null) }
                }
            }
        }
    }

    private fun copyMultipleBooks(uris: List<Uri>, pending: MethodChannel.Result) {
        val answered = AtomicBoolean(false)
        val lastProgress = AtomicLong(System.currentTimeMillis())
        watchCopyProgress(answered, lastProgress, pending)
        worker.execute {
            val files = ArrayList<Map<String, String>>(uris.size)
            val errors = ArrayList<Map<String, String>>()
            for (uri in uris) {
                if (disposed || answered.get()) return@execute
                try {
                    val copied = BookImportProbe.copyPickedBook(activity, uri) {
                        lastProgress.set(System.currentTimeMillis())
                    }
                    files.add(copied)
                } catch (error: Throwable) {
                    val message = error.message ?: "无法读取所选文件"
                    val name = runCatching {
                        BookImportProbe.resolveDisplayName(activity, uri)
                    }.getOrDefault("")
                    errors.add(
                        mapOf(
                            "code" to errorCodeForMessage(message),
                            "message" to message,
                            "name" to name,
                        ),
                    )
                }
            }
            if (!disposed && answered.compareAndSet(false, true)) {
                activity.runOnUiThread {
                    pending.success(
                        mapOf(
                            "files" to files,
                            "errors" to errors,
                        ),
                    )
                }
            }
        }
    }

    private fun errorCodeForMessage(message: String): String = when (message) {
        BookImportProbe.ANDROID_PACKAGE_MESSAGE -> "android_package"
        BookImportProbe.UNSUPPORTED_MESSAGE,
        BookImportProbe.INVALID_FONT_MESSAGE,
        BookImportProbe.INVALID_BACKUP_MESSAGE -> "unsupported"
        else -> "read_failed"
    }

    private fun watchCopyProgress(
        answered: AtomicBoolean,
        lastProgress: AtomicLong,
        pending: MethodChannel.Result,
    ) {
        mainHandler.postDelayed(
            object : Runnable {
                override fun run() {
                    if (disposed || answered.get()) return
                    val quiet = System.currentTimeMillis() - lastProgress.get()
                    if (quiet < COPY_STALL_MS) {
                        mainHandler.postDelayed(this, COPY_STALL_CHECK_MS)
                        return
                    }
                    if (answered.compareAndSet(false, true)) {
                        pending.error("read_failed", COPY_STALL_MESSAGE, null)
                    }
                }
            },
            COPY_STALL_CHECK_MS,
        )
    }

    fun dispose() {
        disposed = true
        cancelAbandonedCheck()
        channel.setMethodCallHandler(null)
        mainHandler.removeCallbacksAndMessages(null)
        worker.shutdownNow()
        pendingResult?.error("read_failed", "无法选择文件", null)
        pendingResult = null
        pendingMode = null
    }
}
