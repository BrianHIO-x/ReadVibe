package com.readvibe.app

import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.apache.poi.hwpf.HWPFDocument
import org.apache.poi.hwpf.extractor.WordExtractor
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val TEXT_ACTION_CHANNEL = "com.readvibe.app/system_text_actions"
        private const val DOCUMENT_PARSER_CHANNEL = "com.readvibe.app/document_parser"
        private const val PDF_RENDERER_CHANNEL = "com.readvibe.app/pdf_renderer"
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
            if (call.method !in setOf("getPageCount", "renderPage", "clearFileCache")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val filePath = call.argument<String>("filePath")
            if (filePath.isNullOrBlank()) {
                result.error("PDF_PATH_INVALID", "PDF 文件路径无效", null)
                return@setMethodCallHandler
            }
            documentExecutor.execute {
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
                            runOnUiThread { result.success(null) }
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
        ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                require(renderer.pageCount > 0) { "PDF 不包含可显示页面" }
                return renderer.pageCount
            }
        }
    }

    private fun renderPdfPage(filePath: String, pageIndex: Int, requestedWidth: Int): String {
        val source = File(filePath)
        require(source.isFile && source.length() > 0) { "PDF 文件为空或无法读取" }
        val widthPx = requestedWidth.coerceIn(480, 4096)
        val cacheRoot = File(cacheDir, "readvibe_pdf_pages")
        if (!cacheRoot.exists()) cacheRoot.mkdirs()
        val cacheKey = pdfCacheKey(source)
        val cacheDirectory = File(cacheRoot, cacheKey)
        if (!cacheDirectory.exists()) cacheDirectory.mkdirs()
        val target = File(cacheDirectory, "${pageIndex}_$widthPx.png")
        if (target.isFile && target.length() > 0) return target.absolutePath

        ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                require(pageIndex in 0 until renderer.pageCount) { "PDF 页码超出范围" }
                renderer.openPage(pageIndex).use { page ->
                    val scale = widthPx.toFloat() / page.width.toFloat()
                    val heightPx = (page.height * scale).toInt().coerceIn(1, 8192)
                    val bitmap = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        val temporary = File(cacheDirectory, "${pageIndex}_$widthPx.tmp")
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
            }
        }
        return target.absolutePath
    }

    private fun clearPdfCache(filePath: String) {
        val source = File(filePath)
        val cacheRoot = File(cacheDir, "readvibe_pdf_pages")
        val cacheDirectory = File(cacheRoot, pdfCacheKey(source))
        if (cacheDirectory.isDirectory) cacheDirectory.deleteRecursively()
    }

    private fun pdfCacheKey(source: File): String {
        return "${source.nameWithoutExtension}_${source.length()}_${source.lastModified()}"
            .replace(Regex("[^A-Za-z0-9_.-]"), "_")
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
        super.onDestroy()
    }
}
