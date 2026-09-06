package com.readvibe.app

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Only verified self-upgrades from the private download directory can be shared. */
class AppUpdateHandler(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.readvibe.app/app_update")
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var disposed = false
    private var busy = false
    private val runner = BackgroundTaskRunner(worker, Executor { activity.runOnUiThread(it) }) { !disposed }

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "installApk") {
                result.notImplemented()
            } else if (busy) {
                result.error("UPDATE_BUSY", "正在检查安装包，请稍候", null)
            } else {
                busy = true
                val path = call.argument<String>("path").orEmpty()
                val version = call.argument<String>("version").orEmpty()
                runner.submit(
                    work = { validateApk(path, version) },
                    onSuccess = { file ->
                        busy = false
                        try {
                            if (!activity.packageManager.canRequestPackageInstalls()) {
                                activity.startActivity(Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:${activity.packageName}"),
                                ))
                                result.success("permissionRequired")
                            } else {
                                val uri = FileProvider.getUriForFile(
                                    activity, "${activity.packageName}.updates", file,
                                )
                                activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/vnd.android.package-archive")
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    clipData = ClipData.newRawUri("ReadVibe update", uri)
                                })
                                result.success("started")
                            }
                        } catch (error: Exception) {
                            result.error("UPDATE_INSTALL_FAILED", "无法打开安装程序或安装权限设置：${error.message}", null)
                        }
                    },
                    onError = { error ->
                        busy = false
                        result.error("UPDATE_INVALID", error.message ?: "安装包校验失败", null)
                    },
                )
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun validateApk(path: String, version: String): File {
        val file = File(path).canonicalFile
        val root = File(activity.cacheDir, "readvibe_updates").canonicalFile
        require(file.path.startsWith(root.path + File.separator) && file.isFile && file.extension == "apk") {
            "安装包不存在，请重新下载"
        }
        val manager = activity.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val installed = manager.getPackageInfo(activity.packageName, flags)
        val archive = manager.getPackageArchiveInfo(file.path, flags) ?: error("文件不是有效的 Android 安装包")
        require(archive.packageName == activity.packageName && archive.versionName == version) {
            "安装包包名或版本与更新信息不符"
        }
        val installedCode = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else installed.versionCode.toLong()
        val archiveCode = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
        require(archiveCode > installedCode) { "安装包构建号未递增，无法覆盖更新" }
        val installedSignatures = if (Build.VERSION.SDK_INT >= 28) installed.signingInfo?.apkContentsSigners else installed.signatures
        val archiveSignatures = if (Build.VERSION.SDK_INT >= 28) archive.signingInfo?.apkContentsSigners else archive.signatures
        require(!installedSignatures.isNullOrEmpty() && !archiveSignatures.isNullOrEmpty() &&
            installedSignatures.toSet() == archiveSignatures.toSet()) {
            "安装包签名与当前应用不一致，已停止安装"
        }
        return file
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }
}
