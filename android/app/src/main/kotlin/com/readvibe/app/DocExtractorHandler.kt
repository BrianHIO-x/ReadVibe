package com.readvibe.app

import android.app.Activity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.apache.poi.hwpf.HWPFDocument
import org.apache.poi.hwpf.extractor.WordExtractor
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors

/** Extracts text and metadata from legacy binary .doc files on a worker thread. */
class DocExtractorHandler(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.readvibe.app/document_parser")
    private val executor = Executors.newSingleThreadExecutor()
    @Volatile private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "extractLegacyDoc") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val filePath = call.argument<String>("filePath")
            if (filePath.isNullOrBlank()) {
                result.error("DOC_PATH_INVALID", "DOC 文件路径无效", null)
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val document = extractLegacyDoc(filePath)
                    if (!disposed) {
                        activity.runOnUiThread { result.success(document) }
                    }
                } catch (error: Throwable) {
                    if (!disposed) {
                        activity.runOnUiThread {
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

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }
}
