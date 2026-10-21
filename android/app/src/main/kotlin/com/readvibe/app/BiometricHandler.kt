package com.readvibe.app

import android.app.Activity
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Fingerprint and face checks for the private shelf.
 *
 * Android does not let an app choose the sensor. The framework prompt accepts
 * whichever biometric the device opens to apps, so this handler only reports
 * which kinds of hardware exist and asks the system to verify. The framework
 * prompt needs no FragmentActivity, which keeps MainActivity unchanged.
 */
class BiometricHandler(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.readvibe.app/biometric")
    private var pending: MethodChannel.Result? = null
    private var cancellation: CancellationSignal? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "capabilities" -> result.success(capabilities())
                "authenticate" -> authenticate(
                    title = call.argument<String>("title").orEmpty(),
                    subtitle = call.argument<String>("subtitle"),
                    negative = call.argument<String>("negative") ?: "取消",
                    result = result,
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun capabilities(): Map<String, Any> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return mapOf(
                "supported" to false,
                "fingerprint" to false,
                "face" to false,
                "status" to "unsupported",
            )
        }
        val manager = activity.getSystemService(BiometricManager::class.java)
        val status = when {
            manager == null -> BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                manager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK)
            else -> @Suppress("DEPRECATION") manager.canAuthenticate()
        }
        // Many phones keep their face unlock to the lock screen and never
        // declare it here, so a missing feature correctly hides the option.
        val packages = activity.packageManager
        return mapOf(
            "supported" to true,
            "fingerprint" to packages.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT),
            "face" to packages.hasSystemFeature(PackageManager.FEATURE_FACE),
            "status" to when (status) {
                BiometricManager.BIOMETRIC_SUCCESS -> "ready"
                BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "notEnrolled"
                BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "noHardware"
                else -> "unavailable"
            },
        )
    }

    private fun authenticate(
        title: String,
        subtitle: String?,
        negative: String,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(mapOf("outcome" to "unavailable"))
            return
        }
        if (pending != null) {
            result.success(mapOf("outcome" to "busy"))
            return
        }
        val executor = activity.mainExecutor
        val builder = BiometricPrompt.Builder(activity)
            .setTitle(title)
            // A face match should open the shelf without an extra tap.
            .setConfirmationRequired(false)
            .setNegativeButton(negative, executor) { _, _ ->
                finish(mapOf("outcome" to "fallback"))
            }
        if (!subtitle.isNullOrBlank()) builder.setSubtitle(subtitle)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Most face unlocks are class 2. Asking for strong biometrics
            // would leave them out entirely.
            builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
        }
        val signal = CancellationSignal()
        pending = result
        cancellation = signal
        try {
            builder.build().authenticate(
                signal,
                executor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        result: BiometricPrompt.AuthenticationResult,
                    ) {
                        finish(mapOf("outcome" to "success"))
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        val outcome = when (errorCode) {
                            BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
                            BiometricPrompt.BIOMETRIC_ERROR_CANCELED,
                            BiometricPrompt.BIOMETRIC_ERROR_TIMEOUT -> "cancelled"
                            BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT,
                            BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> "lockout"
                            BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS -> "notEnrolled"
                            else -> "error"
                        }
                        finish(mapOf("outcome" to outcome, "message" to errString.toString()))
                    }
                },
            )
        } catch (error: Exception) {
            finish(mapOf("outcome" to "error", "message" to (error.message ?: "")))
        }
    }

    /** Answers the waiting call once, whichever callback arrives first. */
    private fun finish(value: Map<String, String>) {
        val waiting = pending ?: return
        pending = null
        cancellation = null
        waiting.success(value)
    }

    fun dispose() {
        cancellation?.cancel()
        finish(mapOf("outcome" to "cancelled"))
        channel.setMethodCallHandler(null)
    }
}
