package org.zorofin.zorofin_tv

import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var recommendations: FireRecommendations? = null
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        recommendations?.opened(intent)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        recommendations?.permissionResult(requestCode, grantResults)
    }

    private fun store(): String? {
        if (Build.MANUFACTURER.equals("Amazon", ignoreCase = true)) return "amazon"
        return try {
            packageManager.getPackageInfo("com.android.vending", 0)
            "google"
        } catch (_: android.content.pm.PackageManager.NameNotFoundException) { null }
    }

    /** TVs (including Fire TV) keep the remote layout; touch devices get the phone or tablet one. */
    private fun formFactor(): String {
        val television = getSystemService(UiModeManager::class.java)?.currentModeType ==
            Configuration.UI_MODE_TYPE_TELEVISION
        val remoteOnly = packageManager.hasSystemFeature("android.software.leanback") &&
            !packageManager.hasSystemFeature("android.hardware.touchscreen")
        return when {
            television || remoteOnly -> "tv"
            resources.configuration.smallestScreenWidthDp >= 600 -> "tablet"
            else -> "phone"
        }
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        recommendations = FireRecommendations(this, engine.dartExecutor.binaryMessenger)
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.zorofin.tv/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "playbackCapabilities" -> {
                        try { result.success(PlaybackCapabilities.read(this)) }
                        catch (_: Exception) { result.success(emptyMap<String, Any>()) }
                    }
                    "store" -> result.success(store())
                    "formFactor" -> result.success(formFactor())
                    "openUrl" -> {
                        // Web pages only (server Dashboard on phones); nothing else is launched.
                        val uri = Uri.parse(call.argument<String>("url") ?: "")
                        if (uri.scheme != "https" && uri.scheme != "http") {
                            result.success(false)
                        } else {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, uri))
                                result.success(true)
                            } catch (_: ActivityNotFoundException) { result.success(false) }
                              catch (_: SecurityException) { result.success(false) }
                        }
                    }
                    "openRating" -> {
                        val destination = when (store()) {
                            "amazon" -> Intent(Intent.ACTION_VIEW,
                                Uri.parse("amzn://apps/android?asin=B0HQBMFSRN&intent=app_update"))
                            "google" -> Intent(Intent.ACTION_VIEW,
                                Uri.parse("market://details?id=$packageName")).setPackage("com.android.vending")
                            else -> null
                        }
                        try {
                            if (destination == null) result.success(false)
                            else { startActivity(destination); result.success(true) }
                        } catch (_: ActivityNotFoundException) { result.success(false) }
                          catch (_: SecurityException) { result.success(false) }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
