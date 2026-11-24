package com.readvibe.app

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Queries and launches controlled external text translation and search apps. */
class SystemTextActionHandler(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
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

    private val channel = MethodChannel(messenger, "com.readvibe.app/system_text_actions")

    init {
        channel.setMethodCallHandler { call, result ->
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
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("SYSTEM_TEXT_ACTION_FAILED", error.message, null)
            }
        }
    }

    private fun querySystemTextTargets(action: String?): List<Map<String, Any>> {
        val packageManager = activity.packageManager
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
                val activityInfo = info.activityInfo ?: continue
                val packageName = activityInfo.packageName.orEmpty()
                val componentName = activityInfo.name.orEmpty()
                if (packageName.isEmpty() || componentName.isEmpty()) continue
                targets.putIfAbsent(
                    packageName,
                    mapOf(
                        "id" to packageName,
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
        if (intent.resolveActivity(activity.packageManager) == null) return false
        activity.startActivity(intent)
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

    fun dispose() = channel.setMethodCallHandler(null)
}
