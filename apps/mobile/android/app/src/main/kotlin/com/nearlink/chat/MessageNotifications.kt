package com.nearlink.chat

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Local-only generic reminders. No sender, message text, group ID or key enters
 * NotificationManager; a random per-process token routes an existing session. */
class MessageNotifications(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "nearlink/message_notifications")
    private val manager = activity.getSystemService(NotificationManager::class.java)
    private val preferences = activity.getSharedPreferences("message-reminders-v1", Activity.MODE_PRIVATE)
    private var pendingPermission: MethodChannel.Result? = null
    private val routePattern = Regex("^[A-Za-z0-9_-]{24}$")

    companion object {
        const val PERMISSION_REQUEST = 58142
        private const val CHANNEL_ID = "nearlink_messages"
        private const val OPEN_ACTION = "com.nearlink.chat.OPEN_MESSAGE_REMINDER"
        private const val TOKEN_EXTRA = "message_reminder_route"
    }

    init {
        refreshChannelLanguage()
        channel.setMethodCallHandler(::handle)
    }

    fun refreshChannelLanguage() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, AppDisplayLanguage.text(activity, "群聊消息", "Chat messages"),
                NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = AppDisplayLanguage.text(activity, "仅显示有新消息，不包含聊天正文", "New message alerts without chat content")
                setShowBadge(true)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            })
        }
    }

    private fun granted(): Boolean {
        val runtime = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        val app = Build.VERSION.SDK_INT < Build.VERSION_CODES.N || manager.areNotificationsEnabled()
        val channelEnabled = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE
        return runtime && app && channelEnabled
    }

    private fun canRequestPermission(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            (!preferences.getBoolean("prompted", false) ||
                activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))

    private fun state(): Map<String, Boolean> = mapOf(
        "enabled" to preferences.getBoolean("enabled", true),
        "granted" to granted(),
        "prompted" to (preferences.getBoolean("prompted", false) ||
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && !granted()) ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)),
        "canRequest" to canRequestPermission()
    )

    private fun clearReminders() {
        for (notice in manager.activeNotifications) {
            val tag = notice.tag ?: continue
            if (routePattern.matches(tag)) manager.cancel(tag, notice.id)
        }
    }

    private fun notificationSettings(): Intent {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelBlocked = manager.areNotificationsEnabled() &&
                manager.getNotificationChannel(CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE
            return Intent(if (channelBlocked) Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS
                else Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                if (channelBlocked) putExtra(Settings.EXTRA_CHANNEL_ID, CHANNEL_ID)
            }
        }
        return Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null))
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        when (call.method) {
            "state" -> if (call.arguments == null) result.success(state()) else invalid(result)
            "setEnabled" -> {
                val enabled = args?.get("enabled") as? Boolean
                if (args?.size != 1 || enabled == null) { invalid(result); return }
                preferences.edit().putBoolean("enabled", enabled).apply()
                if (!enabled) {
                    clearReminders()
                    result.success(state())
                } else if (canRequestPermission()) {
                    if (pendingPermission != null) {
                        result.error("NOTIFICATION_BUSY", "系统通知授权正在处理", null)
                        return
                    }
                    pendingPermission = result
                    preferences.edit().putBoolean("prompted", true).apply()
                    try {
                        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
                    } catch (_: RuntimeException) {
                        pendingPermission = null
                        preferences.edit().remove("prompted").apply()
                        result.error("NOTIFICATION_PERMISSION", "无法请求系统通知权限", null)
                    }
                } else {
                    preferences.edit().putBoolean("prompted", true).apply()
                    result.success(state())
                }
            }
            "openSettings" -> {
                if (call.arguments != null) { invalid(result); return }
                try {
                    activity.startActivity(notificationSettings())
                    result.success(null)
                } catch (_: RuntimeException) {
                    result.error("NOTIFICATION_SETTINGS", "无法打开系统通知设置", null)
                }
            }
            "show" -> {
                val token = args?.get("token") as? String
                val count = (args?.get("count") as? Number)?.toInt()
                val badge = (args?.get("badge") as? Number)?.toInt()
                val sound = args?.get("sound") as? Boolean
                if (args?.size != 4 || token == null || !routePattern.matches(token) || count == null ||
                    count <= 0 || badge == null || badge !in 0..1000000 || sound == null) {
                    invalid(result); return
                }
                if (!preferences.getBoolean("enabled", true) || !granted()) {
                    result.error("NOTIFICATION_PERMISSION", "系统未允许消息提醒", null)
                    return
                }
                val intent = Intent(activity, MainActivity::class.java).apply {
                    action = OPEN_ACTION
                    data = Uri.parse("nearlink-reminder://$token")
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    putExtra(TOKEN_EXTRA, token)
                }
                val pending = PendingIntent.getActivity(activity, 0, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Notification.Builder(activity, CHANNEL_ID)
                } else {
                    @Suppress("DEPRECATION")
                    Notification.Builder(activity)
                }
                builder.setSmallIcon(R.drawable.ic_stat_message)
                    .setContentTitle("Whisplot")
                    .setContentText(AppDisplayLanguage.text(activity, "你有新消息", "You have new messages"))
                    .setContentIntent(pending)
                    .setAutoCancel(true)
                    .setCategory(Notification.CATEGORY_MESSAGE)
                    .setVisibility(Notification.VISIBILITY_SECRET)
                    .setNumber(count.coerceAtMost(999))
                    .setOnlyAlertOnce(!sound)
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O && sound) {
                    builder.setDefaults(Notification.DEFAULT_SOUND)
                }
                try { manager.notify(token, 0, builder.build()); result.success(null) }
                catch (_: SecurityException) { result.error("NOTIFICATION_PERMISSION", "系统未允许消息提醒", null) }
            }
            "clear" -> {
                val token = args?.get("token") as? String
                val badge = (args?.get("badge") as? Number)?.toInt()
                if (args?.size != 2 || token == null || !routePattern.matches(token) ||
                    badge == null || badge !in 0..1000000) { invalid(result); return }
                manager.cancel(token, 0)
                result.success(null)
            }
            "clearAll" -> {
                if (call.arguments != null) { invalid(result); return }
                clearReminders()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        if (grantResults.isEmpty()) preferences.edit().remove("prompted").apply()
        pendingPermission?.success(state())
        pendingPermission = null
        return true
    }

    fun onNewIntent(intent: Intent) {
        if (intent.action != OPEN_ACTION) return
        val token = intent.getStringExtra(TOKEN_EXTRA) ?: return
        if (routePattern.matches(token)) channel.invokeMethod("opened", token)
    }

    fun dispose() {
        pendingPermission?.error("NOTIFICATION_CLOSED", "应用已关闭，请重新开启提醒", null)
        pendingPermission = null
        channel.setMethodCallHandler(null)
    }

    private fun invalid(result: MethodChannel.Result) =
        result.error("INVALID_ARGUMENTS", "提醒参数无效", null)
}
