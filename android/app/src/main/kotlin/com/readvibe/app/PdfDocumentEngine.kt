package com.readvibe.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.cos.COSBase
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationText
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.text.Normalizer
import java.util.LinkedHashMap
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write
import kotlin.math.sqrt

/** Owns document sessions and caches, with no Activity or Flutter channel dependency. */
internal class PdfDocumentEngine(context: Context) {
    private val cacheDir = context.applicationContext.cacheDir
    private val documents = ReentrantReadWriteLock(true)
    private val pdfTextLock = Any()
    private var pdfSession: PdfSession? = null
    private var ocrPdfSession: PdfSession? = null
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
            PdfOperation.PAGE_TEXT -> extractPdfPageText(filePath, pageIndex)
        }
    }

    fun closeRenderResources() = documents.write { closePdfSession() }

    fun closeAnalysisResources() = documents.write {
        closePdfTextSession()
        closeOcrPdfSession()
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

    private fun pdfMemorySetting(): MemoryUsageSetting {
        val tempDir = File(cacheDir, "readvibe_pdf_temp")
        if (!tempDir.exists()) tempDir.mkdirs()
        return MemoryUsageSetting.setupMixed(32L * 1024L * 1024L).setTempDir(tempDir)
    }

    private fun computeRenderSize(
        pageWidth: Int,
        pageHeight: Int,
        requestedWidth: Int,
        maxHeight: Int,
        maxPixels: Long = 12_000_000L,
    ): Pair<Int, Int> {
        require(pageWidth > 0 && pageHeight > 0) { "PDF 页面尺寸无效" }
        var scale = requestedWidth.toDouble() / pageWidth.toDouble()
        val scaledHeight = pageHeight * scale
        if (scaledHeight > maxHeight) {
            scale *= maxHeight.toDouble() / scaledHeight
        }
        val projectedWidth = (pageWidth * scale).coerceAtLeast(1.0)
        val projectedHeight = (pageHeight * scale).coerceAtLeast(1.0)
        val projectedPixels = projectedWidth * projectedHeight
        if (projectedPixels > maxPixels) {
            scale *= sqrt(maxPixels.toDouble() / projectedPixels)
        }
        val targetW = (pageWidth * scale).toInt().coerceIn(1, requestedWidth.coerceAtLeast(1))
        val targetH = (pageHeight * scale).toInt().coerceIn(1, maxHeight)
        return targetW to targetH
    }

    private fun atomicReplace(temporary: File, target: File) {
        try {
            Files.move(
                temporary.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: Throwable) {
            Files.move(
                temporary.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
            )
        }
    }

    private fun prunePdfPageCache(cacheRoot: File, keepFile: File, maxBytes: Long = 128L * 1024L * 1024L) {
        runCatching {
            val allFiles = cacheRoot.walkTopDown().filter { it.isFile }.toList()
            var total = allFiles.sumOf { it.length() }
            if (total <= maxBytes) return
            val targetFloor = (maxBytes * 3) / 4
            for (file in allFiles.sortedBy { it.lastModified() }) {
                if (file.absolutePath == keepFile.absolutePath) continue
                val size = file.length()
                if (file.delete()) {
                    total -= size
                    if (total <= targetFloor) break
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
            val (bmpW, bmpH) = computeRenderSize(page.width, page.height, widthPx, 8192)
            val bitmap = Bitmap.createBitmap(bmpW, bmpH, Bitmap.Config.ARGB_8888)
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
                atomicReplace(temporary, target)
            } finally {
                bitmap.recycle()
            }
        }
        prunePdfPageCache(cacheRoot, target)
        return target.absolutePath
    }

    private data class NormalizedPdfText(
        val text: String,
        val sourceStarts: List<Int>,
        val sourceEnds: List<Int>,
    )

    private fun isCjkCodePoint(codePoint: Int): Boolean =
        (codePoint in 0x3400..0x4dbf) ||
            (codePoint in 0x4e00..0x9fff) ||
            (codePoint in 0xf900..0xfaff) ||
            (codePoint in 0x3040..0x30ff) ||
            (codePoint in 0xac00..0xd7af) ||
            (codePoint in 0x20000..0x2ebef)

    private fun normalizePdfText(source: String): NormalizedPdfText {
        val text = StringBuilder()
        val starts = ArrayList<Int>()
        val ends = ArrayList<Int>()
        var offset = 0
        var whitespaceStart = -1
        var whitespaceEnd = -1
        var lastNonSpaceCodePoint = -1

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
                val rawToken = String(Character.toChars(codePoint))
                val nfkc = Normalizer.normalize(rawToken, Normalizer.Form.NFKC).lowercase(Locale.ROOT)
                if (nfkc.isNotEmpty()) {
                    val firstOutCp = nfkc.codePointAt(0)
                    val joinCjkAcrossWrap =
                        lastNonSpaceCodePoint >= 0 &&
                            isCjkCodePoint(lastNonSpaceCodePoint) &&
                            isCjkCodePoint(firstOutCp)
                    if (whitespaceStart >= 0 && text.isNotEmpty() && !joinCjkAcrossWrap) {
                        text.append(' ')
                        starts.add(whitespaceStart)
                        ends.add(whitespaceEnd)
                    }
                    whitespaceStart = -1
                    text.append(nfkc)
                    repeat(nfkc.length) {
                        starts.add(offset)
                        ends.add(end)
                    }
                    lastNonSpaceCodePoint = nfkc.codePointBefore(nfkc.length)
                } else {
                    whitespaceStart = -1
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
                val source = runCatching { session.pageText(pageIndex) }.getOrDefault("")
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
            val pageMap = HashMap<COSBase, Int>(session.document.numberOfPages)
            for ((index, page) in session.document.pages.withIndex()) {
                pageMap[page.cosObject] = index
            }
            val results = mutableListOf<Map<String, Any>>()
            val visited = HashSet<COSBase>()
            var visitedNodes = 0

            fun appendItems(first: PDOutlineItem?, depth: Int) {
                if (depth > 32) return
                var item = first
                while (item != null && results.size < 5000 && visitedNodes < 20_000) {
                    visitedNodes++
                    val cos = item.cosObject
                    if (!visited.add(cos)) break
                    val page = runCatching { item.findDestinationPage(session.document) }.getOrNull()
                    val pageIndex = page?.cosObject?.let { pageMap[it] } ?: -1
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
                val annotations = runCatching { session.document.getPage(pageIndex).annotations }
                    .getOrNull() ?: continue
                for (annotation in annotations) {
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
            PDDocument.load(source, pdfMemorySetting()).use { document -> document.isEncrypted }
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
        try {
            synchronized(pdfTextLock) {
                closePdfTextSession(filePath)
                PDDocument.load(source, password, pdfMemorySetting()).use { document ->
                    require(document.numberOfPages > 0) { "PDF 不包含可显示页面" }
                    document.setAllSecurityToBeRemoved(true)
                    document.save(temporary)
                }
            }
            require(temporary.isFile && temporary.length() > 0) { "PDF 解锁副本写入失败" }
            atomicReplace(temporary, source)
        } finally {
            if (temporary.exists()) temporary.delete()
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
        try {
            synchronized(pdfTextLock) {
                closePdfTextSession(filePath)
                PDDocument.load(source, pdfMemorySetting()).use { document ->
                    require(pageIndex in 0 until document.numberOfPages) { "PDF 页码超出范围" }
                    if (document.isEncrypted) {
                        document.setAllSecurityToBeRemoved(true)
                    }
                    val page = document.getPage(pageIndex)
                    val mutableAnnotations = page.annotations.toMutableList()
                    mutableAnnotations.removeAll { annotation ->
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
                            rectangle = markerRectForRotation(pageBox, markerSize, page.rotation)
                        }
                        mutableAnnotations.add(annotation)
                    }
                    page.annotations = mutableAnnotations
                    document.save(temporary)
                }
            }
            require(temporary.isFile && temporary.length() > 0) { "PDF 批注写入失败" }
            atomicReplace(temporary, source)
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    private fun markerRectForRotation(
        pageBox: PDRectangle,
        markerSize: Float,
        rotation: Int,
    ): PDRectangle {
        val margin = 12f
        val xMin = pageBox.lowerLeftX
        val yMin = pageBox.lowerLeftY
        val xMax = (pageBox.upperRightX - markerSize).coerceAtLeast(xMin)
        val yMax = (pageBox.upperRightY - markerSize).coerceAtLeast(yMin)
        val (x, y) = when (((rotation % 360) + 360) % 360) {
            90 -> (pageBox.lowerLeftX + margin) to (pageBox.lowerLeftY + margin)
            180 -> (pageBox.upperRightX - markerSize - margin) to (pageBox.lowerLeftY + margin)
            270 -> (pageBox.upperRightX - markerSize - margin) to (pageBox.upperRightY - markerSize - margin)
            else -> (pageBox.lowerLeftX + margin) to (pageBox.upperRightY - markerSize - margin)
        }
        return PDRectangle(
            x.coerceIn(xMin, xMax),
            y.coerceIn(yMin, yMax),
            markerSize,
            markerSize,
        )
    }

    /** Returns the page's own text layer, empty for a scan that carries none. */
    private fun extractPdfPageText(filePath: String, pageIndex: Int): String {
        val source = File(filePath)
        require(source.isFile && source.length() > 0) { "PDF 文件为空或无法读取" }
        return synchronized(pdfTextLock) {
            val session = getPdfTextSession(source)
            require(pageIndex in 0 until session.document.numberOfPages) { "PDF 页码超出范围" }
            session.pageText(pageIndex).trim()
        }
    }

    private fun recognizePdfPageText(filePath: String, pageIndex: Int): String {
        val source = File(filePath)
        require(source.isFile && source.length() > 0) { "PDF 文件为空或无法读取" }
        val cacheKey = pdfCacheKey(source)
        val cacheDirectory = File(cacheDir, "readvibe_pdf_ocr/$cacheKey")
        if (!cacheDirectory.exists()) cacheDirectory.mkdirs()
        val cached = File(cacheDirectory, "$pageIndex.txt")
        if (cached.isFile && cached.length() > 0 && cached.length() <= 8 * 1024 * 1024) {
            return cached.readText(Charsets.UTF_8)
        }

        val bitmap = synchronized(pdfTextLock) {
            val session = getOcrPdfSession(source)
            require(pageIndex in 0 until session.renderer.pageCount) { "PDF 页码超出范围" }
            session.renderer.openPage(pageIndex).use { page ->
                val (bmpW, bmpH) = computeRenderSize(page.width, page.height, 1800, 4096)
                Bitmap.createBitmap(bmpW, bmpH, Bitmap.Config.ARGB_8888).also {
                    it.eraseColor(Color.WHITE)
                    page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                }
            }
        }
        val text = try {
            val image = InputImage.fromBitmap(bitmap, 0)
            Tasks.await(pdfOcrRecognizer.process(image), 30, TimeUnit.SECONDS).text.orEmpty().trim()
        } finally {
            bitmap.recycle()
        }
        if (text.isNotEmpty() && text.length <= 4 * 1024 * 1024) {
            val temporary = File(cacheDirectory, "$pageIndex.tmp")
            temporary.writeText(text, Charsets.UTF_8)
            atomicReplace(temporary, cached)
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
        synchronized(pdfTextLock) {
            val activeOcr = ocrPdfSession
            if (activeOcr?.sourcePath == sourcePath) {
                keys.add(activeOcr.cacheKey)
                closeOcrPdfSession()
            }
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

    private fun getOcrPdfSession(source: File): PdfSession {
        val sourcePath = source.canonicalPath
        val cacheKey = pdfCacheKey(source)
        val active = ocrPdfSession
        if (active != null && active.sourcePath == sourcePath && active.cacheKey == cacheKey) {
            return active
        }
        closeOcrPdfSession()
        val descriptor = ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
        try {
            val renderer = PdfRenderer(descriptor)
            return PdfSession(sourcePath, cacheKey, descriptor, renderer).also {
                ocrPdfSession = it
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
        val document = PDDocument.load(source, pdfMemorySetting())
        return PdfTextSession(sourcePath, cacheKey, document).also {
            pdfTextSession = it
        }
    }

    private fun closePdfSession() {
        val active = pdfSession ?: return
        pdfSession = null
        runCatching { active.close() }
    }

    private fun closeOcrPdfSession() {
        val active = ocrPdfSession ?: return
        ocrPdfSession = null
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
