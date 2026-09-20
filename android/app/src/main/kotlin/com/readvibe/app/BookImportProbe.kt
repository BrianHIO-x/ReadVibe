package com.readvibe.app

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.Charset
import java.util.Locale

/**
 * Inspects a SAF URI without copying the payload, then copies only files that
 * look like books. Android packages are rejected from the name, MIME type, or
 * ZIP central directory so a 50 MB APK never lands in cache.
 */
object BookImportProbe {
    const val ANDROID_PACKAGE_MESSAGE = "这是 Android 安装包，不是书籍"
    const val UNSUPPORTED_MESSAGE =
        "不支持的文件格式，请选择 TXT、EPUB、MOBI、AZW、AZW3、PDF、DOCX 或 DOC"

    private const val PACKAGE_MIME = "application/vnd.android.package-archive"
    private const val MAX_COPY_BYTES = 1024L * 1024L * 1024L
    private const val MAX_CENTRAL_DIRECTORY_BYTES = 2 * 1024 * 1024
    private const val MAX_ZIP_ENTRIES = 4096
    private const val EOCD_MIN_SIZE = 22
    private const val MAX_EOCD_COMMENT = 65535
    private const val ZIP64_LOCATOR_SIZE = 20
    private const val ZIP64_EOCD_MIN_SIZE = 56
    private const val CENTRAL_HEADER_SIZE = 46
    private const val EOCD_SIGNATURE = 0x06054b50L
    private const val ZIP64_LOCATOR_SIGNATURE = 0x07064b50L
    private const val ZIP64_EOCD_SIGNATURE = 0x06064b50L
    private const val CENTRAL_DIRECTORY_SIGNATURE = 0x02014b50L
    private val PACKAGE_EXTENSIONS = setOf("apk", "apks", "xapk", "apkm")
    private val BOOK_EXTENSIONS = setOf(
        "txt", "epub", "mobi", "azw", "azw3", "pdf", "doc", "docx",
    )
    private val DEX_ENTRY = Regex("^classes\\d+\\.dex$")

    enum class Kind {
        APK, EPUB, DOCX, PDF, DOC, MOBI, TXT, UNKNOWN, UNSEEKABLE,
    }

    fun copyPickedBook(
        context: Context,
        uri: Uri,
        onBytesCopied: (Long) -> Unit = {},
    ): Map<String, String> {
        val meta = queryMeta(context, uri)
        if (isAndroidPackage(meta.names, meta.mimes)) {
            error(ANDROID_PACKAGE_MESSAGE)
        }
        val kind = peek(context, uri)
        if (kind == Kind.APK) error(ANDROID_PACKAGE_MESSAGE)
        if (!shouldCopy(kind, meta.displayName)) error(UNSUPPORTED_MESSAGE)
        return copyToCache(
            context,
            uri,
            meta.displayName,
            kind,
            "readvibe_picked",
            onBytesCopied,
        )
    }

    fun rejectAndroidPackage(context: Context, uri: Uri, extraNames: List<String>, extraMimes: List<String>) {
        val meta = queryMeta(context, uri)
        if (isAndroidPackage(meta.names + extraNames, meta.mimes + extraMimes)) {
            error(ANDROID_PACKAGE_MESSAGE)
        }
        if (peek(context, uri) == Kind.APK) {
            error(ANDROID_PACKAGE_MESSAGE)
        }
    }

    fun isAndroidPackage(names: List<String>, mimes: List<String>): Boolean {
        if (mimes.any { it.equals(PACKAGE_MIME, ignoreCase = true) }) return true
        return names.any { extensionOf(it) in PACKAGE_EXTENSIONS }
    }

    private fun shouldCopy(kind: Kind, displayName: String): Boolean {
        return when (kind) {
            Kind.APK -> false
            Kind.EPUB, Kind.DOCX, Kind.PDF, Kind.DOC, Kind.MOBI, Kind.TXT -> true
            Kind.UNKNOWN, Kind.UNSEEKABLE -> extensionOf(displayName) in BOOK_EXTENSIONS
        }
    }

    private data class Meta(
        val displayName: String,
        val names: List<String>,
        val mimes: List<String>,
    )

