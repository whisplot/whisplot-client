import Foundation
import FlutterMacOS
import Security
import os
import XPC

/// A narrow bridge to one master secret and legacy item names. The Dart vault
/// owns migration and the per-run cache; this bridge never reads legacy values.
final class MacSecretVaultBridge {
  private static let service = "com.nearlink.chat"
  private static let masterAccount = "mac-vault-master-v1"
  // These belong to the native vault service, never to the legacy per-secret
  // migration. In particular, do not try to read them through a second caller.
  private static let reservedAccounts: Set<String> = [
    masterAccount, "mac-vault-master-v2", "mac-vault-master-v2-initialized",
  ]
  private static let masterSize = 32

  private let channel: FlutterMethodChannel
  private static let queue = DispatchQueue(label: "nearlink.mac-secret-vault")
  private static let accessLog = Logger(subsystem: "com.nearlink.chat", category: "VaultAccess")
  // Only touched on queue. These counters contain no key names or values and
  // distinguish app requests from multiple dialogs inside one macOS request.
  private static var interactiveReadCount = 0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "nearlink/mac_secret_vault", binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        Self.complete(
          FlutterError(code: "VAULT_UNAVAILABLE", message: "安全存储暂不可用", details: nil),
          result: result
        )
        return
      }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let method = call.method
    guard ["readMaster", "createMaster", "listLegacyKeys"].contains(method) else {
      Self.complete(FlutterMethodNotImplemented, result: result)
      return
    }
    guard call.arguments == nil else {
      Self.complete(
        FlutterError(code: "INVALID_ARGUMENTS", message: "此操作不接受参数", details: nil),
        result: result
      )
      return
    }

    // Keychain work can block on system authorization. Keep it serial and off
    // the Flutter/UI thread; preserve each original cancellation/denial status.
    Self.queue.async {
      let response: Any?
      do {
        switch method {
        case "readMaster":
          response = try Self.readMaster().map { $0.base64EncodedString() }
        case "createMaster":
          response = try Self.createMaster().base64EncodedString()
        case "listLegacyKeys":
          response = try Self.listLegacyKeys()
        default:
          response = FlutterMethodNotImplemented
        }
      } catch let error as VaultSecurityError {
        response = Self.flutterError(error.status)
      } catch {
        response = Self.flutterError(errSecInternalComponent)
      }
      Self.complete(response, result: result)
    }
  }

  private static func complete(_ response: Any?, result: @escaping FlutterResult) {
    DispatchQueue.main.async { result(response) }
  }

  private static func baseQuery() -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      // Keep the existing file-based Keychain namespace used by the app.
      kSecUseDataProtectionKeychain: false,
    ]
  }

  /// The immutable embedded service retains its Keychain code-hash partition
  /// across host-app rebuilds. Both ends validate the other party's signature.
  /// Unconfigured developer builds keep the direct bridge; configured builds
  /// fail closed if the service is unavailable, never retry via another caller.
  private static var usesStableService: Bool {
    Bundle.main.object(forInfoDictionaryKey: "HMUsesStableVaultService") as? Bool == true
  }

  private static func serviceMaster(operation: String) throws -> Data? {
    let bundleURL = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/HelloMentorVaultService.xpc")
    guard let requirement = Bundle.main.object(forInfoDictionaryKey: "HMVaultServiceSigningRequirement") as? String,
          !requirement.isEmpty,
          FileManager.default.fileExists(atPath: bundleURL.path) else {
      throw VaultSecurityError(errSecNotAvailable)
    }
    let connection = xpc_connection_create("com.nearlink.chat.VaultService", DispatchQueue.global(qos: .userInitiated))
    guard xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0 else {
      xpc_connection_cancel(connection)
      throw VaultSecurityError(errSecAuthFailed)
    }
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)
    defer { xpc_connection_cancel(connection) }
    let request = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_int64(request, "version", 1)
    xpc_dictionary_set_string(request, "operation", operation)
    let completed = DispatchSemaphore(value: 0)
    let response = VaultServiceResponse()
    xpc_connection_send_message_with_reply(connection, request, DispatchQueue.global(qos: .userInitiated)) { reply in
      response.set(reply)
      completed.signal()
    }
    // A rejected peer may not reply. Allow time for one user authorization,
    // then fail closed; never retry the same read through the legacy caller.
    guard completed.wait(timeout: .now() + 180) == .success,
          let reply = response.get() else { throw VaultSecurityError(errSecNotAvailable) }
    guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
          xpc_dictionary_get_value(reply, "version").map({ xpc_get_type($0) == XPC_TYPE_INT64 }) == true,
          xpc_dictionary_get_int64(reply, "version") == 1,
          xpc_dictionary_get_value(reply, "status").map({ xpc_get_type($0) == XPC_TYPE_INT64 }) == true else {
      throw VaultSecurityError(errSecNotAvailable)
    }
    let rawStatus = xpc_dictionary_get_int64(reply, "status")
    guard rawStatus >= Int64(Int32.min), rawStatus <= Int64(Int32.max) else {
      throw VaultSecurityError(errSecDecode)
    }
    let status = OSStatus(rawStatus)
    if operation == "readMaster" && status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw VaultSecurityError(status) }
    var size = 0
    guard xpc_dictionary_get_count(reply) == 3,
          let data = xpc_dictionary_get_data(reply, "master", &size),
          size == masterSize else { throw VaultSecurityError(errSecDecode) }
    return Data(bytes: data, count: size)
  }

  private static func readMaster(allowAuthentication: Bool = true) throws -> Data? {
    if usesStableService {
      // Service-internal persistence verification never goes through this call.
      guard allowAuthentication else { throw VaultSecurityError(errSecInternalComponent) }
      interactiveReadCount += 1
      accessLog.notice("Master service access begin; process request=\(interactiveReadCount, privacy: .public)")
      do {
        let value = try serviceMaster(operation: "readMaster")
        accessLog.notice("Master service access end; process request=\(interactiveReadCount, privacy: .public), status=0")
        return value
      } catch let error as VaultSecurityError {
        accessLog.notice("Master service access end; process request=\(interactiveReadCount, privacy: .public), status=\(error.status, privacy: .public)")
        throw error
      }
    }

    var query = baseQuery()
    query[kSecAttrAccount] = masterAccount
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    if !allowAuthentication {
      query[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
    }

    var item: CFTypeRef?
    // Exactly one secret lookup. No contains/read-all/fallback queries.
    if allowAuthentication {
      interactiveReadCount += 1
      accessLog.notice("Master access begin; process request=\(interactiveReadCount, privacy: .public)")
    }
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if allowAuthentication {
      accessLog.notice("Master access end; process request=\(interactiveReadCount, privacy: .public), status=\(status, privacy: .public)")
    }
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw VaultSecurityError(status) }
    guard let data = item as? Data, data.count == masterSize else {
      throw VaultSecurityError(errSecDecode)
    }
    return data
  }

  private static func createMaster() throws -> Data {
    if usesStableService {
      guard let value = try serviceMaster(operation: "createMaster") else {
        throw VaultSecurityError(errSecDecode)
      }
      return value
    }

    var generated = Data(count: masterSize)
    let randomStatus = generated.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, masterSize, bytes.baseAddress!)
    }
    guard randomStatus == errSecSuccess else { throw VaultSecurityError(randomStatus) }

    var attributes = baseQuery()
    attributes[kSecAttrAccount] = masterAccount
    attributes[kSecValueData] = generated
    attributes[kSecAttrLabel] = "Whisplot · 本机密钥库"
    attributes[kSecAttrDescription] = "保护此设备的身份与群密钥"
    // Default app-specific Keychain access controls remain intact. In
    // particular, do not set a custom ACL, update an existing item or delete it.
    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else { throw VaultSecurityError(status) }

    // Verify persistence without creating another authorization prompt. On any
    // failure retain the added item; an explicit retry must read that same key.
    guard let saved = try readMaster(allowAuthentication: false) else {
      throw VaultSecurityError(errSecItemNotFound)
    }
    guard saved == generated else { throw VaultSecurityError(errSecDecode) }
    return saved
  }

  private static func listLegacyKeys() throws -> [String] {
    var query = baseQuery()
    query[kSecReturnAttributes] = true
    query[kSecMatchLimit] = kSecMatchLimitAll
    query[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
    // No kSecReturnData: enumerating names must not read every legacy secret.
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw VaultSecurityError(status) }
    guard let items = result as? [[CFString: Any]] else {
      throw VaultSecurityError(errSecDecode)
    }
    var names = Set<String>()
    for item in items {
      guard let account = item[kSecAttrAccount] as? String else {
        throw VaultSecurityError(errSecDecode)
      }
      if !reservedAccounts.contains(account) { names.insert(account) }
    }
    return names.sorted()
  }

  private static func flutterError(_ status: OSStatus) -> FlutterError {
    let message = SecCopyErrorMessageString(status, nil) as String?
    return FlutterError(
      code: "Unexpected security result code",
      message: message ?? "安全存储操作失败",
      details: Int(status)
    )
  }
}

private struct VaultSecurityError: Error {
  let status: OSStatus
  init(_ status: OSStatus) { self.status = status }
}

private final class VaultServiceResponse {
  private let lock = NSLock()
  private var value: xpc_object_t?
  func set(_ reply: xpc_object_t) {
    lock.lock()
    defer { lock.unlock() }
    value = reply
  }
  func get() -> xpc_object_t? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
