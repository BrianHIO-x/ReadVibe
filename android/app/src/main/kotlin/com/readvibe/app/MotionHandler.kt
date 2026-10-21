package com.readvibe.app

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import android.view.Display
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Display and power hints for animation.
 *
 * The fastest refresh rate is requested only while something on screen moves
 * and released once it rests, so a still page lets the panel drop to its idle
 * rate. Battery saver is reported so the reader can simplify its motion; the
 * system also caps the refresh rate itself while it is on.
 */
class MotionHandler(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.readvibe.app/motion")
    private val powerManager = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val powerSaveReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (powerManager.isPowerSaveMode) setHighRefreshRate(false)
            channel.invokeMethod("powerSaveModeChanged", powerManager.isPowerSaveMode)
        }
    }
    private var highRefreshRate = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setHighRefreshRate" -> {
                    setHighRefreshRate(call.argument<Boolean>("active") == true)
                    result.success(null)
                }
                "isPowerSaveMode" -> result.success(powerManager.isPowerSaveMode)
                else -> result.notImplemented()
            }
        }
        ContextCompat.registerReceiver(
            activity,
            powerSaveReceiver,
            IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    private fun setHighRefreshRate(active: Boolean) {
        val requested = active && !powerManager.isPowerSaveMode
        if (requested == highRefreshRate) return
        highRefreshRate = requested
        val modeId = if (requested) fastestModeId() else 0
        val window = activity.window
        if (window.attributes.preferredDisplayModeId == modeId) return
        window.attributes = window.attributes.apply { preferredDisplayModeId = modeId }
    }

    /**
     * The fastest mode at the current resolution, so the switch never resizes
     * the surface. Zero, meaning no preference, when that resolution offers a
     * single rate.
     */
    private fun fastestModeId(): Int {
        val display: Display = (
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                activity.display
            } else {
                @Suppress("DEPRECATION")
                activity.windowManager.defaultDisplay
            }
        ) ?: return 0
        val current = display.mode
        val sameSize = display.supportedModes.filter {
            it.physicalWidth == current.physicalWidth &&
                it.physicalHeight == current.physicalHeight
        }
        val fastest = sameSize.maxByOrNull { it.refreshRate } ?: return 0
        return if (sameSize.any { it.refreshRate < fastest.refreshRate }) fastest.modeId else 0
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        try {
            activity.unregisterReceiver(powerSaveReceiver)
        } catch (_: IllegalArgumentException) {
            // Never registered, or already gone with the activity.
        }
        setHighRefreshRate(false)
    }
}
