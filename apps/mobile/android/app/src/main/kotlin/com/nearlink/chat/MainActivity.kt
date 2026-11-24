package com.nearlink.chat

import io.flutter.embedding.android.FlutterActivity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var networkPathChannel: EventChannel? = null
    private var networkPathHandler: NetworkPathHandler? = null
    private var appActions: MethodChannel? = null
    private var appLanguage: MethodChannel? = null
    private var messageNotifications: MessageNotifications? = null
    private var backgroundConnection: BackgroundConnectionBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        messageNotifications = MessageNotifications(this, flutterEngine.dartExecutor.binaryMessenger)
        backgroundConnection = BackgroundConnectionBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        appLanguage = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nearlink/app_language").also { channel ->
            channel.setMethodCallHandler { call, result ->
                val args = call.arguments as? Map<*, *>
                val language = args?.get("language") as? String
                if (call.method != "setLanguage") result.notImplemented()
                else if (args?.size != 1 || language !in listOf("en", "zh")) {
                    result.error("INVALID_ARGUMENTS", "Unsupported display language", null)
                } else {
                    AppDisplayLanguage.set(this, language!!)
                    messageNotifications?.refreshChannelLanguage()
                    ConnectionForegroundService.refreshLanguage(this)
                    result.success(null)
                }
            }
        }
        val handler = NetworkPathHandler(getSystemService(ConnectivityManager::class.java))
        networkPathHandler = handler
        networkPathChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger, "nearlink/network_path"
        ).also { it.setStreamHandler(handler) }
        appActions = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nearlink/app_actions").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "openUpdatePage") {
                    result.notImplemented()
                } else if (call.arguments != null) {
                    result.error("INVALID_ARGUMENTS", "此操作不接受网址参数", null)
                } else {
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://whisplot-downloads.pages.dev/")))
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("OPEN_UPDATE_FAILED", "无法打开下载页，请复制网址后打开", null)
                    }
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        backgroundConnection?.dispose()
        backgroundConnection = null
        messageNotifications?.dispose()
        messageNotifications = null
        networkPathHandler?.onCancel(null)
        networkPathChannel?.setStreamHandler(null)
        networkPathHandler = null
        networkPathChannel = null
        appActions?.setMethodCallHandler(null)
        appActions = null
        appLanguage?.setMethodCallHandler(null)
        appLanguage = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        messageNotifications?.onNewIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        backgroundConnection?.onResume()
    }

    override fun onPause() {
        backgroundConnection?.onPause()
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (messageNotifications?.onPermissionResult(requestCode, grantResults) != true) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Protect app content in system screenshots, MediaProjection and recents.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            setRecentsScreenshotEnabled(false)
        }
    }
}

/** Route hints only. DNS, addresses, SSIDs and proxy credentials stay native. */
private class NetworkPathHandler(
    private val connectivity: ConnectivityManager
) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var generation = 0

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        onCancel(null)
        generation += 1
        val currentGeneration = generation
        fun emit() {
            main.post {
                if (generation == currentGeneration) {
                    events.success(mapOf("available" to (connectivity.activeNetwork != null)))
                }
            }
        }
        val current = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = emit()
            override fun onLost(network: Network) = emit()
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = emit()
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = emit()
        }
        callback = current
        try {
            // App minSdk is 24, where default network callbacks are available.
            connectivity.registerDefaultNetworkCallback(current)
            emit()
        } catch (_: SecurityException) {
            callback = null
            events.error("NETWORK_MONITOR_UNAVAILABLE", "无法观察系统网络变化，将定时检查连接", null)
        }
    }

    override fun onCancel(arguments: Any?) {
        generation += 1
        callback?.let {
            try { connectivity.unregisterNetworkCallback(it) } catch (_: IllegalArgumentException) {}
        }
        callback = null
    }
}
