package org.zorofin.zorofin_tv

import android.Manifest
import android.app.Notification
import android.app.UiModeManager
import android.content.res.Configuration
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Local, opt-in Fire TV cards. No tokens or server URLs enter the launcher. */
class FireRecommendations(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "org.zorofin.tv/recommendations")
    private val manager = activity.getSystemService(NotificationManager::class.java)
    private var scope: String? = null
    private var permissionReply: MethodChannel.Result? = null
    private val available get() = Build.MANUFACTURER.equals("Amazon", ignoreCase = true) &&
        activity.getSystemService(UiModeManager::class.java).currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
    private fun permitted() = Build.VERSION.SDK_INT < 33 ||
        activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(available)
                "pending" -> { result.success(readIntent(activity.intent)); activity.intent.removeExtra("recommendationAccount"); activity.intent.removeExtra("recommendationItem") }
                "scope" -> { scope = call.arguments as? String; clear(); result.success(null) }
                "permission" -> {
                    if (!available) result.success(false)
                    else if (permitted()) result.success(true)
                    else if (permissionReply != null) result.success(false)
                    else { permissionReply = result; activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION) }
                }
                "publish" -> {
                    try { result.success(publish(call.arguments as? Map<*, *>)) }
                    catch (_: RuntimeException) { clear(); result.success(false) }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun permissionResult(code: Int, results: IntArray) {
        if (code != PERMISSION) return
        permissionReply?.success(results.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        permissionReply = null
    }

    fun opened(intent: Intent) {
        val value = readIntent(intent) ?: return
        channel.invokeMethod("open", value)
        intent.removeExtra("recommendationAccount"); intent.removeExtra("recommendationItem")
    }

    private fun readIntent(intent: Intent): Map<String, String>? {
        if (intent.action != ACTION) return null
        val account = intent.getStringExtra("recommendationAccount") ?: return null
        val item = intent.getStringExtra("recommendationItem") ?: return null
        if (account.length > 128 || item.isEmpty() || item.length > 256) return null
        return mapOf("accountId" to account, "itemId" to item)
    }

    private fun clear() { for (id in 0..4) manager.cancel(TAG, id) }

    private fun publish(arguments: Map<*, *>?): Boolean {
        val account = arguments?.get("accountId") as? String ?: return false
        if (!available || !permitted() || scope == null || account != scope) return false
        val cards = arguments["cards"] as? List<*> ?: return false
        clear()
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Zorofin recommendations", NotificationManager.IMPORTANCE_LOW))
        }
        cards.take(5).forEachIndexed { index, value ->
            val card = value as? Map<*, *> ?: return@forEachIndexed
            val item = card["itemId"] as? String ?: return@forEachIndexed
            val title = card["title"] as? String ?: return@forEachIndexed
            if (item.isEmpty() || item.length > 256) return@forEachIndexed
            val intent = Intent(activity, MainActivity::class.java).apply {
                action = ACTION
                data = Uri.Builder().scheme("zorofin-recommendation").authority("local").appendPath(account).appendPath(item).build()
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("recommendationAccount", account); putExtra("recommendationItem", item)
            }
            val pending = PendingIntent.getActivity(activity, index, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val bytes = card["image"] as? ByteArray
            val image = if (bytes != null && bytes.size <= 180000) {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                if (bounds.outWidth in 1..320 && bounds.outHeight in 1..180) BitmapFactory.decodeByteArray(bytes, 0, bytes.size) else null
            } else null
            val art = image ?: BitmapFactory.decodeResource(activity.resources, R.drawable.tv_banner)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(activity, CHANNEL) else Notification.Builder(activity)
            builder.setSmallIcon(R.drawable.ic_recommendation)
                .setContentTitle(title.take(200))
                .setContentText((card["description"] as? String ?: "Open in Zorofin").take(200))
                .setCategory(Notification.CATEGORY_RECOMMENDATION)
                .setLocalOnly(true).setOnlyAlertOnce(true).setAutoCancel(false)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setContentIntent(pending).setLargeIcon(art)
                .setStyle(Notification.BigPictureStyle().bigPicture(art))
            manager.notify(TAG, index, builder.build())
        }
        return true
    }

    companion object {
        private const val TAG = "zorofin-home"
        private const val CHANNEL = "zorofin-recommendations"
        private const val ACTION = "org.zorofin.tv.RECOMMENDATION"
        private const val PERMISSION = 4810
    }
}
