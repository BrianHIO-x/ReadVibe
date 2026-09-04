package com.readvibe.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationText
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.LinkedHashMap
import java.util.Locale
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/** Owns document sessions and caches, with no Activity or Flutter channel dependency. */
internal class PdfDocumentEngine(context: Context) {
    private val cacheDir = context.applicationContext.cacheDir
    private val documents = ReentrantReadWriteLock(true)
    private val pdfTextLock = Any()
    private var pdfSession: PdfSession? = null
    private var pdfTextSession: PdfTextSession? = null
    private val recognizer = lazy {
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }
    private val pdfOcrRecognizer get() = recognizer.value

    init {
        PDFBoxResourceLoader.init(context.applicationContext)
    }

    fun execute(request: PdfRequest): Any? =
        if (request.operation.mutatesDocument) documents.write { perform(request) }
        else documents.read { perform(request) }

    private fun perform(request: PdfRequest): Any? = with(request) {
        when (operation) {
            PdfOperation.PAGE_COUNT -> getPdfPageCount(filePath)
            PdfOperation.RENDER -> renderPdfPage(filePath, pageIndex, widthPx)
            PdfOperation.CLEAR_CACHE -> {
                clearPdfCache(filePath)
                closePdfTextSession(filePath)
                null
            }
            PdfOperation.SEARCH -> searchPdfText(filePath, query)
            PdfOperation.OUTLINE -> getPdfOutline(filePath)
            PdfOperation.ANNOTATIONS -> getPdfTextAnnotations(filePath)
            PdfOperation.PASSWORD_CHECK -> isPdfPasswordProtected(filePath)
            PdfOperation.UNLOCK -> unlockPdf(filePath, password)
            PdfOperation.NOTE -> {
                syncPdfTextNote(filePath, pageIndex, noteId, contents)
                null
            }
            PdfOperation.OCR -> recognizePdfPageText(filePath, pageIndex)
        }
    }

    fun closeRenderResources() = documents.write { closePdfSession() }

    fun closeAnalysisResources() = documents.write {
        closePdfTextSession()
        if (recognizer.isInitialized()) runCatching { recognizer.value.close() }
        Unit
    }

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

    private fun getPdfTextAnnotations(filePath: String): List<Map<String, Any>> {
        return synchronized(pdfTextLock) {
            val session = getPdfTextSession(File(filePath))
            val results = mutableListOf<Map<String, Any>>()
            for (pageIndex in 0 until session.document.numberOfPages) {
                val page = session.document.getPage(pageIndex)
                for (annotation in page.annotations) {
                    val contents = annotation.contents?.trim().orEmpty()
                    if (contents.isEmpty()) continue
                    results.add(
                        mapOf(
                            "pageIndex" to pageIndex,
                            "annotationId" to annotation.annotationName.orEmpty(),
                            "contents" to contents.take(4000),
                        ),
                    )
                    if (results.size >= 2000) return@synchronized results
                }
            }
            results
        }
    }

    private fun isPdfPasswordProtected(filePath: String): Boolean {
        val source = File(filePath)
        require(source.isFile && source.length() > 0) { "PDF 文件为空或无法读取" }
        return try {
            PDDocument.load(source).use { document -> document.isEncrypted }
        } catch (_: InvalidPasswordException) {
            true
        }
    }

    private fun unlockPdf(filePath: String, password: String): Int {
        val source = File(filePath)
        require(source.isFile && source.length() > 0) { "PDF 文件为空或无法读取" }
        clearPdfCache(filePath)
        val temporary = File(source.parentFile, "${source.name}.unlocking")
        if (temporary.exists()) temporary.delete()
        synchronized(pdfTextLock) {
            closePdfTextSession(filePath)
            PDDocument.load(source, password).use { document ->
                require(document.numberOfPages > 0) { "PDF 不包含可显示页面" }
                document.setAllSecurityToBeRemoved(true)
                document.save(temporary)
            }
        }
        require(temporary.isFile && temporary.length() > 0) { "PDF 解锁副本写入失败" }
        try {
            temporary.copyTo(source, overwrite = true)
        } finally {
            temporary.delete()
        }
        return getPdfPageCount(filePath)
    }

