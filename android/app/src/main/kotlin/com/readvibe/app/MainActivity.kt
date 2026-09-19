package com.readvibe.app

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.apache.poi.hwpf.HWPFDocument
import org.apache.poi.hwpf.extractor.WordExtractor
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.ArrayDeque
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val TEXT_ACTION_CHANNEL = "com.readvibe.app/system_text_actions"
        private const val DOCUMENT_PARSER_CHANNEL = "com.readvibe.app/document_parser"
        private const val INCOMING_FILE_CHANNEL = "com.readvibe.app/incoming_file"
        private const val ACTION_TRANSLATE = "android.intent.action.TRANSLATE"
        private val AI_PACKAGE_ALLOWLIST = setOf(
            "com.deepseek.chat",
            "com.openai.chatgpt",
            "com.google.android.apps.bard",
            "com.anthropic.claude",
            "com.microsoft.copilot",
            "ai.perplexity.app.android",
        )
        private val BROWSER_PACKAGE_ALLOWLIST = setOf(
            "com.microsoft.emmx",
            "com.android.chrome",
        )
    }

    private var bookExporter: BookExportHandler? = null
    private var pdfHandler: PdfChannelHandler? = null
    private var updateHandler: AppUpdateHandler? = null

    private val documentExecutor = Executors.newSingleThreadExecutor()
    private val incomingFileExecutor = Executors.newSingleThreadExecutor()
    private val incomingFileIntents = ArrayDeque<Intent>()
    private var incomingFileChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bookExporter = BookExportHandler(this, flutterEngine.dartExecutor.binaryMessenger)
        pdfHandler = PdfChannelHandler(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        updateHandler = AppUpdateHandler(this, flutterEngine.dartExecutor.binaryMessenger)
        incomingFileChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INCOMING_FILE_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "consumeNext") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val incoming = synchronized(incomingFileIntents) {
                    if (incomingFileIntents.isEmpty()) null else incomingFileIntents.removeFirst()
                }
                if (incoming == null) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                incomingFileExecutor.execute {
                    try {
                        val copied = copyIncomingFile(incoming)
                        runOnUiThread { result.success(copied) }
                    } catch (error: Throwable) {
                        runOnUiThread {
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
        enqueueIncomingFile(intent, notifyFlutter = false)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TEXT_ACTION_CHANNEL,
        ).setMethodCallHandler { call, result ->
            try {
                val arguments = call.arguments as? Map<*, *>
                when (call.method) {
                    "getTargets" -> {
                        val action = arguments?.get("action") as? String
                        result.success(querySystemTextTargets(action))
                    }

                    "launch" -> {
                        val action = arguments?.get("action") as? String
                        val targetId = arguments?.get("targetId") as? String
                        val packageName = arguments?.get("packageName") as? String
                        val componentName = arguments?.get("componentName") as? String
                        val intentKind = arguments?.get("intentKind") as? String
                        val text = (arguments?.get("text") as? String)?.trim().orEmpty()
                        if (action.isNullOrBlank() || targetId.isNullOrBlank() || text.isEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(
                            launchSystemTextTarget(
                                action = action,
                                targetId = targetId,
                                packageName = packageName.orEmpty(),
                                componentName = componentName.orEmpty(),
                                intentKind = intentKind.orEmpty(),
                                text = text,
                            ),
                        )
                    }

                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
            } catch (error: Exception) {
                result.error("SYSTEM_TEXT_ACTION_FAILED", error.message, null)
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOCUMENT_PARSER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "extractLegacyDoc") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val filePath = call.argument<String>("filePath")
            if (filePath.isNullOrBlank()) {
                result.error("DOC_PATH_INVALID", "DOC 文件路径无效", null)
                return@setMethodCallHandler
            }

            documentExecutor.execute {
                try {
                    val document = extractLegacyDoc(filePath)
                    runOnUiThread { result.success(document) }
                } catch (error: Throwable) {
                    runOnUiThread {
                        result.error(
                            "DOC_PARSE_FAILED",
                            error.message ?: "DOC 文档已损坏、加密或不受支持",
                            null,
                        )
                    }
                }
            }
        }

    }

    private fun extractLegacyDoc(filePath: String): Map<String, String> {
        val source = File(filePath)
        require(source.isFile && source.length() > 0) { "DOC 文件为空或无法读取" }
        FileInputStream(source).use { input ->
            HWPFDocument(input).use { document ->
                WordExtractor(document).use { extractor ->
                    val summary = document.summaryInformation
                    return mapOf(
                        "content" to extractor.text.orEmpty(),
                        "title" to summary?.title.orEmpty().trim(),
                        "author" to summary?.author.orEmpty().trim(),
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        enqueueIncomingFile(intent, notifyFlutter = true)
    }

    private fun enqueueIncomingFile(intent: Intent?, notifyFlutter: Boolean) {
        val uri = incomingFileUri(intent) ?: return
        val queued = Intent(intent).apply { data = uri }
        synchronized(incomingFileIntents) {
            while (incomingFileIntents.size >= 8) incomingFileIntents.removeFirst()
            incomingFileIntents.addLast(queued)
        }
        if (notifyFlutter) incomingFileChannel?.invokeMethod("available", null)
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
        val incomingDirectory = File(cacheDir, "readvibe_incoming")
        if (!incomingDirectory.exists()) incomingDirectory.mkdirs()
        val staleBefore = System.currentTimeMillis() - 24L * 60L * 60L * 1000L
        incomingDirectory.listFiles()?.forEach { file ->
            if (file.lastModified() < staleBefore) file.delete()
        }

        var displayName: String? = null
        if (uri.scheme == "content") {
            contentResolver.query(
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
        val sanitizedName = withExtension
            .replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_")
        val safeExtension = File(sanitizedName).extension.take(12)
        val safeBaseName = File(sanitizedName).nameWithoutExtension
            .take(if (safeExtension.isEmpty()) 160 else 147)
            .ifEmpty { "外部文件" }
        val safeName = if (safeExtension.isEmpty()) {
            safeBaseName
        } else {
            "$safeBaseName.$safeExtension"
        }
        val target = File(
            incomingDirectory,
            "${System.currentTimeMillis()}_${safeName.ifEmpty { "外部文件" }}",
        )
        val input = when (uri.scheme) {
            "file" -> FileInputStream(File(requireNotNull(uri.path)))
            else -> contentResolver.openInputStream(uri)
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

    private fun querySystemTextTargets(action: String?): List<Map<String, Any>> {
        val queryIntents = when (action) {
            "translate" -> listOf(
                "send" to buildSendIntent("翻译测试"),
                "processText" to buildProcessTextIntent("翻译测试"),
                "translate" to buildTranslateIntent("翻译测试"),
            )

            "search" -> listOf("view" to buildSearchIntent("测试"))
            else -> emptyList()
        }
        val targets = linkedMapOf<String, Map<String, Any>>()
        for ((intentKind, intent) in queryIntents) {
            @Suppress("DEPRECATION")
            val resolved = packageManager.queryIntentActivities(intent, 0)
            for (info in resolved) {
                val activity = info.activityInfo ?: continue
                val packageName = activity.packageName.orEmpty()
                val componentName = activity.name.orEmpty()
                if (packageName.isEmpty() || componentName.isEmpty()) continue
                val key = packageName
                targets.putIfAbsent(
                    key,
                    mapOf(
                        "id" to key,
                        "label" to info.loadLabel(packageManager).toString(),
                        "packageName" to packageName,
                        "componentName" to componentName,
                        "intentKind" to intentKind,
                        "available" to true,
                    ),
                )
            }
        }
        return targets.values.toList()
    }

    private fun launchSystemTextTarget(
        action: String,
        targetId: String,
        packageName: String,
        componentName: String,
        intentKind: String,
        text: String,
    ): Boolean {
        val intent = when (action) {
            "translate" -> {
                if (packageName !in AI_PACKAGE_ALLOWLIST || componentName.isBlank()) return false
                val prompt = "翻译如下内容：“$text”"
                val targetIntent = when (intentKind) {
                    "processText" -> buildProcessTextIntent(prompt)
                    "send" -> buildSendIntent(prompt)
                    "translate" -> buildTranslateIntent(prompt)
                    else -> return false
                }
                targetIntent.component = ComponentName(packageName, componentName)
                targetIntent
            }

            "search" -> {
                if (targetId == "system") {
                    buildSearchIntent(text)
                } else {
                    if (packageName !in BROWSER_PACKAGE_ALLOWLIST || componentName.isBlank()) {
                        return false
                    }
                    buildSearchIntent(text).apply {
                        component = ComponentName(packageName, componentName)
                    }
                }
            }

            else -> return false
        }
        if (intent.resolveActivity(packageManager) == null) return false
        startActivity(intent)
        return true
    }

    private fun buildSendIntent(prompt: String): Intent {
        return Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, prompt)
        }
    }

    private fun buildProcessTextIntent(prompt: String): Intent {
        return Intent(Intent.ACTION_PROCESS_TEXT).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_PROCESS_TEXT, prompt)
            putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
            putExtra(Intent.EXTRA_TEXT, prompt)
        }
    }

    private fun buildTranslateIntent(prompt: String): Intent {
        return Intent(ACTION_TRANSLATE).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, prompt)
            putExtra(Intent.EXTRA_PROCESS_TEXT, prompt)
            putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
        }
    }

    private fun buildSearchIntent(text: String): Intent {
        return Intent(
            Intent.ACTION_VIEW,
            Uri.parse("https://www.google.com/search?q=${Uri.encode(text)}"),
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (bookExporter?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        updateHandler?.dispose()
        updateHandler = null
        bookExporter?.dispose()
        bookExporter = null
        documentExecutor.shutdownNow()
        pdfHandler?.dispose()
        pdfHandler = null
        incomingFileExecutor.shutdownNow()
        incomingFileChannel = null
        super.onDestroy()
    }
}
