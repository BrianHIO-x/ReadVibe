package com.readvibe.app

import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem
import com.tom_roush.pdfbox.text.PDFTextStripper
import org.apache.poi.hwpf.HWPFDocument
import org.apache.poi.hwpf.extractor.WordExtractor
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.Closeable
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.LinkedHashMap
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val TEXT_ACTION_CHANNEL = "com.readvibe.app/system_text_actions"
        private const val DOCUMENT_PARSER_CHANNEL = "com.readvibe.app/document_parser"
        private const val PDF_RENDERER_CHANNEL = "com.readvibe.app/pdf_renderer"
        private const val APP_UPDATE_CHANNEL = "com.readvibe.app/app_update"
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

    private val documentExecutor = Executors.newSingleThreadExecutor()
    private val pdfExecutor = Executors.newSingleThreadExecutor()
    private val pdfAnalysisExecutor = Executors.newSingleThreadExecutor()
    private val incomingFileExecutor = Executors.newSingleThreadExecutor()
    private var pdfSession: PdfSession? = null
    private var pdfTextSession: PdfTextSession? = null
    private val incomingFileIntents = ArrayDeque<Intent>()
    private var incomingFileChannel: MethodChannel? = null
    private val pdfTextLock = Any()

    private class PdfSession(
        val sourcePath: String,
        val cacheKey: String,
        val descriptor: ParcelFileDescriptor,
        val renderer: PdfRenderer,
    ) : Closeable {
        override fun close() {
            renderer.close()
            descriptor.close()
        }
    }

    private class PdfTextSession(
        val sourcePath: String,
        val cacheKey: String,
        val document: PDDocument,
    ) : Closeable {
        private val pageTexts = LinkedHashMap<Int, String>(16, 0.75f, true)
        private var cachedCharacters = 0

        fun pageText(pageIndex: Int): String {
            pageTexts[pageIndex]?.let { return it }
            val stripper = PDFTextStripper().apply {
                startPage = pageIndex + 1
                endPage = pageIndex + 1
                sortByPosition = true
            }
            val text = stripper.getText(document).orEmpty()
            if (text.length <= 2 * 1024 * 1024) {
                while (cachedCharacters + text.length > 16 * 1024 * 1024 && pageTexts.isNotEmpty()) {
                    val oldest = pageTexts.entries.iterator().next()
                    cachedCharacters -= oldest.value.length
                    pageTexts.remove(oldest.key)
                }
                pageTexts[pageIndex] = text
                cachedCharacters += text.length
            }
            return text
        }

        override fun close() {
            pageTexts.clear()
            cachedCharacters = 0
            document.close()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PDFBoxResourceLoader.init(applicationContext)
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
                    val content = extractLegacyDoc(filePath)
                    runOnUiThread { result.success(content) }
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PDF_RENDERER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method !in setOf(
                    "getPageCount",
                    "renderPage",
                    "clearFileCache",
                    "searchText",
                    "getOutline",
                )
            ) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val filePath = call.argument<String>("filePath")
            if (filePath.isNullOrBlank()) {
                result.error("PDF_PATH_INVALID", "PDF 文件路径无效", null)
                return@setMethodCallHandler
            }
            val task = Runnable {
                try {
                    when (call.method) {
                        "getPageCount" -> {
                            val pageCount = getPdfPageCount(filePath)
                            runOnUiThread { result.success(pageCount) }
                        }

                        "renderPage" -> {
                            val pageIndex = call.argument<Int>("pageIndex") ?: -1
                            val widthPx = call.argument<Int>("widthPx") ?: 1440
                            val rendered = renderPdfPage(filePath, pageIndex, widthPx)
                            runOnUiThread { result.success(rendered) }
                        }

                        "clearFileCache" -> {
                            clearPdfCache(filePath)
                            closePdfTextSession(filePath)
                            runOnUiThread { result.success(null) }
                        }

                        "searchText" -> {
                            val query = call.argument<String>("query").orEmpty()
                            runOnUiThread { result.success(searchPdfText(filePath, query)) }
                        }

                        "getOutline" -> {
                            runOnUiThread { result.success(getPdfOutline(filePath)) }
                        }
                    }
                } catch (error: Throwable) {
                    runOnUiThread {
                        result.error(
                            "PDF_RENDER_FAILED",
                            error.message ?: "PDF 已损坏、加密或不受支持",
                            null,
                        )
                    }
                }
            }
            if (call.method == "searchText" || call.method == "getOutline") {
                pdfAnalysisExecutor.execute(task)
            } else {
                pdfExecutor.execute(task)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_UPDATE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "openExternalUrl" -> {
                        val rawUrl = call.argument<String>("url")
                        val uri = rawUrl?.let(Uri::parse)
                        if (uri == null || uri.scheme !in setOf("https", "http")) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(Intent.ACTION_VIEW, uri)
                        if (intent.resolveActivity(packageManager) == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        startActivity(intent)
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("APP_UPDATE_FAILED", error.message, null)
            }
        }

    }

    private fun extractLegacyDoc(filePath: String): String {
        val source = File(filePath)
        require(source.isFile && source.length() > 0) { "DOC 文件为空或无法读取" }
        FileInputStream(source).use { input ->
            HWPFDocument(input).use { document ->
                WordExtractor(document).use { extractor ->
                    return extractor.text.orEmpty()
                }
            }
        }
    }

    private fun getPdfPageCount(filePath: String): Int {
        val source = File(filePath)
        require(source.isFile && source.length() > 0) { "PDF 文件为空或无法读取" }
        val session = getPdfSession(source)
        require(session.renderer.pageCount > 0) { "PDF 不包含可显示页面" }
        return session.renderer.pageCount
    }

    private fun renderPdfPage(filePath: String, pageIndex: Int, requestedWidth: Int): String {
        val source = File(filePath)
        require(source.isFile && source.length() > 0) { "PDF 文件为空或无法读取" }
        val widthPx = requestedWidth.coerceIn(480, 4096)
        val cacheRoot = File(cacheDir, "readvibe_pdf_pages")
        if (!cacheRoot.exists()) cacheRoot.mkdirs()
        val session = getPdfSession(source)
        val cacheKey = session.cacheKey
        val cacheDirectory = File(cacheRoot, cacheKey)
        if (!cacheDirectory.exists()) cacheDirectory.mkdirs()
        val target = File(cacheDirectory, "${pageIndex}_$widthPx.png")
        if (target.isFile && target.length() > 0) return target.absolutePath

        val renderer = session.renderer
        require(pageIndex in 0 until renderer.pageCount) { "PDF 页码超出范围" }
        renderer.openPage(pageIndex).use { page ->
            val scale = widthPx.toFloat() / page.width.toFloat()
            val heightPx = (page.height * scale).toInt().coerceIn(1, 8192)
            val bitmap = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val temporary = File(cacheDirectory, "${pageIndex}_$widthPx.tmp")
                if (temporary.exists()) temporary.delete()
                FileOutputStream(temporary).use { output ->
                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                        "PDF 页面图像写入失败"
                    }
                    output.flush()
                }
                if (target.exists()) target.delete()
                check(temporary.renameTo(target)) { "PDF 页面缓存替换失败" }
            } finally {
                bitmap.recycle()
            }
        }
        return target.absolutePath
    }

    private data class NormalizedPdfText(
        val text: String,
        val sourceStarts: List<Int>,
        val sourceEnds: List<Int>,
    )

    private fun normalizePdfText(source: String): NormalizedPdfText {
        val text = StringBuilder()
        val starts = ArrayList<Int>()
        val ends = ArrayList<Int>()
        var offset = 0
        var whitespaceStart = -1
        var whitespaceEnd = -1
        while (offset < source.length) {
            val codePoint = source.codePointAt(offset)
            val count = Character.charCount(codePoint)
            val end = offset + count
            val whitespace = Character.isWhitespace(codePoint) ||
                codePoint == 0x00a0 || codePoint == 0x3000 || codePoint == 0xfeff
            if (whitespace) {
                if (whitespaceStart < 0) whitespaceStart = offset
                whitespaceEnd = end
            } else {
                if (whitespaceStart >= 0 && text.isNotEmpty()) {
                    text.append(' ')
                    starts.add(whitespaceStart)
                    ends.add(whitespaceEnd)
                }
                whitespaceStart = -1
                val lowered = String(Character.toChars(codePoint)).lowercase(Locale.ROOT)
                text.append(lowered)
                repeat(lowered.length) {
                    starts.add(offset)
                    ends.add(end)
                }
            }
            offset = end
        }
        return NormalizedPdfText(text.toString(), starts, ends)
    }

    private fun searchPdfText(filePath: String, rawQuery: String): List<Map<String, Any>> {
        val query = normalizePdfText(rawQuery).text
        if (query.isEmpty()) return emptyList()
        return synchronized(pdfTextLock) {
            val session = getPdfTextSession(File(filePath))
            val results = mutableListOf<Map<String, Any>>()
            for (pageIndex in 0 until session.document.numberOfPages) {
                val source = session.pageText(pageIndex)
                if (source.isEmpty()) continue
                val normalized = normalizePdfText(source)
                var match = normalized.text.indexOf(query)
                while (match >= 0 && results.size < 500) {
                    val normalizedEnd = match + query.length - 1
                    if (match >= normalized.sourceStarts.size || normalizedEnd >= normalized.sourceEnds.size) {
                        break
                    }
                    val sourceStart = normalized.sourceStarts[match]
                    val sourceEnd = normalized.sourceEnds[normalizedEnd]
                    var snippetStart = (sourceStart - 36).coerceAtLeast(0)
                    var snippetEnd = (sourceEnd + 56).coerceAtMost(source.length)
                    if (snippetStart > 0 && Character.isLowSurrogate(source[snippetStart])) {
                        snippetStart--
                    }
                    if (snippetEnd < source.length &&
                        snippetEnd > 0 &&
                        Character.isHighSurrogate(source[snippetEnd - 1])
                    ) {
                        snippetEnd++
                    }
                    val leadingEllipsis = snippetStart > 0
                    val trailingEllipsis = snippetEnd < source.length
                    val snippet = buildString {
                        if (leadingEllipsis) append('…')
                        append(source.substring(snippetStart, snippetEnd))
                        if (trailingEllipsis) append('…')
                    }
                    val snippetMatchStart =
                        (if (leadingEllipsis) 1 else 0) + sourceStart - snippetStart
                    results.add(
                        mapOf(
                            "pageIndex" to pageIndex,
                            "snippet" to snippet,
                            "matchedText" to source.substring(sourceStart, sourceEnd),
                            "snippetMatchStart" to snippetMatchStart,
                            "snippetMatchEnd" to snippetMatchStart + sourceEnd - sourceStart,
                        ),
                    )
                    match = normalized.text.indexOf(query, match + query.length)
                }
                if (results.size >= 500) break
            }
            results
        }
    }

    private fun getPdfOutline(filePath: String): List<Map<String, Any>> {
        return synchronized(pdfTextLock) {
            val session = getPdfTextSession(File(filePath))
            val outline = session.document.documentCatalog.documentOutline ?: return@synchronized emptyList()
            val results = mutableListOf<Map<String, Any>>()

            fun appendItems(first: PDOutlineItem?, depth: Int) {
                var item = first
                while (item != null && results.size < 5000) {
                    val page = runCatching { item.findDestinationPage(session.document) }.getOrNull()
                    val pageIndex = page?.let { session.document.pages.indexOf(it) } ?: -1
                    val title = item.title?.trim().orEmpty()
                    if (title.isNotEmpty() && pageIndex >= 0) {
                        results.add(
                            mapOf(
                                "title" to title,
                                "pageIndex" to pageIndex,
                                "depth" to depth.coerceIn(0, 12),
                            ),
                        )
                    }
                    appendItems(item.firstChild, depth + 1)
                    item = item.nextSibling
                }
            }
            appendItems(outline.firstChild, 0)
            results
        }
    }

    private fun clearPdfCache(filePath: String) {
        val source = File(filePath)
        val cacheRoot = File(cacheDir, "readvibe_pdf_pages")
        val sourcePath = runCatching { source.canonicalPath }.getOrDefault(source.absolutePath)
        val keys = linkedSetOf<String>()
        val active = pdfSession
        if (active?.sourcePath == sourcePath) {
            keys.add(active.cacheKey)
            closePdfSession()
        }
        if (source.isFile && source.length() > 0) keys.add(pdfCacheKey(source))
        for (key in keys) {
            val cacheDirectory = File(cacheRoot, key)
            if (cacheDirectory.isDirectory) cacheDirectory.deleteRecursively()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        enqueueIncomingFile(intent, notifyFlutter = true)
    }

    private fun enqueueIncomingFile(intent: Intent?, notifyFlutter: Boolean) {
        if (intent?.action != Intent.ACTION_VIEW || intent.data == null) return
        synchronized(incomingFileIntents) {
            while (incomingFileIntents.size >= 8) incomingFileIntents.removeFirst()
            incomingFileIntents.addLast(Intent(intent))
        }
        if (notifyFlutter) incomingFileChannel?.invokeMethod("available", null)
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
            "application/pdf" -> ".pdf"
            "application/msword" -> ".doc"
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
            return mapOf(
                "path" to target.absolutePath,
                "name" to safeName,
                "mimeType" to mimeType,
            )
        } catch (error: Throwable) {
            target.delete()
            throw error
        }
    }

    private fun getPdfSession(source: File): PdfSession {
        val sourcePath = source.canonicalPath
        val cacheKey = pdfCacheKey(source)
        val active = pdfSession
        if (active != null && active.sourcePath == sourcePath && active.cacheKey == cacheKey) {
            return active
        }
        closePdfSession()
        val descriptor = ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
        try {
            val renderer = PdfRenderer(descriptor)
            return PdfSession(sourcePath, cacheKey, descriptor, renderer).also {
                pdfSession = it
            }
        } catch (error: Throwable) {
            descriptor.close()
            throw error
        }
    }

    private fun getPdfTextSession(source: File): PdfTextSession {
        require(source.isFile && source.length() > 0) { "PDF 文件为空或无法读取" }
        val sourcePath = source.canonicalPath
        val cacheKey = pdfCacheKey(source)
        val active = pdfTextSession
        if (active != null && active.sourcePath == sourcePath && active.cacheKey == cacheKey) {
            return active
        }
        closePdfTextSession()
        val document = PDDocument.load(source)
        return PdfTextSession(sourcePath, cacheKey, document).also {
            pdfTextSession = it
        }
    }

    private fun closePdfSession() {
        val active = pdfSession ?: return
        pdfSession = null
        runCatching { active.close() }
    }

    private fun closePdfTextSession(filePath: String? = null) {
        synchronized(pdfTextLock) {
            val active = pdfTextSession ?: return
            if (filePath != null) {
                val requested = runCatching { File(filePath).canonicalPath }
                    .getOrDefault(File(filePath).absolutePath)
                if (active.sourcePath != requested) return
            }
            pdfTextSession = null
            runCatching { active.close() }
        }
    }

    private fun pdfCacheKey(source: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(source.canonicalPath.toByteArray(Charsets.UTF_8))
        digest.update(":${source.length()}:${source.lastModified()}:".toByteArray(Charsets.UTF_8))
        RandomAccessFile(source, "r").use { input ->
            val sampleSize = 64 * 1024
            val buffer = ByteArray(sampleSize)
            val firstCount = input.read(buffer)
            if (firstCount > 0) digest.update(buffer, 0, firstCount)
            if (input.length() > sampleSize) {
                input.seek((input.length() - sampleSize).coerceAtLeast(0))
                val lastCount = input.read(buffer)
                if (lastCount > 0) digest.update(buffer, 0, lastCount)
            }
        }
        return digest.digest().joinToString("") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
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

    override fun onDestroy() {
        documentExecutor.shutdownNow()
        pdfExecutor.execute { closePdfSession() }
        pdfExecutor.shutdown()
        pdfAnalysisExecutor.execute { closePdfTextSession() }
        pdfAnalysisExecutor.shutdown()
        incomingFileExecutor.shutdownNow()
        incomingFileChannel = null
        super.onDestroy()
    }
}
