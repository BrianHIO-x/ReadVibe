package com.readvibe.app

import android.app.Activity
import android.os.Build
import android.view.WindowManager
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** System bars and physical cutouts are independent of the reader's page grid. */
class ReaderWindowHandler(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.readvibe.app/reader_window")

    init {
        val window = activity.window
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setChrome" -> {
                    WindowCompat.setDecorFitsSystemWindows(window, false)
                    WindowCompat.getInsetsController(window, window.decorView).apply {
                        systemBarsBehavior =
                            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                        show(WindowInsetsCompat.Type.navigationBars())
                        if (call.argument<Boolean>("visible") != false) {
                            show(WindowInsetsCompat.Type.statusBars())
                        } else {
                            hide(WindowInsetsCompat.Type.statusBars())
                        }
                    }
                    result.success(null)
                }
                "metrics" -> {
                    val insets = ViewCompat.getRootWindowInsets(window.decorView)
                    if (insets == null) {
                        result.success(null)
                    } else {
                        val density = activity.resources.displayMetrics.density.toDouble()
                        val cutout = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
                        val bars = insets.getInsetsIgnoringVisibility(WindowInsetsCompat.Type.systemBars())
                        result.success(mapOf(
                            "cutout" to listOf(cutout.left, cutout.top, cutout.right, cutout.bottom).map { it / density },
                            "bars" to listOf(bars.left, bars.top, bars.right, bars.bottom).map { it / density },
                        ))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() = channel.setMethodCallHandler(null)
}
