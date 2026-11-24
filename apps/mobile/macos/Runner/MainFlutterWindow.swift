import Cocoa
import FlutterMacOS
import Network

class MainFlutterWindow: NSWindow {
  private static weak var existingWindow: MainFlutterWindow?
  private var networkProxyChannel: FlutterMethodChannel?
  private var networkPathChannel: FlutterEventChannel?
  private var appActionsChannel: FlutterMethodChannel?
  private var appLanguageChannel: FlutterMethodChannel?
  private var macSecretVaultBridge: MacSecretVaultBridge?
  private var messageNotifications: MessageNotifications?
  private let networkPathHandler = NetworkPathHandler()

  override func awakeFromNib() {
    Self.existingWindow = self
    isReleasedWhenClosed = false
    let flutterViewController = FlutterViewController()
    contentViewController = flutterViewController
    title = "Whisplot"
    // Best effort for legacy capture paths only. Modern macOS no longer uses
    // this restriction; the Flutter lifecycle cover hides inactive content.
    // Do not claim this blocks foreground ScreenCaptureKit or all screenshots.
    sharingType = .none
    contentMinSize = NSSize(width: 720, height: 560)
    setFrameAutosaveName("HelloMentorMainWindow")
    if !setFrameUsingName("HelloMentorMainWindow") {
      let available = screen?.visibleFrame.size ?? NSSize(width: 1280, height: 900)
      setContentSize(NSSize(
        width: min(1080, available.width - 60),
        height: min(760, available.height - 100)
      ))
      center()
    }

    // Install local notification handling before Firebase registers. Its plugin
    // preserves and forwards to an existing UNUserNotificationCenter delegate.
    messageNotifications = MessageNotifications(
      messenger: flutterViewController.engine.binaryMessenger
    )
    RegisterGeneratedPlugins(registry: flutterViewController)
    macSecretVaultBridge = MacSecretVaultBridge(
      messenger: flutterViewController.engine.binaryMessenger
    )
    let actions = FlutterMethodChannel(
      name: "nearlink/app_actions", binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    actions.setMethodCallHandler { call, result in
      guard call.method == "openUpdatePage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard call.arguments == nil,
            let url = URL(string: "https://whisplot-downloads.pages.dev/") else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "此操作不接受网址参数", details: nil))
        return
      }
      if NSWorkspace.shared.open(url) {
        result(nil)
      } else {
        result(FlutterError(code: "OPEN_UPDATE_FAILED", message: "无法打开下载页，请复制网址后打开", details: nil))
      }
    }
    appActionsChannel = actions
    let languageChannel = FlutterMethodChannel(
      name: "nearlink/app_language", binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    languageChannel.setMethodCallHandler { call, result in
      guard call.method == "setLanguage" else { result(FlutterMethodNotImplemented); return }
      guard let args = call.arguments as? [String: Any], args.count == 1,
            let language = args["language"] as? String, ["en", "zh"].contains(language) else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Unsupported display language", details: nil))
        return
      }
      UserDefaults.standard.set(language, forKey: AppDisplayLanguage.preferenceKey)
      result(nil)
    }
    appLanguageChannel = languageChannel
    let channel = FlutterMethodChannel(
      name: "nearlink/network_proxy",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "proxyForUrl" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let address = arguments["url"] as? String else {
        result(ProxyRoutingError.invalidURL.flutterError)
        return
      }
      do {
        result(try SystemProxyResolver.route(for: address))
      } catch let error as ProxyRoutingError {
        result(error.flutterError)
      } catch {
        result(ProxyRoutingError.invalidReply.flutterError)
      }
    }
    networkProxyChannel = channel
    let pathChannel = FlutterEventChannel(
      name: "nearlink/network_path",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    pathChannel.setStreamHandler(networkPathHandler)
    networkPathChannel = pathChannel

    super.awakeFromNib()
  }

  // Red close hides this same window. Keeping its Flutter engine alive retains
  // the unlocked identity, message subscriptions and drafts.
  // Command-Q / application termination still ends the process normally.
  override func close() {
    orderOut(nil)
  }

  @discardableResult
  static func restoreExistingWindow() -> Bool {
    guard let window = existingWindow else { return false }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return true
  }
}

enum AppDisplayLanguage {
  static let preferenceKey = "whisplot-display-language-v1"
  static func text(_ zh: String, _ en: String) -> String {
    UserDefaults.standard.string(forKey: preferenceKey) == "zh" ? zh : en
  }
}

private extension ProxyRoutingError {
  var flutterError: FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }
}

/// NWPath updates are route-change hints, not an Internet reachability test.
/// Keep the monitor tied to the Dart subscription and dispatch events on main.
private final class NetworkPathHandler: NSObject, FlutterStreamHandler {
  private var monitor: NWPathMonitor?
  private var generation = 0

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    cancel()
    generation += 1
    let currentGeneration = generation
    let current = NWPathMonitor()
    monitor = current
    current.pathUpdateHandler = { [weak self] path in
      let available = path.status == .satisfied
      DispatchQueue.main.async {
        guard let self = self, self.generation == currentGeneration else { return }
        events(["available": available])
      }
    }
    current.start(queue: DispatchQueue(label: "nearlink.network-path"))
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    cancel()
    return nil
  }

  private func cancel() {
    generation += 1
    monitor?.cancel()
    monitor = nil
  }

  deinit { monitor?.cancel() }
}
