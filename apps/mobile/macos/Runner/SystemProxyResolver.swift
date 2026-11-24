import CFNetwork
import Foundation

enum ProxyRoutingError: Error {
  case invalidURL
  case settingsUnavailable
  case unsupportedProxy
  case invalidReply

  var code: String {
    switch self {
    case .invalidURL: return "invalid_proxy_url"
    case .settingsUnavailable: return "system_proxy_unavailable"
    case .unsupportedProxy: return "unsupported_system_proxy"
    case .invalidReply: return "invalid_system_proxy"
    }
  }

  var message: String {
    switch self {
    case .invalidURL: return "代理查询只接受有效的 HTTP 或 HTTPS 地址。"
    case .settingsUnavailable: return "暂时无法读取 macOS 系统代理设置。"
    case .unsupportedProxy: return "此版本支持系统手动 HTTP/HTTPS 代理，暂不支持 PAC 或 SOCKS 代理。"
    case .invalidReply: return "macOS 系统代理配置无效，请检查代理地址与端口。"
    }
  }
}

/// Resolve each request with CFNetwork so system bypass rules remain authoritative.
/// This only reads settings; it never executes PAC, reads credentials, or logs URLs.
enum SystemProxyResolver {
  static func route(for address: String) throws -> String {
    let url = try validatedURL(address)
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
      throw ProxyRoutingError.settingsUnavailable
    }
    return try route(for: url, settings: settings)
  }

  static func validatedURL(_ address: String) throws -> URL {
    guard let url = URL(string: address),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty,
          url.user == nil, url.password == nil else {
      throw ProxyRoutingError.invalidURL
    }
    return url
  }

  static func route(for url: URL, settings: CFDictionary) throws -> String {
    let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue()
    guard let entries = proxies as? [[String: Any]] else {
      throw ProxyRoutingError.invalidReply
    }
    return try format(entries)
  }

  static func format(_ proxies: [[String: Any]]) throws -> String {
    guard !proxies.isEmpty else { throw ProxyRoutingError.invalidReply }
    var routes: [String] = []
    var hasHTTPProxy = false
    var hasSOCKSFallback = false
    for proxy in proxies {
      guard let type = proxy[kCFProxyTypeKey as String] as? String else {
        throw ProxyRoutingError.invalidReply
      }
      if type == kCFProxyTypeNone as String {
        routes.append("DIRECT")
        continue
      }
      if type == kCFProxyTypeSOCKS as String {
        hasSOCKSFallback = true
        continue
      }
      guard type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String else {
        // Do not silently drop an unsupported route and use a later DIRECT entry.
        throw ProxyRoutingError.unsupportedProxy
      }
      guard let host = proxy[kCFProxyHostNameKey as String] as? String,
            !host.isEmpty,
            host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            host.rangeOfCharacter(from: CharacterSet(charactersIn: ";/@?#\\")) == nil,
            let port = proxy[kCFProxyPortNumberKey as String] as? NSNumber,
            port.doubleValue == Double(port.intValue),
            (1...65535).contains(port.intValue) else {
        throw ProxyRoutingError.invalidReply
      }
      let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
      routes.append("PROXY \(authority):\(port.intValue)")
      hasHTTPProxy = true
    }
    if hasSOCKSFallback {
      // Some system proxy clients expose HTTP plus SOCKS together. HTTP remains
      // usable; do not convert an unsupported SOCKS-only route into DIRECT or
      // bypass a SOCKS fallback by selecting a later DIRECT entry.
      guard hasHTTPProxy else { throw ProxyRoutingError.unsupportedProxy }
      routes.removeAll { $0 == "DIRECT" }
    }
    return routes.joined(separator: "; ")
  }
}
