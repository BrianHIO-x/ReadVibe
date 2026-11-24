package com.readvibe.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.ArrayDeque
import java.util.concurrent.Executors

/** Receives Android ACTION_VIEW / ACTION_SEND files and stages them for Flutter. */
class IncomingFileHandler(
    private val activity: Activity,
    messenger: BinaryMessenger,
    initialIntent: Intent?,
) {
    private val channel = MethodChannel(messenger, "com.readvibe.app/incoming_file")
    private val executor = Executors.newSingleThreadExecutor()
    private val intents = ArrayDeque<Intent>()
    @Volatile private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "consumeNext") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val incoming = synchronized(intents) {
                if (intents.isEmpty()) null else intents.removeFirst()
            }
            if (incoming == null) {
                result.success(null)
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val copied = copyIncomingFile(incoming)
                    if (!disposed) {
                        activity.runOnUiThread { result.success(copied) }
                    }
                } catch (error: Throwable) {
                    if (!disposed) {
                        activity.runOnUiThread {
                            result.error(
                                "INCOMING_FILE_FAILED",
                                error.message ?: "无法读取外部文件",
                                null,
                            )
                        }
                    }
                }
            }
        }
        enqueue(initialIntent, notifyFlutter = false)
    }

    fun onNewIntent(intent: Intent) {
        enqueue(intent, notifyFlutter = true)
    }

    private fun enqueue(intent: Intent?, notifyFlutter: Boolean) {
        val uri = incomingFileUri(intent) ?: return
        val queued = Intent(intent).apply { data = uri }
        synchronized(intents) {
            while (intents.size >= 8) intents.removeFirst()
            intents.addLast(queued)
        }
        if (notifyFlutter && !disposed) channel.invokeMethod("available", null)
    }

    private fun incomingFileUri(intent: Intent?): Uri? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> extraStreamUri(intent) ?: intent.data
            else -> null
        }
    }

    private fun extraStreamUri(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        }
    }

    private fun copyIncomingFile(intent: Intent): Map<String, String> {
        val uri = intent.data ?: error("外部文件地址为空")
        val mimeType = intent.type.orEmpty()
        val resolver = activity.contentResolver
        val incomingDirectory = File(activity.cacheDir, "readvibe_incoming")
        if (!incomingDirectory.exists()) incomingDirectory.mkdirs()
        val staleBefore = System.currentTimeMillis() - 24L * 60L * 60L * 1000L
        incomingDirectory.listFiles()?.forEach { file ->
            if (file.lastModified() < staleBefore) file.delete()
        }

        var displayName: String? = null
        if (uri.scheme == "content") {
            resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (column >= 0) displayName = cursor.getString(column)
                }
            }
        }
        val resolverType = if (uri.scheme == "content") resolver.getType(uri).orEmpty() else ""
        val inferredExtension = when (mimeType.lowercase()) {
            "text/plain" -> ".txt"
            "application/epub+zip" -> ".epub"
            "application/x-mobipocket-ebook" -> ".mobi"
            "application/vnd.amazon.ebook" -> ".azw"
            "application/vnd.amazon.mobi8-ebook" -> ".azw3"
            "application/x-mobi8-ebook" -> ".azw3"
            "application/pdf" -> ".pdf"
            "application/msword" -> ".doc"
            "application/vnd.ms-word" -> ".doc"
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> ".docx"
            else -> ""
        }
        val rawName = displayName?.trim().orEmpty().ifEmpty {
            uri.lastPathSegment?.substringAfterLast('/')?.trim().orEmpty()
        }
        val fallbackName = rawName.ifEmpty { "外部文件" }
        val withExtension = if (
            File(fallbackName).extension.isEmpty() && inferredExtension.isNotEmpty()
        ) {
            "$fallbackName$inferredExtension"
        } else {
            fallbackName
        }
        val sanitizedName = withExtension.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_")
        val safeExtension = File(sanitizedName).extension.take(12)
        val safeBaseName = File(sanitizedName).nameWithoutExtension
            .take(if (safeExtension.isEmpty()) 160 else 147)
            .ifEmpty { "外部文件" }
        val safeName = if (safeExtension.isEmpty()) {
            safeBaseName
        } else {
            "$safeBaseName.$safeExtension"
        }
        BookImportProbe.rejectAndroidPackage(
            context = activity,
            uri = uri,
            extraNames = listOf(
                fallbackName,
                sanitizedName,
                safeName,
                uri.lastPathSegment.orEmpty(),
            ),
            extraMimes = listOf(mimeType, resolverType),
        )
        val target = File(
            incomingDirectory,
            "${System.currentTimeMillis()}_${safeName.ifEmpty { "外部文件" }}",
        )
        val input = when (uri.scheme) {
            "file" -> FileInputStream(File(requireNotNull(uri.path)))
            else -> resolver.openInputStream(uri)
        } ?: error("系统未授予外部文件读取权限")
        var copiedBytes = 0L
        try {
            input.use { source ->
                FileOutputStream(target).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        copiedBytes += count
                        if (copiedBytes > 1024L * 1024L * 1024L) {
                            error("外部文件超过 1 GB，无法导入")
                        }
                        output.write(buffer, 0, count)
                    }
                    output.flush()
                }
            }
            require(copiedBytes > 0) { "外部文件为空" }
            var finalTarget = target
            var finalName = safeName
            if (File(safeName).extension.isEmpty()) {
                val sniffed = sniffImportedExtension(target)
                if (sniffed.isNotEmpty()) {
                    val renamed = File(target.parentFile, "${target.name}.$sniffed")
                    if (target.renameTo(renamed)) {
                        finalTarget = renamed
                        finalName = "$safeName.$sniffed"
                    }
                }
            }
            return mapOf(
                "path" to finalTarget.absolutePath,
                "name" to finalName,
                "mimeType" to mimeType,
            )
        } catch (error: Throwable) {
            target.delete()
            throw error
        }
    }

    private fun sniffImportedExtension(file: File): String {
        FileInputStream(file).use { input ->
            val header = ByteArray(68)
            val count = input.read(header)
            if (count >= 4 &&
                header[0] == 0x25.toByte() &&
                header[1] == 0x50.toByte() &&
                header[2] == 0x44.toByte() &&
                header[3] == 0x46.toByte()
            ) {
                return "pdf"
            }
            if (count >= 4 &&
                header[0] == 0xD0.toByte() &&
                header[1] == 0xCF.toByte() &&
                header[2] == 0x11.toByte() &&
                header[3] == 0xE0.toByte()
            ) {
                return "doc"
            }
            if (count >= 68 &&
                header[60] == 0x42.toByte() &&
                header[61] == 0x4F.toByte() &&
                header[62] == 0x4F.toByte() &&
                header[63] == 0x4B.toByte() &&
                header[64] == 0x4D.toByte() &&
                header[65] == 0x4F.toByte() &&
                header[66] == 0x42.toByte() &&
                header[67] == 0x49.toByte()
            ) {
                return "mobi"
            }
        }
        return ""
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }
}