    private fun queryMeta(context: Context, uri: Uri): Meta {
        var displayName = ""
        if (uri.scheme == "content") {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (column >= 0) displayName = cursor.getString(column).orEmpty()
                }
            }
        }
        val pathName = uri.lastPathSegment?.substringAfterLast('/').orEmpty()
        val resolverType = if (uri.scheme == "content") {
            context.contentResolver.getType(uri).orEmpty()
        } else {
            ""
        }
        val fromExtension = MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(extensionOf(displayName.ifEmpty { pathName }))
            .orEmpty()
        val name = displayName.trim().ifEmpty { pathName }.ifEmpty { "外部文件" }
        return Meta(
            displayName = name,
            names = listOf(displayName, pathName, name, uri.toString()),
            mimes = listOf(resolverType, fromExtension).filter { it.isNotEmpty() },
        )
    }

    private fun peek(context: Context, uri: Uri): Kind {
        val pfd = try {
            context.contentResolver.openFileDescriptor(uri, "r")
        } catch (_: Exception) {
            null
        } ?: return Kind.UNSEEKABLE
        ParcelFileDescriptor.AutoCloseInputStream(pfd).use { input ->
            return peekChannel(input.channel)
        }
    }

    private fun peekChannel(channel: FileChannel): Kind {
        val size = try {
            channel.size()
        } catch (_: Exception) {
            0L
        }
        if (size <= 0L) return Kind.UNSEEKABLE
        val header = try {
            readAt(channel, 0L, minOf(68L, size).toInt())
        } catch (_: Exception) {
            return Kind.UNSEEKABLE
        }
        if (isPdf(header)) return Kind.PDF
        if (isOle(header)) return Kind.DOC
        if (isMobi(header)) return Kind.MOBI
        if (isZip(header)) {
            val names = try {
                zipNames(channel, size)
            } catch (_: Exception) {
                return Kind.UNSEEKABLE
            } ?: return Kind.UNKNOWN
            if (isApkArchive(names)) return Kind.APK
            if (isEpubArchive(names)) return Kind.EPUB
            if (isDocxArchive(names)) return Kind.DOCX
            return Kind.UNKNOWN
        }
        val sample = if (header.size >= minOf(8192L, size).toInt()) {
            header
        } else {
            try {
                readAt(channel, 0L, minOf(8192L, size).toInt())
            } catch (_: Exception) {
                header
            }
        }
        if (looksLikePlainText(sample)) return Kind.TXT
        return Kind.UNKNOWN
    }

    private fun zipNames(channel: FileChannel, size: Long): Set<String>? {
        if (size < EOCD_MIN_SIZE) return null
        val maxScan = minOf(size, (EOCD_MIN_SIZE + MAX_EOCD_COMMENT).toLong()).toInt()
        val tailStart = size - maxScan
        val tail = readAt(channel, tailStart, maxScan)
        val eocdOffset = findEocd(tail, size, tailStart) ?: return null
        val eocd = readAt(channel, eocdOffset, EOCD_MIN_SIZE)
        if (eocd.size < EOCD_MIN_SIZE) return null
        var entries = u16(eocd, 10).toLong()
        var cdSize = u32(eocd, 12)
        var cdOffset = u32(eocd, 16)
        if (entries == 0xffffL || cdSize == 0xffffffffL || cdOffset == 0xffffffffL) {
            readZip64(channel, eocdOffset)?.let { zip64 ->
                entries = zip64.first
                cdSize = zip64.second
                cdOffset = zip64.third
            }
        }
        if (entries <= 0L || cdSize <= 0L || cdOffset < 0L || cdOffset >= size) return null
        val available = size - cdOffset
        if (available <= 0L) return null
        val bounded = minOf(cdSize, available, MAX_CENTRAL_DIRECTORY_BYTES.toLong()).toInt()
        val directory = readAt(channel, cdOffset, bounded)
        if (directory.isEmpty()) return null
        return namesFromCentralDirectory(directory)
    }

    private fun findEocd(tail: ByteArray, fileSize: Long, tailStart: Long): Long? {
        var abs = fileSize - EOCD_MIN_SIZE
        while (abs >= tailStart) {
            val index = (abs - tailStart).toInt()
            if (index + EOCD_MIN_SIZE <= tail.size && u32(tail, index) == EOCD_SIGNATURE) {
                val commentLength = u16(tail, index + 20)
                if (abs + EOCD_MIN_SIZE + commentLength == fileSize) return abs
            }
            abs--
        }
        return null
    }

    private fun readZip64(channel: FileChannel, eocdOffset: Long): Triple<Long, Long, Long>? {
        if (eocdOffset < ZIP64_LOCATOR_SIZE) return null
        val locator = readAt(channel, eocdOffset - ZIP64_LOCATOR_SIZE, ZIP64_LOCATOR_SIZE)
        if (locator.size < ZIP64_LOCATOR_SIZE) return null
        if (u32(locator, 0) != ZIP64_LOCATOR_SIGNATURE) return null
        val zip64Offset = u64(locator, 8)
        if (zip64Offset < 0L) return null
        val record = readAt(channel, zip64Offset, ZIP64_EOCD_MIN_SIZE)
        if (record.size < ZIP64_EOCD_MIN_SIZE) return null
        if (u32(record, 0) != ZIP64_EOCD_SIGNATURE) return null
        val entries = u64(record, 32)
        val size = u64(record, 40)
        val offset = u64(record, 48)
        if (entries <= 0L || size <= 0L || offset < 0L) return null
        return Triple(entries, size, offset)
    }

    private fun namesFromCentralDirectory(directory: ByteArray): Set<String> {
        val names = linkedSetOf<String>()
        var offset = 0
        while (offset + CENTRAL_HEADER_SIZE <= directory.size && names.size < MAX_ZIP_ENTRIES) {
            if (u32(directory, offset) != CENTRAL_DIRECTORY_SIGNATURE) break
            val nameLength = u16(directory, offset + 28)
            val extraLength = u16(directory, offset + 30)
            val commentLength = u16(directory, offset + 32)
            val nameStart = offset + CENTRAL_HEADER_SIZE
            val nameEnd = nameStart + nameLength
            if (nameEnd > directory.size) break
            if (nameLength > 0) {
                names.add(zipName(String(directory, nameStart, nameLength, Charset.forName("ISO-8859-1"))))
            }
            offset = nameEnd + extraLength + commentLength
        }
        return names
    }

    private fun isApkArchive(names: Set<String>): Boolean {
        val hasManifest = names.contains("androidmanifest.xml")
        val hasDex = names.any { it == "classes.dex" || DEX_ENTRY.matches(it) }
        val hasResources = names.contains("resources.arsc")
        return hasManifest && (hasDex || hasResources)
    }

    private fun isEpubArchive(names: Set<String>): Boolean {
        return names.contains("meta-inf/container.xml") || names.contains("mimetype")
    }

    private fun isDocxArchive(names: Set<String>): Boolean {
        val hasContentTypes = names.contains("[content_types].xml")
        val hasWord = names.any { it == "word" || it.startsWith("word/") }
        return hasContentTypes && hasWord
    }

    private fun zipName(name: String): String {
        var value = name.replace('\\', '/').lowercase(Locale.ROOT)
        while (value.startsWith("./")) value = value.substring(2)
        if (value.startsWith("/")) value = value.substring(1)
        return value
    }

    private fun isPdf(bytes: ByteArray): Boolean {
        return bytes.size >= 4 &&
            bytes[0] == 0x25.toByte() &&
            bytes[1] == 0x50.toByte() &&
            bytes[2] == 0x44.toByte() &&
            bytes[3] == 0x46.toByte()
    }

    private fun isZip(bytes: ByteArray): Boolean {
        return bytes.size >= 4 &&
            bytes[0] == 0x50.toByte() &&
            bytes[1] == 0x4b.toByte() &&
            bytes[2] == 3.toByte() &&
            bytes[3] == 4.toByte()
    }

    private fun isOle(bytes: ByteArray): Boolean {
        return bytes.size >= 4 &&
            bytes[0] == 0xd0.toByte() &&
            bytes[1] == 0xcf.toByte() &&
            bytes[2] == 0x11.toByte() &&
            bytes[3] == 0xe0.toByte()
    }

    private fun isMobi(bytes: ByteArray): Boolean {
        if (bytes.size < 68) return false
        return bytes[60] == 0x42.toByte() &&
            bytes[61] == 0x4f.toByte() &&
            bytes[62] == 0x4f.toByte() &&
            bytes[63] == 0x4b.toByte() &&
            bytes[64] == 0x4d.toByte() &&
            bytes[65] == 0x4f.toByte() &&
            bytes[66] == 0x42.toByte() &&
            bytes[67] == 0x49.toByte()
    }

    private fun looksLikePlainText(bytes: ByteArray): Boolean {
        if (bytes.isEmpty()) return false
        if (bytes.size >= 3 &&
            bytes[0] == 0xef.toByte() &&
            bytes[1] == 0xbb.toByte() &&
            bytes[2] == 0xbf.toByte()
        ) {
            return true
        }
        if (bytes.size >= 2 &&
            ((bytes[0] == 0xff.toByte() && bytes[1] == 0xfe.toByte()) ||
                (bytes[0] == 0xfe.toByte() && bytes[1] == 0xff.toByte()))
        ) {
            return true
        }
        if (bytes.any { it == 0.toByte() }) return false
        val text = try {
            String(bytes, Charsets.UTF_8)
        } catch (_: Exception) {
            return looksLikeLegacyChinese(bytes)
        }
        return text.trim().isNotEmpty()
    }

    private fun looksLikeLegacyChinese(bytes: ByteArray): Boolean {
        var lead = 0
        var pairs = 0
        for (value in bytes) {
            val unsigned = value.toInt() and 0xff
            if (lead != 0) {
                if (unsigned >= 0x40) pairs++
                lead = 0
                continue
            }
            if (unsigned in 0x81..0xfe) {
                lead = unsigned
                continue
            }
            val isAsciiText =
                unsigned == 9 || unsigned == 10 || unsigned == 13 || unsigned in 32 until 127
            if (isAsciiText) continue
            if (unsigned < 32) return false
        }
        return pairs >= 8
    }

    private fun copyToCache(
        context: Context,
        uri: Uri,
        displayName: String,
        kind: Kind,
        directoryName: String,
        onBytesCopied: (Long) -> Unit = {},
    ): Map<String, String> {
        val directory = File(context.cacheDir, directoryName)
        if (!directory.exists()) directory.mkdirs()
        val staleBefore = System.currentTimeMillis() - 24L * 60L * 60L * 1000L
        directory.listFiles()?.forEach { file ->
            if (file.lastModified() < staleBefore) file.delete()
        }
        val labeled = labeledName(displayName, kind)
        val sanitized = labeled.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_")
        val target = File(directory, "${System.currentTimeMillis()}_${sanitized.ifEmpty { "file" }}")
        val input = when (uri.scheme) {
            "file" -> FileInputStream(File(requireNotNull(uri.path)))
            else -> context.contentResolver.openInputStream(uri)
        } ?: error("系统未授予外部文件读取权限")
        var copied = 0L
        try {
            input.use { source ->
                FileOutputStream(target).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        copied += count
                        if (copied > MAX_COPY_BYTES) error("外部文件超过 1 GB，无法导入")
                        output.write(buffer, 0, count)
                        // A document provider may stream from the network, so
                        // the caller needs to see that bytes are still moving
                        // to tell a slow copy from one that will never finish.
                        onBytesCopied(copied)
                    }
                    output.flush()
                }
            }
            require(copied > 0) { "外部文件为空" }
            return mapOf(
                "path" to target.absolutePath,
                "name" to labeled,
            )
        } catch (error: Throwable) {
            target.delete()
            throw error
        }
    }

    private fun labeledName(displayName: String, kind: Kind): String {
        val extension = when (kind) {
            Kind.EPUB -> "epub"
            Kind.DOCX -> "docx"
            Kind.PDF -> "pdf"
            Kind.DOC -> "doc"
            Kind.MOBI -> "mobi"
            Kind.TXT -> "txt"
            else -> ""
        }
        val current = extensionOf(displayName)
        if (extension.isEmpty() || current == extension) return displayName
        if (current.isEmpty()) return "$displayName.$extension"
        val stem = displayName.substringBeforeLast('.')
        return "$stem.$extension"
    }

    private fun extensionOf(name: String): String {
        val base = name.substringAfterLast('/').substringAfterLast('\\')
        val dot = base.lastIndexOf('.')
        if (dot <= 0 || dot == base.length - 1) return ""
        return base.substring(dot + 1).lowercase(Locale.ROOT)
    }

    private fun readAt(channel: FileChannel, position: Long, count: Int): ByteArray {
        if (count <= 0) return ByteArray(0)
        val buffer = ByteBuffer.allocate(count)
        channel.position(position)
        while (buffer.hasRemaining()) {
            val read = channel.read(buffer)
            if (read < 0) break
        }
        val length = buffer.position()
        return if (length == count) buffer.array() else buffer.array().copyOf(length)
    }

    private fun u16(bytes: ByteArray, offset: Int): Int {
        return (bytes[offset].toInt() and 0xff) or
            ((bytes[offset + 1].toInt() and 0xff) shl 8)
    }

    private fun u32(bytes: ByteArray, offset: Int): Long {
        return (bytes[offset].toLong() and 0xff) or
            ((bytes[offset + 1].toLong() and 0xff) shl 8) or
            ((bytes[offset + 2].toLong() and 0xff) shl 16) or
            ((bytes[offset + 3].toLong() and 0xff) shl 24)
    }

    private fun u64(bytes: ByteArray, offset: Int): Long {
        val lo = u32(bytes, offset)
        val hi = u32(bytes, offset + 4)
        return lo or (hi shl 32)
    }
}
