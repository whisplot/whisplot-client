import Cocoa
import FlutterMacOS
import UserNotifications

/// Native notifications accept opaque route tokens only, never chat content.
/// This is local delivery while the app is running, not an APNs background agent.
final class MessageNotifications: NSObject, UNUserNotificationCenterDelegate {
  private let channel: FlutterMethodChannel
  private let center = UNUserNotificationCenter.current()
  private let defaults = UserDefaults.standard
  private let enabledKey = "message-reminders-enabled-v1"
  private let promptedKey = "message-reminders-prompted-v1"
  private var generation = 0
  private var routeGenerations: [String: Int] = [:]
  private var requestSerial: UInt64 = 0
  private var latestIdentifiers: [String: String] = [:]
  private var enabled: Bool {
    defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "nearlink/message_notifications", binaryMessenger: messenger)
    super.init()
    center.delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      self.handle(call, result: result)
    }
  }

  private func settings(_ result: @escaping FlutterResult) {
    center.getNotificationSettings { [weak self] settings in
      DispatchQueue.main.async {
        guard let self = self else { result(nil); return }
        result([
          "enabled": self.enabled,
          "granted": settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
          "prompted": self.defaults.bool(forKey: self.promptedKey) || settings.authorizationStatus != .notDetermined,
          "canRequest": settings.authorizationStatus == .notDetermined,
        ])
      }
    }
  }

  private func token(_ value: Any?) -> String? {
    guard let text = value as? String, text.utf8.count == 24,
          text.range(of: "^[A-Za-z0-9_-]{24}$", options: .regularExpression) != nil else { return nil }
    return text
  }

  private func badge(_ value: Any?) -> Int? {
    guard let number = value as? Int, (0...1000000).contains(number) else { return nil }
    return min(number, 999)
  }

  private func setBadge(_ value: Int) {
    NSApp.dockTile.badgeLabel = value == 0 ? nil : String(value)
  }

  private func invalid(_ result: FlutterResult) {
    result(FlutterError(code: "INVALID_ARGUMENTS", message: "提醒参数无效", details: nil))
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "state":
      guard call.arguments == nil else { invalid(result); return }
      settings(result)
    case "setEnabled":
      guard let args = call.arguments as? [String: Any], args.count == 1,
            let value = args["enabled"] as? Bool else { invalid(result); return }
      defaults.set(value, forKey: enabledKey)
      if !value {
        generation += 1
        routeGenerations.removeAll()
        latestIdentifiers.removeAll()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        setBadge(0)
        settings(result)
        return
      }
      enable(result)
    case "openSettings":
      guard call.arguments == nil else { invalid(result); return }
      let workspace = NSWorkspace.shared
      let notifications = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
      if workspace.open(notifications) ||
          (workspace.urlForApplication(withBundleIdentifier: "com.apple.systempreferences")
              .map { workspace.open($0) } ?? false) {
        result(nil)
      } else {
        result(FlutterError(code: "NOTIFICATION_SETTINGS", message: "无法打开系统通知设置", details: nil))
      }
    case "show":
      guard let args = call.arguments as? [String: Any], args.count == 4,
            let route = token(args["token"]), let count = args["count"] as? Int, count > 0,
            let total = badge(args["badge"]), let sound = args["sound"] as? Bool else {
        invalid(result); return
      }
      guard enabled else { result(nil); return }
      let queuedGeneration = generation
      let queuedRouteGeneration = routeGenerations[route, default: 0]
      requestSerial &+= 1
      let identifier = "\(route)-\(requestSerial)"
      if let previous = latestIdentifiers[route] {
        center.removeDeliveredNotifications(withIdentifiers: [previous])
        center.removePendingNotificationRequests(withIdentifiers: [previous])
      }
      latestIdentifiers[route] = identifier
      let content = UNMutableNotificationContent()
      content.title = "Whisplot"
      content.body = AppDisplayLanguage.text("你有新消息", "You have new messages")
      content.userInfo = ["route": route]
      content.threadIdentifier = route
      content.badge = NSNumber(value: total)
      if sound { content.sound = .default }
      let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
      center.add(request) { [weak self] error in
        DispatchQueue.main.async {
          guard let self = self else { result(nil); return }
          guard self.enabled, self.generation == queuedGeneration,
                self.routeGenerations[route, default: 0] == queuedRouteGeneration,
                self.latestIdentifiers[route] == identifier else {
            // A cancellation may run while UserNotifications is still adding
            // the request. Do not revive its delivered alert or Dock badge.
            self.center.removeDeliveredNotifications(withIdentifiers: [identifier])
            self.center.removePendingNotificationRequests(withIdentifiers: [identifier])
            result(nil)
            return
          }
          if error != nil {
            result(FlutterError(code: "NOTIFICATION_FAILED", message: "无法显示消息提醒", details: nil))
          } else { self.setBadge(total); result(nil) }
        }
      }
    case "clear":
      guard let args = call.arguments as? [String: Any], args.count == 2,
            let route = token(args["token"]), let total = badge(args["badge"]) else {
        invalid(result); return
      }
      routeGenerations[route, default: 0] += 1
      if let identifier = latestIdentifiers.removeValue(forKey: route) {
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
      }
      setBadge(total)
      result(nil)
    case "clearAll":
      guard call.arguments == nil else { invalid(result); return }
      generation += 1
      routeGenerations.removeAll()
      latestIdentifiers.removeAll()
      center.removeAllDeliveredNotifications()
      center.removeAllPendingNotificationRequests()
      setBadge(0)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func enable(_ result: @escaping FlutterResult) {
    center.getNotificationSettings { [weak self] current in
      DispatchQueue.main.async {
        guard let self = self else { result(nil); return }
        guard self.enabled, current.authorizationStatus == .notDetermined else {
          self.settings(result)
          return
        }
        self.center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
          DispatchQueue.main.async {
            if error != nil {
              result(FlutterError(code: "NOTIFICATION_PERMISSION", message: "无法请求系统通知权限", details: nil))
            } else {
              self.defaults.set(true, forKey: self.promptedKey)
              self.settings(result)
            }
          }
        }
      }
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
      withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    // Dart has already excluded visible/read messages. Other groups may notify
    // even while the application itself is foregrounded.
    guard enabled, token(notification.request.content.userInfo["route"]) != nil else {
      completionHandler([]); return
    }
    var options: UNNotificationPresentationOptions = [.banner, .list, .badge]
    if notification.request.content.sound != nil { options.insert(.sound) }
    completionHandler(options)
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping () -> Void) {
    let route = token(response.notification.request.content.userInfo["route"])
    DispatchQueue.main.async { [weak self] in
      if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let route = route {
        MainFlutterWindow.restoreExistingWindow()
        self?.channel.invokeMethod("opened", arguments: route)
      }
      completionHandler()
    }
  }
}
