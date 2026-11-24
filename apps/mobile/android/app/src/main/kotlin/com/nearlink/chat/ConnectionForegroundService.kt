package com.nearlink.chat

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Supports the existing Activity's Flutter engine and its actual chat sockets.
 * It never creates an engine, loads identity material, or restarts a killed app.
 * Doze, force-stop, and vendor restrictions can still suspend networking. */
class ConnectionForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "nearlink_background_connection"
        private const val NOTIFICATION_ID = 58143
        private var requested = false
        private var generation = 0
        var running = false
            private set
        var stateChanged: (() -> Unit)? = null

        fun state(): Map<String, Boolean> = mapOf("available" to true, "running" to running)

        fun refreshLanguage(context: Context) {
            if (!running) return
            try {
                val manager = context.getSystemService(NotificationManager::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    manager.getNotificationChannel(CHANNEL_ID)?.let { channel ->
                        channel.name = AppDisplayLanguage.text(context, "后台连接", "Background connection")
                        channel.description = AppDisplayLanguage.text(context, "保持当前聊天连接，退出应用后停止", "Keeps the current chat connection until the app exits")
                        manager.createNotificationChannel(channel)
                    }
                }
                manager.activeNotifications.firstOrNull { it.id == NOTIFICATION_ID }?.let { current ->
                    manager.notify(NOTIFICATION_ID, Notification.Builder.recoverBuilder(context, current.notification)
                        .setContentTitle("Whisplot")
                        .setContentText(AppDisplayLanguage.text(context, "正在保持后台连接", "Keeping your chats connected"))
                        .setOnlyAlertOnce(true).build())
                }
            } catch (_: RuntimeException) { /* Cosmetic only; preserve the live connection. */ }
        }

        fun start(context: Context) {
            requested = true
            val requestGeneration = ++generation
            try {
                val intent = Intent(context, ConnectionForegroundService::class.java)
                    .putExtra("requestGeneration", requestGeneration)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (error: RuntimeException) {
                requested = false
                throw error
            }
        }

        fun stop(context: Context) {
            generation++
            requested = false
            running = false
            context.stopService(Intent(context, ConnectionForegroundService::class.java))
            stateChanged?.invoke()
        }
    }

    private var ownerGeneration = -1

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A task removal/engine cleanup may overtake a pending service start.
        val requestGeneration = intent?.getIntExtra("requestGeneration", -1) ?: -1
        if (!requested || stateChanged == null || requestGeneration != generation) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        ownerGeneration = requestGeneration
        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, AppDisplayLanguage.text(this, "后台连接", "Background connection"), NotificationManager.IMPORTANCE_LOW).apply {
                        description = AppDisplayLanguage.text(this@ConnectionForegroundService, "保持当前聊天连接，退出应用后停止", "Keeps the current chat connection until the app exits")
                        setShowBadge(false)
                        setSound(null, null)
                        lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                    }
                )
            }
            val open = Intent(this, MainActivity::class.java).apply {
                this.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pending = PendingIntent.getActivity(this, NOTIFICATION_ID, open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
            val notification = builder
                .setSmallIcon(R.drawable.ic_stat_message)
                .setContentTitle("Whisplot")
                .setContentText(AppDisplayLanguage.text(this, "正在保持后台连接", "Keeping your chats connected"))
                .setContentIntent(pending)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = true
            stateChanged?.invoke()
        } catch (_: RuntimeException) {
            requested = false
            running = false
            stateChanged?.invoke()
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // stopWithTask normally lets Android stop us without this callback.
        requested = false
        running = false
        generation++
        stateChanged?.invoke()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (ownerGeneration == generation) {
            requested = false
            running = false
            stateChanged?.invoke()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
        else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }
}

/** Native lifecycle admission. A new service can only start from a resumed
 * Activity; background calls can observe/stop an already-running service. */
class BackgroundConnectionBridge(
    private val activity: Activity,
    messenger: BinaryMessenger
) {
    private val channel = MethodChannel(messenger, "nearlink/background_connection")
    private val main = Handler(Looper.getMainLooper())
    private var resumed = false
    private var disposed = false
    private var pendingStart: MethodChannel.Result? = null
    private var timeout: Runnable? = null
    private val listener: () -> Unit = {
        if (!disposed) {
            val state = ConnectionForegroundService.state()
            channel.invokeMethod("changed", state)
            finishStart(state)
        }
    }

    init {
        ConnectionForegroundService.stateChanged = listener
        channel.setMethodCallHandler { call, result ->
            val arguments = call.arguments as? Map<*, *>
            when (call.method) {
                "state" -> if (call.arguments == null) result.success(ConnectionForegroundService.state())
                    else invalid(result)
                "setEnabled" -> {
                    val enabled = arguments?.get("enabled") as? Boolean
                    if (arguments?.size != 1 || enabled == null) invalid(result)
                    else if (!enabled) {
                        ConnectionForegroundService.stop(activity)
                        result.success(ConnectionForegroundService.state())
                    } else if (ConnectionForegroundService.running) {
                        result.success(ConnectionForegroundService.state())
                    } else if (!resumed || activity.isFinishing || activity.isDestroyed) {
                        result.error("BACKGROUND_START_UNAVAILABLE", "请在应用前台开启后台连接", null)
                    } else if (pendingStart != null) {
                        result.error("BACKGROUND_START_BUSY", "后台连接正在开启", null)
                    } else {
                        pendingStart = result
                        try {
                            ConnectionForegroundService.start(activity)
                            timeout = Runnable {
                                val pending = pendingStart
                                pendingStart = null
                                ConnectionForegroundService.stop(activity)
                                pending?.error("BACKGROUND_START_TIMEOUT", "后台连接未能启动", null)
                            }.also { main.postDelayed(it, 4000) }
                        } catch (_: RuntimeException) {
                            pendingStart = null
                            result.error("BACKGROUND_START_UNAVAILABLE", "系统暂未允许后台连接", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun finishStart(state: Map<String, Boolean>) {
        timeout?.let(main::removeCallbacks)
        timeout = null
        val pending = pendingStart
        pendingStart = null
        pending?.success(state)
    }

    fun onResume() { resumed = true }
    fun onPause() { resumed = false }

    fun dispose() {
        if (disposed) return
        disposed = true
        resumed = false
        timeout?.let(main::removeCallbacks)
        timeout = null
        pendingStart?.error("BACKGROUND_CLOSED", "应用已关闭", null)
        pendingStart = null
        channel.setMethodCallHandler(null)
        if (ConnectionForegroundService.stateChanged === listener) {
            ConnectionForegroundService.stateChanged = null
            ConnectionForegroundService.stop(activity)
        }
    }

    private fun invalid(result: MethodChannel.Result) =
        result.error("INVALID_ARGUMENTS", "后台连接参数无效", null)
}
