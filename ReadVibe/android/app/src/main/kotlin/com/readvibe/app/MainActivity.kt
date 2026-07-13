package com.readvibe.app

import android.app.SearchManager
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val TEXT_ACTION_CHANNEL = "com.readvibe.app/system_text_actions"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TEXT_ACTION_CHANNEL,
        ).setMethodCallHandler { call, result ->
            val text = (call.arguments as? String)?.trim().orEmpty()
            if (text.isEmpty()) {
                result.success(false)
                return@setMethodCallHandler
            }
            try {
                val launched = when (call.method) {
                    "translate" -> launchTranslation(text)
                    "search" -> launchSearch(text)
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
                result.success(launched)
            } catch (error: Exception) {
                result.error("SYSTEM_TEXT_ACTION_FAILED", error.message, null)
            }
        }
    }

    private fun launchTranslation(text: String): Boolean {
        val translateIntent = Intent(Intent.ACTION_TRANSLATE).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            putExtra(Intent.EXTRA_PROCESS_TEXT, text)
            putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
        }
        if (launchChooserIfAvailable(translateIntent, "翻译")) return true

        val processTextIntent = Intent(Intent.ACTION_PROCESS_TEXT).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_PROCESS_TEXT, text)
            putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
        }
        return launchChooserIfAvailable(processTextIntent, "翻译")
    }

    private fun launchSearch(text: String): Boolean {
        val webSearchIntent = Intent(Intent.ACTION_WEB_SEARCH).apply {
            putExtra(SearchManager.QUERY, text)
        }
        if (launchChooserIfAvailable(webSearchIntent, "搜索")) return true

        val browserIntent = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("https://www.google.com/search?q=${Uri.encode(text)}"),
        )
        return launchChooserIfAvailable(browserIntent, "搜索")
    }

    private fun launchChooserIfAvailable(intent: Intent, title: String): Boolean {
        if (intent.resolveActivity(packageManager) == null) return false
        startActivity(Intent.createChooser(intent, title))
        return true
    }
}
