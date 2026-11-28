package com.readvibe.app

import android.app.Activity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.apache.poi.EncryptedDocumentException
import org.apache.poi.hwpf.HWPFDocument
import org.apache.poi.hwpf.HWPFOldDocument
import org.apache.poi.hwpf.OldWordFileFormatException
import org.apache.poi.hwpf.extractor.Word6Extractor
import org.apache.poi.hwpf.extractor.WordExtractor
import org.apache.poi.poifs.filesystem.NotOLE2FileException
import org.apache.poi.poifs.filesystem.OfficeXmlFileException
import org.apache.poi.poifs.filesystem.POIFSFileSystem
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.charset.Charset
import java.util.concurrent.Executors

private class DocIsDocxException : RuntimeException()

/** Extracts text and metadata from legacy .doc containers (and RTF/HTML/Word6 misnamed as .doc) on a worker thread. */
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
                } catch (_: DocIsDocxException) {
                    if (!disposed) {
                        activity.runOnUiThread {
                            result.error("DOC_IS_DOCX", "文档实际为 DOCX 格式", null)
                        }
                    }
                } catch (error: Throwable) {
                    if (!disposed) {
                        activity.runOnUiThread {
                            result.error(
                                "DOC_PARSE_FAILED",
                                friendlyDocError(error),
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

        val header = ByteArray(1024)
        val headerLen = FileInputStream(source).use { it.read(header) }
        if (headerLen <= 0) {
            throw IllegalArgumentException("DOC 文件为空或无法读取")
        }
        val probe = header.copyOf(headerLen)
        if (isZipSignature(probe)) {
            throw DocIsDocxException()
        }
        if (looksLikeRtf(probe)) {
            require(source.length() <= 64L * 1024L * 1024L) { "RTF 文档过大，无法解析" }
            val text = cleanExtractedText(extractRtfText(source.readBytes()))
            require(text.isNotBlank()) { "RTF 文档中没有可读取的正文" }
            return mapOf("content" to text, "title" to "", "author" to "")
        }
        if (looksLikeMarkupOrMhtml(probe)) {
            require(source.length() <= 64L * 1024L * 1024L) { "HTML/XML 文档过大，无法解析" }
            val text = cleanExtractedText(extractHtmlOrXmlText(source.readBytes()))
            require(text.isNotBlank()) { "文档中没有可读取的正文" }
            return mapOf("content" to text, "title" to "", "author" to "")
        }

        POIFSFileSystem(source, true).use { fs ->
            val root = fs.root
            if (root.hasEntry("EncryptionInfo") || root.hasEntry("EncryptedPackage")) {
                throw IllegalArgumentException("文档受密码加密保护，无法离线解析")
            }
            return try {
                HWPFDocument(fs).use { document ->
                    WordExtractor(document).use { extractor ->
                        val summary = document.summaryInformation
                        mapOf(
                            "content" to cleanExtractedText(extractor.text.orEmpty()),
                            "title" to summary?.title.orEmpty().trim(),
                            "author" to summary?.author.orEmpty().trim(),
                        )
                    }
                }
            } catch (_: OldWordFileFormatException) {
                HWPFOldDocument(fs).use { oldDoc ->
                    Word6Extractor(oldDoc).use { extractor ->
                        val summary = oldDoc.summaryInformation
                        mapOf(
                            "content" to cleanExtractedText(extractor.text.orEmpty()),
                            "title" to summary?.title.orEmpty().trim(),
                            "author" to summary?.author.orEmpty().trim(),
                        )
                    }
                }
            }
        }
    }

    private fun friendlyDocError(error: Throwable): String {
        val raw = error.message?.trim().orEmpty()
        if (raw.any { it.code >= 0x4E00 && it.code <= 0x9FFF }) {
            return raw
        }
        return when (error) {
            is EncryptedDocumentException -> "Word 文档受密码加密保护，无法离线解析"
            is OfficeXmlFileException -> "该文件为 DOCX XML 格式"
            is NotOLE2FileException -> "不是有效的二进制 Word (.doc) 文档"
            else -> {
                val lower = raw.lowercase()
                when {
                    lower.contains("encrypt") || lower.contains("password") ->
                        "Word 文档受密码加密保护，无法离线解析"
                    lower.contains("worddocument") || lower.contains("not found") ->
                        "文档结构不完整或受密码加密保护"
                    else -> "DOC 文档已损坏、加密或不受支持"
                }
            }
        }
    }

    private fun cleanExtractedText(text: String): String =
        text.replace("\u0000", "")
            .replace("\u0007", "\n")
            .replace("\u0001", "")
            .replace("\u0008", "")
            .replace("\u0013", "")
            .replace("\u0014", "")
            .replace("\u0015", "")

    private fun isZipSignature(bytes: ByteArray): Boolean =
        bytes.size >= 4 &&
            bytes[0] == 0x50.toByte() &&
            bytes[1] == 0x4B.toByte() &&
            ((bytes[2] == 0x03.toByte() && bytes[3] == 0x04.toByte()) ||
                (bytes[2] == 0x05.toByte() && bytes[3] == 0x06.toByte()) ||
                (bytes[2] == 0x07.toByte() && bytes[3] == 0x08.toByte()))

    private fun looksLikeRtf(bytes: ByteArray): Boolean {
        val head = String(bytes, Charsets.ISO_8859_1).trimStart('\uFEFF', ' ', '\t', '\r', '\n')
        return head.startsWith("{\\rtf")
    }

    private fun looksLikeMarkupOrMhtml(bytes: ByteArray): Boolean {
        val head = String(bytes, Charsets.UTF_8)
            .trimStart('\uFEFF', ' ', '\t', '\r', '\n')
            .lowercase()
        return head.startsWith("<!doctype html") ||
            head.startsWith("<html") ||
            head.startsWith("<w:worddocument") ||
            (head.startsWith("<?xml") &&
                (head.contains("worddocument") || head.contains("<html"))) ||
            (head.contains("mime-version:") && head.contains("text/html"))
    }

    private fun extractRtfText(bytes: ByteArray): String {
        val skippedDestinations = setOf(
            "fonttbl", "colortbl", "stylesheet", "info", "pict", "object",
            "fldinst", "header", "footer", "headerl", "headerr", "headerf",
            "footerl", "footerr", "footerf", "footnote", "datafield", "themedata",
            "colorschememapping", "latentstyles", "datastore", "xmlnstbl",
        )
        data class Frame(val uc: Int, val skip: Boolean)
        val stack = ArrayDeque<Frame>()
        var currentUc = 1
        var currentSkip = false
        var ansiCharset = Charset.forName("windows-1252")
        val out = StringBuilder()
        val hexBytes = ByteArrayOutputStream()

        fun flushHex() {
            if (hexBytes.size() > 0) {
                if (!currentSkip) {
                    out.append(String(hexBytes.toByteArray(), ansiCharset))
                }
                hexBytes.reset()
            }
        }

        var i = 0
        var skipFallbackChars = 0
        while (i < bytes.size) {
            val ch = bytes[i].toInt() and 0xff
            if (skipFallbackChars > 0 && ch != '\\'.code && ch != '{'.code && ch != '}'.code) {
                skipFallbackChars--
                if (ch != '\r'.code && ch != '\n'.code) {
                    i++
                    continue
                }
                i++
                continue
            }
            when (ch) {
                '{'.code -> {
                    flushHex()
                    stack.addLast(Frame(currentUc, currentSkip))
                    i++
                }
                '}'.code -> {
                    flushHex()
                    if (stack.isNotEmpty()) {
                        val prev = stack.removeLast()
                        currentUc = prev.uc
                        currentSkip = prev.skip
                    }
                    i++
                }
                '\\'.code -> {
                    i++
                    if (i >= bytes.size) break
                    val next = bytes[i].toInt() and 0xff
                    if (next == '\''.code && i + 2 < bytes.size) {
                        val h1 = Character.digit(bytes[i + 1].toInt().toChar(), 16)
                        val h2 = Character.digit(bytes[i + 2].toInt().toChar(), 16)
                        if (h1 >= 0 && h2 >= 0) {
                            if (!currentSkip) hexBytes.write((h1 shl 4) or h2)
                            i += 3
                            continue
                        }
                    }
                    flushHex()
                    if (next == '*'.code) {
                        currentSkip = true
                        i++
                        continue
                    }
                    if (!Character.isLetter(next)) {
                        if (!currentSkip) {
                            when (next) {
                                '\\'.code, '{'.code, '}'.code -> out.append(next.toChar())
                                '~'.code -> out.append('\u00a0')
                                '_'.code -> out.append('-')
                                '\r'.code, '\n'.code -> out.append('\n')
                            }
                        }
                        i++
                        continue
                    }
                    val wordStart = i
                    while (i < bytes.size && Character.isLetter(bytes[i].toInt() and 0xff)) {
                        i++
                    }
                    val word = String(bytes, wordStart, i - wordStart, Charsets.US_ASCII)
                    var param: Int? = null
                    var negative = false
                    if (i < bytes.size && bytes[i].toInt() == '-'.code) {
                        negative = true
                        i++
                    }
                    val numStart = i
                    while (i < bytes.size && Character.isDigit(bytes[i].toInt() and 0xff)) {
                        i++
                    }
                    if (i > numStart) {
                        val parsed = String(bytes, numStart, i - numStart, Charsets.US_ASCII).toIntOrNull()
                        if (parsed != null) param = if (negative) -parsed else parsed
                    }
                    if (i < bytes.size && bytes[i].toInt() == ' '.code) i++

                    if (word == "ansicpg" && param != null) {
                        ansiCharset = when (param) {
                            936, 54936 -> Charset.forName("GB18030")
                            950 -> Charset.forName("Big5")
                            else -> runCatching { Charset.forName("windows-$param") }
                                .getOrDefault(Charsets.UTF_8)
                        }
                    } else if (word in skippedDestinations) {
                        currentSkip = true
                    } else if (word == "uc" && param != null) {
                        currentUc = param.coerceIn(0, 8)
                    } else if (!currentSkip) {
                        when (word) {
                            "par", "line" -> out.append('\n')
                            "tab" -> out.append('\t')
                            "emdash" -> out.append('—')
                            "endash" -> out.append('–')
                            "lquote" -> out.append('‘')
                            "rquote" -> out.append('’')
                            "ldblquote" -> out.append('“')
                            "rdblquote" -> out.append('”')
                            "u" -> if (param != null) {
                                val codeUnit = if (param < 0) param + 65536 else param
                                out.append(codeUnit.toChar())
                                skipFallbackChars = currentUc
                            }
                        }
                    }
                }
                '\r'.code, '\n'.code -> i++
                else -> {
                    flushHex()
                    if (!currentSkip) out.append(ch.toChar())
                    i++
                }
            }
        }
        flushHex()
        return out.toString()
    }

    private fun extractHtmlOrXmlText(bytes: ByteArray): String {
        var raw = String(bytes, Charsets.UTF_8)
        val lower = raw.lowercase()
        if (lower.contains("mime-version:") && lower.contains("text/html")) {
            val htmlStart = lower.indexOf("<html")
            if (htmlStart >= 0) raw = raw.substring(htmlStart)
        }
        raw = raw
            .replace(Regex("(?is)<(head|style|script|xml)\\b[^>]*>.*?</\\1>"), "")
            .replace(Regex("(?i)<(?:br|/?(?:p|div|tr|li|h[1-6]|w:p))\\b[^>]*>"), "\n")
            .replace(Regex("<[^>]+>"), "")
            .replace("&nbsp;", " ")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&")
            .replace("&quot;", "\"")
        return raw.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString("\n")
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }
}