    private fun syncPdfTextNote(
        filePath: String,
        pageIndex: Int,
        noteId: String,
        rawContents: String,
    ) {
        require(noteId.isNotBlank() && noteId.length <= 240) { "PDF 笔记标识无效" }
        val source = File(filePath)
        require(source.isFile && source.length() > 0) { "PDF 文件为空或无法读取" }
        clearPdfCache(filePath)
        val temporary = File(source.parentFile, "${source.name}.annotating")
        if (temporary.exists()) temporary.delete()
        synchronized(pdfTextLock) {
            closePdfTextSession(filePath)
            PDDocument.load(source).use { document ->
                require(pageIndex in 0 until document.numberOfPages) { "PDF 页码超出范围" }
                val page = document.getPage(pageIndex)
                page.annotations.removeAll { annotation ->
                    annotation.annotationName == noteId
                }
                val contents = rawContents.trim().take(4000)
                if (contents.isNotEmpty()) {
                    val pageBox = page.cropBox ?: page.mediaBox
                    val markerSize = 22f
                    val annotation = PDAnnotationText().apply {
                        annotationName = noteId
                        this.contents = contents
                        setOpen(false)
                        rectangle = PDRectangle(
                            (pageBox.lowerLeftX + 12f).coerceAtMost(pageBox.upperRightX - markerSize),
                            (pageBox.upperRightY - markerSize - 12f).coerceAtLeast(pageBox.lowerLeftY),
                            markerSize,
                            markerSize,
                        )
                    }
                    page.annotations.add(annotation)
                }
                document.save(temporary)
            }
        }
        require(temporary.isFile && temporary.length() > 0) { "PDF 批注写入失败" }
        try {
            temporary.copyTo(source, overwrite = true)
        } finally {
            temporary.delete()
        }
    }

    private fun recognizePdfPageText(filePath: String, pageIndex: Int): String {
        val source = File(filePath)
        require(source.isFile && source.length() > 0) { "PDF 文件为空或无法读取" }
        val cacheDirectory = File(cacheDir, "readvibe_pdf_ocr/${pdfCacheKey(source)}")
        if (!cacheDirectory.exists()) cacheDirectory.mkdirs()
        val cached = File(cacheDirectory, "$pageIndex.txt")
        if (cached.isFile && cached.length() > 0 && cached.length() <= 8 * 1024 * 1024) {
            return cached.readText(Charsets.UTF_8)
        }

        val descriptor = ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
        val bitmap = try {
            PdfRenderer(descriptor).use { renderer ->
                require(pageIndex in 0 until renderer.pageCount) { "PDF 页码超出范围" }
                renderer.openPage(pageIndex).use { page ->
                    val targetWidth = 1800
                    val scale = targetWidth.toFloat() / page.width.toFloat()
                    val targetHeight = (page.height * scale).toInt().coerceIn(1, 4096)
                    Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888).also {
                        it.eraseColor(Color.WHITE)
                        page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    }
                }
            }
        } finally {
            descriptor.close()
        }
        val text = try {
            val image = InputImage.fromBitmap(bitmap, 0)
            Tasks.await(pdfOcrRecognizer.process(image)).text.orEmpty().trim()
        } finally {
            bitmap.recycle()
        }
        if (text.isNotEmpty() && text.length <= 4 * 1024 * 1024) {
            val temporary = File(cacheDirectory, "$pageIndex.tmp")
            temporary.writeText(text, Charsets.UTF_8)
            temporary.copyTo(cached, overwrite = true)
            temporary.delete()
        }
        return text
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
            val ocrDirectory = File(cacheDir, "readvibe_pdf_ocr/$key")
            if (ocrDirectory.isDirectory) ocrDirectory.deleteRecursively()
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

}
