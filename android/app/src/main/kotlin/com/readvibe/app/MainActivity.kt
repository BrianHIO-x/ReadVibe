package com.readvibe.app

import android.app.Activity
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
import android.os.Handler
import android.os.Looper
import java.util.ArrayDeque
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class MainActivity : FlutterActivity() {
    companion object {
        private const val TEXT_ACTION_CHANNEL = "com.readvibe.app/system_text_actions"
        private const val DOCUMENT_PARSER_CHANNEL = "com.readvibe.app/document_parser"
        private const val INCOMING_FILE_CHANNEL = "com.readvibe.app/incoming_file"
        private const val BOOK_PICKER_CHANNEL = "com.readvibe.app/book_picker"
        private const val PICK_BOOK_REQUEST = 0x5242

        // A document provider may serve a file over the network, where a read
        // can block with no bytes arriving. The copy is abandoned only after
        // it stops making progress, so a slow but advancing transfer finishes.
        // A result and the return to the foreground arrive together, and the
        // order is not guaranteed. Waiting this long before treating a
        // request as abandoned lets a result that lands second still win.
        private const val ABANDONED_PICK_GRACE_MS = 1_500L
        private const val COPY_STALL_MS = 45_000L
        private const val COPY_STALL_CHECK_MS = 5_000L
        private const val COPY_STALL_MESSAGE =
            "读取所选文件长时间没有进展，请把文件保存到本机后重试"
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
    // The picker copies on its own threads. A pool rather than a single thread
    // because a read that blocks inside a document provider may ignore an
    // interrupt, and one abandoned copy must not hold up every later
    // selection. Sharing the incoming-file executor would have the same fault.
    private val pickedBookExecutor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val incomingFileIntents = ArrayDeque<Intent>()
    private var incomingFileChannel: MethodChannel? = null
    private var pickBookResult: MethodChannel.Result? = null
    private var pickerTookForeground = false


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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BOOK_PICKER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "pick") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (pickBookResult != null) {
                result.error("already_active", "文件选择器已打开，请完成当前选择", null)
                return@setMethodCallHandler
            }
            pickBookResult = result
            pickerTookForeground = false
            try {
                @Suppress("DEPRECATION")
                startActivityForResult(
                    Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    },
                    PICK_BOOK_REQUEST,
                )
            } catch (error: Exception) {
                pickBookResult = null
                result.error("invalid_format_type", "无法打开系统文件选择器", null)
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

    override fun onPause() {
        if (pickBookResult != null) pickerTookForeground = true
        super.onPause()
    }

    /**
     * Answers a selection the system never delivered.
     *
     * A picker that closes normally clears the request through
     * onActivityResult, which can land either side of this callback. Checking
     * again after a short grace period therefore only ever finds a request the
     * system abandoned, and answering it keeps the shelf from waiting on a
     * result that is not coming, and keeps the next selection from being
     * refused as one already in progress.
     */
    override fun onResume() {
        super.onResume()
        if (!pickerTookForeground) return
        pickerTookForeground = false
        mainHandler.postDelayed({
            val abandoned = pickBookResult ?: return@postDelayed
            pickBookResult = null
            abandoned.success(null)
        }, ABANDONED_PICK_GRACE_MS)
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
        val resolverType = if (uri.scheme == "content") {
            contentResolver.getType(uri).orEmpty()
        } else {
            ""
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
        BookImportProbe.rejectAndroidPackage(
            context = this,
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

    private fun onBookPicked(uri: Uri?) {
        val pending = pickBookResult ?: return
        pickBookResult = null
        if (uri == null) {
            pending.success(null)
            return
        }
        val answered = AtomicBoolean(false)
        val lastProgress = AtomicLong(System.currentTimeMillis())
        watchCopyProgress(answered, lastProgress, pending)
        pickedBookExecutor.execute {
            try {
                val copied = BookImportProbe.copyPickedBook(this, uri) {
                    lastProgress.set(System.currentTimeMillis())
                }
                if (answered.compareAndSet(false, true)) {
                    runOnUiThread { pending.success(copied) }
                }
            } catch (error: Throwable) {
                val message = error.message ?: "无法读取所选文件"
                val code = when (message) {
                    BookImportProbe.ANDROID_PACKAGE_MESSAGE -> "android_package"
                    BookImportProbe.UNSUPPORTED_MESSAGE -> "unsupported"
                    else -> "read_failed"
                }
                if (answered.compareAndSet(false, true)) {
                    runOnUiThread { pending.error(code, message, null) }
                }
            }
        }
    }

    /**
     * Fails a copy that has stopped moving.
     *
     * Reading from a document provider can block with no bytes arriving and no
     * error, which would leave the shelf waiting on a selection forever. Only
     * a stall ends the copy, so a large file arriving slowly still completes.
     */
    private fun watchCopyProgress(
        answered: AtomicBoolean,
        lastProgress: AtomicLong,
        pending: MethodChannel.Result,
    ) {
        mainHandler.postDelayed(
            object : Runnable {
                override fun run() {
                    if (answered.get()) return
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
        if (requestCode == PICK_BOOK_REQUEST) {
            pickerTookForeground = false
            if (resultCode != Activity.RESULT_OK) {
                pickBookResult?.success(null)
                pickBookResult = null
                return
            }
            onBookPicked(data?.data)
            return
        }
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
        pickedBookExecutor.shutdownNow()
        mainHandler.removeCallbacksAndMessages(null)
        incomingFileChannel = null
        pickBookResult?.error("read_failed", "无法选择文件", null)
        pickBookResult = null
        super.onDestroy()
    }
}
