package com.readvibe.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Manages the uninstall-proof ReadVibe_Vault directory across both SAF
 * (`content://`) and optional direct-storage (`file://`) backends with bounded
 * 64 KB streaming I/O, atomic writes, and strict quota/space guards.
 */
class StorageVaultHandler(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val REQUEST_PICK_TREE = 0x5256
        private const val REQUEST_MANAGE_ALL_FILES = 0x5257
        private const val ABANDONED_PICK_GRACE_MS = 1_500L
        private const val VAULT_ROOT_DIR = "ReadVibe_Vault"
        private const val STAGING_CACHE_DIR = "readvibe_vault_staging"
        private const val BUFFER_BYTES = 64 * 1024
        private const val MIN_FREE_SPACE_FLOOR = 256L * 1024L * 1024L
        private const val WRITE_HEADROOM_MARGIN = 128L * 1024L * 1024L
        private const val MAX_STREAM_READ_BYTES = 2L * 1024L * 1024L * 1024L
        private val VALID_REL_PATH = Regex(
            """^(vault_manifest\.json|books/[A-Za-z0-9_-]{1,128}\.rvbook|fonts/[A-Za-z0-9_.\-\u4e00-\u9fa5]{1,160}\.(ttf|otf))$""",
        )
    }

    private data class DocEntry(
        val uri: Uri,
        val documentId: String,
        val name: String,
        val isDir: Boolean,
        val size: Long,
        val lastModified: Long,
    )

    private val channel = MethodChannel(messenger, "com.readvibe.app/storage_vault")
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cancelled = AtomicBoolean(false)
    @Volatile private var disposed = false
    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingAllFilesResult: MethodChannel.Result? = null
    private var pickerTookForeground = false
    private var abandonedRunnable: Runnable? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickTree" -> launchTreePicker(result)
                "allFilesAccessStatus" -> runAsync(result) { allFilesAccessStatusMap() }
                "requestAllFilesAccess" -> launchAllFilesSettings(result)
                "listLocalDirectories" -> runAsync(result) {
                    listLocalDirectoriesMap(call.argument("path"))
                }
                "createLocalDirectory" -> runAsync(result) {
                    createLocalDirectoryPath(
                        parentPath = call.argument("parentPath"),
                        name = call.argument("name"),
                    )
                }
                "bindLocalDirectory" -> runAsync(result) {
                    bindLocalDirectoryMap(call.argument("path"))
                }
                "checkTree" -> runAsync(result) {
                    val uri = requireTreeUri(call.argument("treeUri"))
                    checkTreeAccess(uri)
                }
                "releaseTree" -> runAsync(result) {
                    val raw = call.argument<String>("treeUri")
                    if (!raw.isNullOrBlank()) {
                        val uri = Uri.parse(raw)
                        if (uri.scheme != "file") {
                            runCatching {
                                activity.contentResolver.releasePersistableUriPermission(
                                    uri,
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                                )
                            }
                        }
                    }
                    true
                }
                "deviceStorageInfo" -> runAsync(result) {
                    mapOf("freeBytes" to availableStorageBytes())
                }
                "listVaultFiles" -> runAsync(result) {
                    val uri = requireTreeUri(call.argument("treeUri"))
                    listVaultEntries(uri)
                }
                "readVaultFileToCache" -> runAsync(result) {
                    val uri = requireTreeUri(call.argument("treeUri"))
                    val relPath = requireValidRelPath(call.argument("relativePath"))
                    val maxBytes = (call.argument<Number>("maxBytes")?.toLong()
                        ?: MAX_STREAM_READ_BYTES).coerceIn(1L, MAX_STREAM_READ_BYTES)
                    streamVaultFileToCache(uri, relPath, maxBytes)
                }
                "writeCacheFileToVault" -> runAsync(result) {
                    val uri = requireTreeUri(call.argument("treeUri"))
                    val relPath = requireValidRelPath(call.argument("relativePath"))
                    val sourcePath = call.argument<String>("sourcePath")
                        ?: throw IllegalArgumentException("缺失源文件")
                    val quotaBytes = call.argument<Number>("maxVaultBytes")?.toLong() ?: 0L
                    streamCacheFileToVault(uri, sourcePath, relPath, quotaBytes)
                }
                "deleteVaultFile" -> runAsync(result) {
                    val uri = requireTreeUri(call.argument("treeUri"))
                    val relPath = requireValidRelPath(call.argument("relativePath"))
                    deleteVaultEntry(uri, relPath)
                }
                "purgeVault" -> runAsync(result) {
                    val uri = requireTreeUri(call.argument("treeUri"))
                    purgeVaultRoot(uri)
                }
                "cancelOperations" -> {
                    cancelled.set(true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        if (disposed) {
            result.error("DISPOSED", "服务已关闭", null)
            return
        }
        cancelled.set(false)
        worker.execute {
            try {
                val value = block()
                postMain {
                    if (!disposed) result.success(value)
                }
            } catch (error: Throwable) {
                val code = when (error) {
                    is QuotaExceededException -> "QUOTA_EXCEEDED"
                    is LowSpaceException -> "LOW_DISK_SPACE"
                    is SecurityException -> "PERMISSION_DENIED"
                    else -> "VAULT_IO_ERROR"
                }
                postMain {
                    if (!disposed) {
                        result.error(code, error.message ?: "守护目录读写失败", null)
                    }
                }
            }
        }
    }

    private fun postMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action()
        else mainHandler.post(action)
    }

    private fun cancelAbandonedCheck() {
        abandonedRunnable?.let(mainHandler::removeCallbacks)
        abandonedRunnable = null
    }

    fun onPause() {
        if (pendingPickResult != null || pendingAllFilesResult != null) {
            pickerTookForeground = true
        }
    }

    fun onResume() {
        if (!pickerTookForeground) return
        pickerTookForeground = false
        cancelAbandonedCheck()
        val runnable = Runnable {
            abandonedRunnable = null
            pendingPickResult?.let { abandoned ->
                pendingPickResult = null
                abandoned.success(null)
            }
            pendingAllFilesResult?.let { settingsResult ->
                pendingAllFilesResult = null
                settingsResult.success(isAllFilesGranted())
            }
        }
        abandonedRunnable = runnable
        mainHandler.postDelayed(runnable, ABANDONED_PICK_GRACE_MS)
    }

    private fun buildOpenTreeIntent(): Intent {
        val documentsUri = resolveDocumentsInitialUri()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val baseIntent = runCatching {
                activity.getSystemService(StorageManager::class.java)
                    ?.primaryStorageVolume
                    ?.createOpenDocumentTreeIntent()
            }.getOrNull()
            return (baseIntent ?: Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)).apply {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, documentsUri)
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                )
            }
        }
        return Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, documentsUri)
            }
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
    }

    private fun resolveDocumentsInitialUri(): Uri {
        val fallback = Uri.parse(
            "content://com.android.externalstorage.documents/document/primary%3ADocuments",
        )
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return fallback
        return runCatching {
            val baseIntent = activity.getSystemService(StorageManager::class.java)
                ?.primaryStorageVolume
                ?.createOpenDocumentTreeIntent()
            val rawUri = if (Build.VERSION.SDK_INT >= 33) {
                baseIntent?.getParcelableExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    Uri::class.java,
                )
            } else {
                @Suppress("DEPRECATION")
                baseIntent?.getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI)
            } ?: return@runCatching fallback
            val docBase = rawUri.toString().replace("/root/", "/document/")
            val target = if (docBase.endsWith("/")) {
                "${docBase}primary%3ADocuments"
            } else {
                "$docBase%3ADocuments"
            }
            Uri.parse(target)
        }.getOrDefault(fallback)
    }

    private fun launchTreePicker(result: MethodChannel.Result) {
        if (pendingPickResult != null || pendingAllFilesResult != null) {
            result.error("BUSY", "目录选择器已打开", null)
            return
        }
        cancelAbandonedCheck()
        pendingPickResult = result
        pickerTookForeground = false
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(buildOpenTreeIntent(), REQUEST_PICK_TREE)
        } catch (_: Exception) {
            try {
                @Suppress("DEPRECATION")
                activity.startActivityForResult(
                    Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                        )
                    },
                    REQUEST_PICK_TREE,
                )
            } catch (_: Exception) {
                pendingPickResult = null
                result.error("PICKER_FAILED", "无法打开系统目录选择器", null)
            }
        }
    }

    private fun launchAllFilesSettings(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 30) {
            result.success(false)
            return
        }
        if (isAllFilesGranted()) {
            result.success(true)
            return
        }
        if (pendingPickResult != null || pendingAllFilesResult != null) {
            result.error("BUSY", "授权界面已打开", null)
            return
        }
        cancelAbandonedCheck()
        pendingAllFilesResult = result
        pickerTookForeground = false
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(
                Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:${activity.packageName}"),
                ),
                REQUEST_MANAGE_ALL_FILES,
            )
        } catch (_: Exception) {
            try {
                @Suppress("DEPRECATION")
                activity.startActivityForResult(
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
                    REQUEST_MANAGE_ALL_FILES,
                )
            } catch (_: Exception) {
                pendingAllFilesResult = null
                result.error("PICKER_FAILED", "无法打开系统所有文件访问授权页面", null)
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_MANAGE_ALL_FILES) {
            cancelAbandonedCheck()
            pickerTookForeground = false
            val pending = pendingAllFilesResult ?: return true
            pendingAllFilesResult = null
            pending.success(isAllFilesGranted())
            return true
        }
        if (requestCode != REQUEST_PICK_TREE) return false
        cancelAbandonedCheck()
        pickerTookForeground = false
        val pending = pendingPickResult ?: return true
        pendingPickResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pending.success(null)
            return true
        }
        val treeUri = data.data!!
        val flags = data.flags and (
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        try {
            activity.contentResolver.takePersistableUriPermission(
                treeUri,
                if (flags != 0) {
                    flags
                } else {
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                },
            )
        } catch (_: SecurityException) {
            // Some virtual document providers deny persistable flag even when writable now.
        }
        runAsync(pending) {
            val info = checkTreeAccess(treeUri)
            if (info["valid"] != true) {
                throw SecurityException("所选目录没有持久化读写权限")
            }
            info
        }
        return true
    }

    private fun isAllFilesGranted(): Boolean =
        Build.VERSION.SDK_INT >= 30 && Environment.isExternalStorageManager()

    private fun externalStorageRoot(): File =
        Environment.getExternalStorageDirectory().canonicalFile

    private fun allFilesAccessStatusMap(): Map<String, Any> {
        val extRoot = externalStorageRoot()
        val docs = File(extRoot, "Documents").canonicalFile
        val defaultDir = if (docs.isDirectory) docs else extRoot
        return mapOf(
            "supported" to (Build.VERSION.SDK_INT >= 30),
            "granted" to isAllFilesGranted(),
            "rootPath" to extRoot.path,
            "defaultPath" to defaultDir.path,
        )
    }

    private fun relativeStoragePath(extRoot: File, dir: File): String {
        val canonical = dir.canonicalFile
        if (canonical == extRoot) return ""
        val prefix = extRoot.path + File.separator
        if (!canonical.path.startsWith(prefix)) {
            throw SecurityException("禁止访问外部存储范围之外的目录")
        }
        return canonical.path.substring(prefix.length).replace(File.separatorChar, '/')
    }

    private fun isRestrictedLocalRelativePath(relPath: String): Boolean {
        val lower = relPath.lowercase()
        return lower == "android/data" ||
            lower.startsWith("android/data/") ||
            lower == "android/obb" ||
            lower.startsWith("android/obb/") ||
            lower.startsWith("android/.")
    }

    private fun requireLocalDir(rawPath: String?, defaultToDocs: Boolean = false): Pair<File, String> {
        if (!isAllFilesGranted()) {
            throw SecurityException("尚未授予所有文件访问权限")
        }
        val extRoot = externalStorageRoot()
        val candidate = if (rawPath.isNullOrBlank() && defaultToDocs) {
            val docs = File(extRoot, "Documents")
            if (docs.isDirectory) docs else extRoot
        } else if (rawPath.isNullOrBlank()) {
            extRoot
        } else {
            File(rawPath.trim())
        }
        val canonical = candidate.canonicalFile
        val rel = relativeStoragePath(extRoot, canonical)
        if (isRestrictedLocalRelativePath(rel)) {
            throw SecurityException("系统受保护目录不可选择或访问")
        }
        if (!canonical.isDirectory) {
            throw IOException("所选目录不存在")
        }
        return canonical to rel
    }

    private fun listLocalDirectoriesMap(rawPath: String?): Map<String, Any?> {
        val extRoot = externalStorageRoot()
        val (dir, rel) = requireLocalDir(rawPath, defaultToDocs = rawPath.isNullOrBlank())
        val parentPath = if (dir == extRoot) null else dir.parentFile?.canonicalPath
        val hasVault = File(dir, "$VAULT_ROOT_DIR/vault_manifest.json").isFile

        val priorityNames = mapOf("documents" to 0, "download" to 1)
        val rawChildren = dir.listFiles { child ->
            if (!child.isDirectory) return@listFiles false
            val name = child.name
            if (name.startsWith(".") || name == VAULT_ROOT_DIR) return@listFiles false
            val childRel = if (rel.isEmpty()) name else "$rel/$name"
            !isRestrictedLocalRelativePath(childRel)
        }?.toList().orEmpty()

        val items = rawChildren.map { child ->
            val canonical = child.canonicalFile
            val childHasVault = File(canonical, "$VAULT_ROOT_DIR/vault_manifest.json").isFile
            mapOf(
                "path" to canonical.path,
                "name" to canonical.name,
                "hasVault" to childHasVault,
            )
        }.sortedWith(
            compareBy<Map<String, Any>>(
                { if (it["hasVault"] == true) 0 else 1 },
                {
                    if (rel.isEmpty()) {
                        priorityNames[(it["name"] as String).lowercase()] ?: 2
                    } else {
                        0
                    }
                },
                { (it["name"] as String).lowercase() },
            ),
        )

        return mapOf(
            "currentPath" to dir.path,
            "parentPath" to parentPath,
            "relativePath" to rel,
            "displayName" to rel.ifEmpty { "内部存储" },
            "hasVault" to hasVault,
            "directories" to items,
        )
    }

    private fun createLocalDirectoryPath(parentPath: String?, name: String?): String {
        val (parentDir, _) = requireLocalDir(parentPath)
        val trimmed = name?.trim().orEmpty()
        require(trimmed.isNotEmpty() && trimmed.length <= 60) {
            "文件夹名称长度需在 1 到 60 个字符之间"
        }
        require(
            !trimmed.startsWith(".") &&
                trimmed != "." &&
                trimmed != ".." &&
                !trimmed.contains('/') &&
                !trimmed.contains('\\') &&
                !trimmed.equals(VAULT_ROOT_DIR, ignoreCase = true) &&
                trimmed.none { it.code < 32 },
        ) { "文件夹名称包含不支持的字符" }

        val target = File(parentDir, trimmed).canonicalFile
        val extRoot = externalStorageRoot()
        val rel = relativeStoragePath(extRoot, target)
        if (isRestrictedLocalRelativePath(rel)) {
            throw SecurityException("不可在受保护目录下新建文件夹")
        }
        if (target.exists() && !target.isDirectory) {
            throw IOException("同名文件已存在")
        }
        if (!target.exists() && !target.mkdirs()) {
            throw IOException("无法创建文件夹 $trimmed")
        }
        return target.path
    }

    private fun bindLocalDirectoryMap(rawPath: String?): Map<String, Any?> {
        val (dir, rel) = requireLocalDir(rawPath)
        if (!dir.canRead() || !dir.canWrite()) {
            throw SecurityException("所选目录不可读写，请更换其他目录或检查权限")
        }
        return mapOf(
            "treeUri" to Uri.fromFile(dir).toString(),
            "displayName" to rel.ifEmpty { "内部存储" },
            "valid" to true,
            "freeBytes" to availableStorageBytes(),
        )
    }

    private fun requireTreeUri(raw: String?): Uri {
        val trimmed = raw?.trim().orEmpty()
        require(trimmed.isNotEmpty()) { "守护目录地址为空" }
        return Uri.parse(trimmed)
    }

    private fun requireValidRelPath(raw: String?): String {
        val value = raw?.trim().orEmpty()
        require(VALID_REL_PATH.matches(value)) { "非法的守护目录路径：$value" }
        return value
    }

    private fun resolveDirectRoot(treeUri: Uri): File? {
        if (treeUri.scheme != "file") return null
        val path = treeUri.path?.trim().orEmpty()
        require(path.isNotEmpty()) { "守护目录路径为空" }
        val extRoot = externalStorageRoot()
        val dir = File(path).canonicalFile
        val rel = relativeStoragePath(extRoot, dir)
        if (isRestrictedLocalRelativePath(rel)) {
            throw SecurityException("系统受保护目录不可访问")
        }
        return dir
    }

    private fun resolveDirectVaultDir(directRoot: File, createIfMissing: Boolean): File? {
        val vaultDir = File(directRoot, VAULT_ROOT_DIR).canonicalFile
        val expectedPrefix = directRoot.canonicalPath + File.separator
        require(vaultDir.path.startsWith(expectedPrefix)) { "非法的守护根目录" }
        if (vaultDir.isDirectory) return vaultDir
        if (vaultDir.exists()) throw IOException("路径冲突：$VAULT_ROOT_DIR 不是文件夹")
        if (!createIfMissing) return null
        if (!vaultDir.mkdirs() && !vaultDir.isDirectory) {
            throw IOException("无法创建目录 $VAULT_ROOT_DIR")
        }
        return vaultDir
    }

    private fun resolveDirectTarget(
        vaultDir: File,
        relPath: String,
        createSubdir: Boolean,
    ): Pair<File, File> {
        val target = File(vaultDir, relPath).canonicalFile
        val expectedPrefix = vaultDir.canonicalPath + File.separator
        require(target.path.startsWith(expectedPrefix)) { "守护路径越界：$relPath" }
        val parent = target.parentFile!!
        if (createSubdir && !parent.isDirectory) {
            if (parent.exists()) throw IOException("路径冲突：${parent.name} 不是文件夹")
            if (!parent.mkdirs() && !parent.isDirectory) {
                throw IOException("无法创建目录 ${parent.name}")
            }
        }
        return parent to target
    }

    private fun treeRootDocUri(treeUri: Uri): Uri {
        val rootDocId = DocumentsContract.getTreeDocumentId(treeUri)
        return DocumentsContract.buildDocumentUriUsingTree(treeUri, rootDocId)
    }

    private fun checkTreeAccess(treeUri: Uri): Map<String, Any?> {
        val directRoot = runCatching { resolveDirectRoot(treeUri) }.getOrNull()
        if (directRoot != null) {
            val rel = runCatching {
                relativeStoragePath(externalStorageRoot(), directRoot)
            }.getOrDefault("")
            val valid = isAllFilesGranted() &&
                directRoot.isDirectory &&
                directRoot.canRead() &&
                directRoot.canWrite()
            return mapOf(
                "treeUri" to treeUri.toString(),
                "displayName" to rel.ifEmpty { "内部存储" },
                "valid" to valid,
                "freeBytes" to availableStorageBytes(),
            )
        }

        val rootDoc = treeRootDocUri(treeUri)
        var displayName = "守护目录"
        var valid = false
        try {
            activity.contentResolver.query(
                rootDoc,
                arrayOf(Document.COLUMN_DISPLAY_NAME, Document.COLUMN_FLAGS),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(Document.COLUMN_DISPLAY_NAME)
                    val flagsIdx = cursor.getColumnIndex(Document.COLUMN_FLAGS)
                    if (nameIdx >= 0) {
                        displayName = cursor.getString(nameIdx)?.trim()
                            ?.ifEmpty { "守护目录" } ?: "守护目录"
                    }
                    val flags = if (flagsIdx >= 0) cursor.getInt(flagsIdx) else 0
                    val persisted = activity.contentResolver.persistedUriPermissions.any {
                        it.uri == treeUri && it.isReadPermission && it.isWritePermission
                    }
                    val canCreate = (flags and Document.FLAG_DIR_SUPPORTS_CREATE) != 0
                    valid = persisted || canCreate
                }
            }
        } catch (_: Exception) {
            valid = false
        }
        return mapOf(
            "treeUri" to treeUri.toString(),
            "displayName" to displayName,
            "valid" to valid,
            "freeBytes" to availableStorageBytes(),
        )
    }

    private fun availableStorageBytes(): Long {
        val paths = listOfNotNull(
            activity.filesDir.absolutePath,
            runCatching { Environment.getExternalStorageDirectory().absolutePath }.getOrNull(),
        )
        var bestFree = Long.MAX_VALUE
        for (path in paths) {
            val stat = runCatching { StatFs(path) }.getOrNull() ?: continue
            bestFree = minOf(bestFree, stat.availableBytes)
        }
        return if (bestFree == Long.MAX_VALUE) 0L else bestFree
    }

    private fun listChildren(treeUri: Uri, parentDocId: String): List<DocEntry> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        val entries = ArrayList<DocEntry>()
        activity.contentResolver.query(
            childrenUri,
            arrayOf(
                Document.COLUMN_DOCUMENT_ID,
                Document.COLUMN_DISPLAY_NAME,
                Document.COLUMN_MIME_TYPE,
                Document.COLUMN_SIZE,
                Document.COLUMN_LAST_MODIFIED,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndex(Document.COLUMN_DOCUMENT_ID)
            val nameIdx = cursor.getColumnIndex(Document.COLUMN_DISPLAY_NAME)
            val mimeIdx = cursor.getColumnIndex(Document.COLUMN_MIME_TYPE)
            val sizeIdx = cursor.getColumnIndex(Document.COLUMN_SIZE)
            val modIdx = cursor.getColumnIndex(Document.COLUMN_LAST_MODIFIED)
            while (cursor.moveToNext()) {
                val docId = if (idIdx >= 0) cursor.getString(idIdx).orEmpty() else ""
                val name = if (nameIdx >= 0) cursor.getString(nameIdx).orEmpty() else ""
                if (docId.isEmpty() || name.isEmpty()) continue
                val mime = if (mimeIdx >= 0) cursor.getString(mimeIdx).orEmpty() else ""
                val size = if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) cursor.getLong(sizeIdx) else 0L
                val mod = if (modIdx >= 0 && !cursor.isNull(modIdx)) cursor.getLong(modIdx) else 0L
                entries.add(
                    DocEntry(
                        uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId),
                        documentId = docId,
                        name = name,
                        isDir = mime == Document.MIME_TYPE_DIR,
                        size = size,
                        lastModified = mod,
                    ),
                )
            }
        }
        return entries
    }

    private fun findChild(treeUri: Uri, parentDocId: String, name: String): DocEntry? {
        return listChildren(treeUri, parentDocId).firstOrNull { it.name == name }
    }

    private fun ensureSubdir(treeUri: Uri, parentUri: Uri, name: String): DocEntry {
        val parentDocId = DocumentsContract.getDocumentId(parentUri)
        val existing = findChild(treeUri, parentDocId, name)
        if (existing != null) {
            if (!existing.isDir) {
                throw IOException("路径冲突：$name 不是文件夹")
            }
            return existing
        }
        val createdUri = DocumentsContract.createDocument(
            activity.contentResolver,
            parentUri,
            Document.MIME_TYPE_DIR,
            name,
        ) ?: throw IOException("无法创建目录 $name")
        val docId = DocumentsContract.getDocumentId(createdUri)
        return DocEntry(
            uri = createdUri,
            documentId = docId,
            name = name,
            isDir = true,
            size = 0L,
            lastModified = System.currentTimeMillis(),
        )
    }

    private fun findVaultSubdir(treeUri: Uri, createIfMissing: Boolean): DocEntry? {
        val rootUri = treeRootDocUri(treeUri)
        val rootDocId = DocumentsContract.getDocumentId(rootUri)
        val existing = findChild(treeUri, rootDocId, VAULT_ROOT_DIR)
        if (existing != null && existing.isDir) return existing
        if (!createIfMissing) return null
        return ensureSubdir(treeUri, rootUri, VAULT_ROOT_DIR)
    }

    private fun listVaultEntries(treeUri: Uri): Map<String, Any> {
        val directRoot = resolveDirectRoot(treeUri)
        if (directRoot != null) {
            if (!isAllFilesGranted()) {
                throw SecurityException("所有文件访问权限已失效")
            }
            val vaultDir = resolveDirectVaultDir(directRoot, createIfMissing = false)
                ?: return mapOf(
                    "exists" to false,
                    "totalBytes" to 0L,
                    "files" to emptyList<Map<String, Any>>(),
                    "staleTmpCount" to 0,
                )
            val files = ArrayList<Map<String, Any>>()
            var totalBytes = 0L
            var staleTmpCount = 0

            fun scanDirectDir(prefix: String, dir: File) {
                for (child in dir.listFiles().orEmpty()) {
                    if (child.isDirectory) {
                        if (prefix.isEmpty() && (child.name == "books" || child.name == "fonts")) {
                            scanDirectDir("${child.name}/", child)
                        }
                        continue
                    }
                    if (!child.isFile) continue
                    if (child.name.endsWith(".tmp")) {
                        staleTmpCount++
                        child.delete()
                        continue
                    }
                    val size = child.length()
                    totalBytes += size
                    files.add(
                        mapOf(
                            "relativePath" to "$prefix${child.name}",
                            "sizeBytes" to size,
                            "lastModifiedMs" to child.lastModified(),
                        ),
                    )
                }
            }

            scanDirectDir("", vaultDir)
            return mapOf(
                "exists" to true,
                "totalBytes" to totalBytes,
                "files" to files,
                "staleTmpCount" to staleTmpCount,
            )
        }

        val vaultDir = findVaultSubdir(treeUri, createIfMissing = false)
            ?: return mapOf(
                "exists" to false,
                "totalBytes" to 0L,
                "files" to emptyList<Map<String, Any>>(),
                "staleTmpCount" to 0,
            )
        val files = ArrayList<Map<String, Any>>()
        var totalBytes = 0L
        var staleTmpCount = 0

        fun scanDir(prefix: String, docId: String) {
            for (child in listChildren(treeUri, docId)) {
                if (child.isDir) {
                    if (child.name == "books" || child.name == "fonts") {
                        scanDir("${child.name}/", child.documentId)
                    }
                    continue
                }
                if (child.name.endsWith(".tmp")) {
                    staleTmpCount++
                    runCatching { DocumentsContract.deleteDocument(activity.contentResolver, child.uri) }
                    continue
                }
                val rel = "$prefix${child.name}"
                totalBytes += child.size
                files.add(
                    mapOf(
                        "relativePath" to rel,
                        "sizeBytes" to child.size,
                        "lastModifiedMs" to child.lastModified,
                    ),
                )
            }
        }

        scanDir("", vaultDir.documentId)
        return mapOf(
            "exists" to true,
            "totalBytes" to totalBytes,
            "files" to files,
            "staleTmpCount" to staleTmpCount,
        )
    }

    private fun measureVaultBytes(treeUri: Uri, excludeRelPath: String? = null): Long {
        val directRoot = resolveDirectRoot(treeUri)
        if (directRoot != null) {
            val vaultDir = resolveDirectVaultDir(directRoot, createIfMissing = false) ?: return 0L
            var total = 0L
            fun sumDirect(prefix: String, dir: File) {
                for (child in dir.listFiles().orEmpty()) {
                    if (child.isDirectory) {
                        if (prefix.isEmpty() && (child.name == "books" || child.name == "fonts")) {
                            sumDirect("${child.name}/", child)
                        }
                        continue
                    }
                    val rel = "$prefix${child.name}"
                    if (rel != excludeRelPath && !child.name.endsWith(".tmp")) {
                        total += child.length()
                    }
                }
            }
            sumDirect("", vaultDir)
            return total
        }

        val vaultDir = findVaultSubdir(treeUri, createIfMissing = false) ?: return 0L
        var total = 0L
        fun sumDir(prefix: String, docId: String) {
            for (child in listChildren(treeUri, docId)) {
                if (child.isDir) {
                    if (child.name == "books" || child.name == "fonts") {
                        sumDir("${child.name}/", child.documentId)
                    }
                    continue
                }
                val rel = "$prefix${child.name}"
                if (rel != excludeRelPath && !child.name.endsWith(".tmp")) {
                    total += child.size
                }
            }
        }
        sumDir("", vaultDir.documentId)
        return total
    }

    private fun resolveTargetParent(
        treeUri: Uri,
        relPath: String,
        createIfMissing: Boolean,
    ): Pair<DocEntry, String>? {
        val vaultDir = findVaultSubdir(treeUri, createIfMissing = createIfMissing) ?: return null
        val slash = relPath.indexOf('/')
        if (slash < 0) return vaultDir to relPath
        val subName = relPath.substring(0, slash)
        val fileName = relPath.substring(slash + 1)
        val existingSub = findChild(treeUri, vaultDir.documentId, subName)
        if (existingSub != null && existingSub.isDir) return existingSub to fileName
        if (!createIfMissing) return null
        return ensureSubdir(treeUri, vaultDir.uri, subName) to fileName
    }

    private fun streamVaultFileToCache(
        treeUri: Uri,
        relPath: String,
        maxBytes: Long,
    ): String? {
        val directRoot = resolveDirectRoot(treeUri)
        if (directRoot != null) {
            if (!isAllFilesGranted()) {
                throw SecurityException("所有文件访问权限已失效")
            }
            val vaultDir = resolveDirectVaultDir(directRoot, createIfMissing = false) ?: return null
            val (_, targetFile) = resolveDirectTarget(vaultDir, relPath, createSubdir = false)
            if (!targetFile.isFile) return null
            if (targetFile.length() > maxBytes) {
                throw IOException("守护文件体积超出安全读取上限")
            }
            val stagingDir = File(activity.cacheDir, STAGING_CACHE_DIR)
            if (!stagingDir.exists()) stagingDir.mkdirs()
            val safeBase = targetFile.name.replace(Regex("[^A-Za-z0-9_.-]"), "_")
            val outFile = File(stagingDir, "${System.currentTimeMillis()}_$safeBase")
            var total = 0L
            try {
                FileInputStream(targetFile).use { source ->
                    FileOutputStream(outFile).use { dest ->
                        val buf = ByteArray(BUFFER_BYTES)
                        while (true) {
                            if (cancelled.get() || disposed) {
                                throw IOException("读取已取消")
                            }
                            val read = source.read(buf)
                            if (read < 0) break
                            total += read
                            if (total > maxBytes) {
                                throw IOException("守护文件体积超出安全读取上限")
                            }
                            dest.write(buf, 0, read)
                        }
                        dest.flush()
                    }
                }
                return outFile.absolutePath
            } catch (error: Throwable) {
                outFile.delete()
                throw error
            }
        }

        val (parent, fileName) = resolveTargetParent(treeUri, relPath, createIfMissing = false)
            ?: return null
        val doc = findChild(treeUri, parent.documentId, fileName) ?: return null
        if (doc.isDir) return null
        if (doc.size > maxBytes) {
            throw IOException("守护文件体积超出安全读取上限")
        }
        val stagingDir = File(activity.cacheDir, STAGING_CACHE_DIR)
        if (!stagingDir.exists()) stagingDir.mkdirs()
        val safeBase = fileName.replace(Regex("[^A-Za-z0-9_.-]"), "_")
        val outFile = File(stagingDir, "${System.currentTimeMillis()}_$safeBase")
        val input = activity.contentResolver.openInputStream(doc.uri)
            ?: throw IOException("无法读取守护目录中的 $relPath")
        var total = 0L
        try {
            input.use { source ->
                FileOutputStream(outFile).use { dest ->
                    val buf = ByteArray(BUFFER_BYTES)
                    while (true) {
                        if (cancelled.get() || disposed) {
                            throw IOException("读取已取消")
                        }
                        val read = source.read(buf)
                        if (read < 0) break
                        total += read
                        if (total > maxBytes) {
                            throw IOException("守护文件体积超出安全读取上限")
                        }
                        dest.write(buf, 0, read)
                    }
                    dest.flush()
                }
            }
            return outFile.absolutePath
        } catch (error: Throwable) {
            outFile.delete()
            throw error
        }
    }

    private fun streamCacheFileToVault(
        treeUri: Uri,
        sourcePath: String,
        relPath: String,
        maxVaultBytes: Long,
    ): Long {
        val sourceFile = File(sourcePath).canonicalFile
        val cacheRoot = activity.cacheDir.canonicalFile
        val appFilesRoot = activity.filesDir.canonicalFile
        val underAppStorage =
            sourceFile.path.startsWith(cacheRoot.path + File.separator) ||
                sourceFile.path.startsWith(appFilesRoot.path + File.separator)
        require(underAppStorage && sourceFile.isFile) { "无效的同步源文件" }
        val fileSize = sourceFile.length()

        val free = availableStorageBytes()
        val requiredFree = maxOf(MIN_FREE_SPACE_FLOOR, fileSize + WRITE_HEADROOM_MARGIN)
        if (free in 1 until requiredFree) {
            throw LowSpaceException("手机可用存储空间不足（需预留至少 256 MB 安全余量），已暂停写入守护目录")
        }

        if (maxVaultBytes > 0L) {
            val currentOtherBytes = measureVaultBytes(treeUri, excludeRelPath = relPath)
            if (currentOtherBytes + fileSize > maxVaultBytes) {
                throw QuotaExceededException("已达到守护目录空间配额上限，未继续写入")
            }
        }

        val directRoot = resolveDirectRoot(treeUri)
        if (directRoot != null) {
            if (!isAllFilesGranted()) {
                throw SecurityException("所有文件访问权限已失效")
            }
            val vaultDir = resolveDirectVaultDir(directRoot, createIfMissing = true)!!
            val (parentDir, targetFile) = resolveDirectTarget(
                vaultDir,
                relPath,
                createSubdir = true,
            )
            val tmpFile = File(parentDir, "${targetFile.name}.tmp")
            if (tmpFile.exists()) tmpFile.delete()
            var wroteTmp = false
            try {
                FileOutputStream(tmpFile).use { dest ->
                    FileInputStream(sourceFile).use { src ->
                        val buf = ByteArray(BUFFER_BYTES)
                        while (true) {
                            if (cancelled.get() || disposed) {
                                throw IOException("同步已取消")
                            }
                            val read = src.read(buf)
                            if (read < 0) break
                            dest.write(buf, 0, read)
                        }
                        dest.flush()
                    }
                }
                wroteTmp = true
                if (targetFile.exists() && !targetFile.delete()) {
                    throw IOException("无法替换旧的守护文件 ${targetFile.name}")
                }
                if (!tmpFile.renameTo(targetFile)) {
                    FileOutputStream(targetFile).use { dest ->
                        FileInputStream(tmpFile).use { src ->
                            val buf = ByteArray(BUFFER_BYTES)
                            while (true) {
                                val read = src.read(buf)
                                if (read < 0) break
                                dest.write(buf, 0, read)
                            }
                            dest.flush()
                        }
                    }
                    tmpFile.delete()
                }
                wroteTmp = false
                return fileSize
            } finally {
                if (wroteTmp || tmpFile.exists()) {
                    tmpFile.delete()
                }
            }
        }

        val (parent, fileName) = resolveTargetParent(treeUri, relPath, createIfMissing = true)!!
        val resolver = activity.contentResolver
        val tmpName = "$fileName.tmp"
        findChild(treeUri, parent.documentId, tmpName)?.let { stale ->
            runCatching { DocumentsContract.deleteDocument(resolver, stale.uri) }
        }

        val mime = if (fileName.endsWith(".json")) "application/json" else "application/octet-stream"
        val tmpUri = DocumentsContract.createDocument(resolver, parent.uri, mime, tmpName)
            ?: throw IOException("无法在守护目录创建临时文件 $tmpName")

        var wroteTmp = false
        try {
            val out = resolver.openOutputStream(tmpUri, "wt")
                ?: throw IOException("无法打开守护目录写入流")
            out.use { dest ->
                FileInputStream(sourceFile).use { src ->
                    val buf = ByteArray(BUFFER_BYTES)
                    while (true) {
                        if (cancelled.get() || disposed) {
                            throw IOException("同步已取消")
                        }
                        val read = src.read(buf)
                        if (read < 0) break
                        dest.write(buf, 0, read)
                    }
                    dest.flush()
                }
            }
            wroteTmp = true

            val existing = findChild(treeUri, parent.documentId, fileName)
            if (existing != null) {
                DocumentsContract.deleteDocument(resolver, existing.uri)
            }
            val renamed = runCatching {
                DocumentsContract.renameDocument(resolver, tmpUri, fileName)
            }.getOrNull()
            if (renamed == null) {
                // Provider fallback: stream directly into the named target, then clean .tmp.
                val directUri = DocumentsContract.createDocument(resolver, parent.uri, mime, fileName)
                    ?: throw IOException("无法保存目标文件 $fileName")
                resolver.openOutputStream(directUri, "wt")?.use { dest ->
                    FileInputStream(sourceFile).use { src ->
                        val buf = ByteArray(BUFFER_BYTES)
                        while (true) {
                            val read = src.read(buf)
                            if (read < 0) break
                            dest.write(buf, 0, read)
                        }
                        dest.flush()
                    }
                } ?: throw IOException("无法写入目标文件 $fileName")
                runCatching { DocumentsContract.deleteDocument(resolver, tmpUri) }
            }
            wroteTmp = false
            return fileSize
        } finally {
            if (wroteTmp) {
                runCatching { DocumentsContract.deleteDocument(resolver, tmpUri) }
            } else {
                findChild(treeUri, parent.documentId, tmpName)?.let { leftover ->
                    runCatching { DocumentsContract.deleteDocument(resolver, leftover.uri) }
                }
            }
        }
    }

    private fun deleteVaultEntry(treeUri: Uri, relPath: String): Boolean {
        val directRoot = resolveDirectRoot(treeUri)
        if (directRoot != null) {
            if (!isAllFilesGranted()) {
                throw SecurityException("所有文件访问权限已失效")
            }
            val vaultDir = resolveDirectVaultDir(directRoot, createIfMissing = false) ?: return false
            val (_, targetFile) = resolveDirectTarget(vaultDir, relPath, createSubdir = false)
            return if (targetFile.isFile) targetFile.delete() else false
        }

        val (parent, fileName) = resolveTargetParent(treeUri, relPath, createIfMissing = false)
            ?: return false
        val target = findChild(treeUri, parent.documentId, fileName) ?: return false
        return runCatching {
            DocumentsContract.deleteDocument(activity.contentResolver, target.uri)
        }.getOrDefault(false)
    }

    private fun purgeVaultRoot(treeUri: Uri): Map<String, Any> {
        val directRoot = resolveDirectRoot(treeUri)
        if (directRoot != null) {
            if (!isAllFilesGranted()) {
                throw SecurityException("所有文件访问权限已失效")
            }
            val vaultDir = resolveDirectVaultDir(directRoot, createIfMissing = false)
                ?: return mapOf("deletedCount" to 0, "freedBytes" to 0L)
            val freed = measureVaultBytes(treeUri)
            var deletedCount = 0
            fun countFiles(dir: File): Int {
                var count = 0
                for (child in dir.listFiles().orEmpty()) {
                    count += if (child.isDirectory) countFiles(child) else 1
                }
                return count
            }
            deletedCount = countFiles(vaultDir)
            if (!vaultDir.deleteRecursively() && vaultDir.exists()) {
                throw IOException("无法清空守护目录")
            }
            return mapOf("deletedCount" to deletedCount, "freedBytes" to freed)
        }

        val vaultDir = findVaultSubdir(treeUri, createIfMissing = false)
            ?: return mapOf("deletedCount" to 0, "freedBytes" to 0L)
        val freed = measureVaultBytes(treeUri)
        var deletedCount = 0
        fun countFiles(docId: String): Int {
            var count = 0
            for (child in listChildren(treeUri, docId)) {
                count += if (child.isDir) countFiles(child.documentId) else 1
            }
            return count
        }
        deletedCount = countFiles(vaultDir.documentId)
        DocumentsContract.deleteDocument(activity.contentResolver, vaultDir.uri)
        return mapOf("deletedCount" to deletedCount, "freedBytes" to freed)
    }

    fun dispose() {
        disposed = true
        cancelled.set(true)
        cancelAbandonedCheck()
        channel.setMethodCallHandler(null)
        mainHandler.removeCallbacksAndMessages(null)
        worker.shutdownNow()
        pendingPickResult?.error("DISPOSED", "应用已关闭", null)
        pendingPickResult = null
        pendingAllFilesResult?.error("DISPOSED", "应用已关闭", null)
        pendingAllFilesResult = null
    }

    private class QuotaExceededException(message: String) : IOException(message)
    private class LowSpaceException(message: String) : IOException(message)
}
