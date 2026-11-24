import CFNetwork
import Foundation
import Testing

struct RunnerTests {
  @Test func systemExceptionsRemainDirect() throws {
    let settings = [
      kCFNetworkProxiesHTTPEnable as String: 1,
      kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
      kCFNetworkProxiesHTTPPort as String: 7897,
      kCFNetworkProxiesExceptionsList as String: ["localhost", "127.0.0.1"],
    ] as CFDictionary
    let local = URL(string: "http://127.0.0.1:8787/v1/groups")!
    let remote = URL(string: "http://example.com/v1/groups")!
    #expect(try SystemProxyResolver.route(for: local, settings: settings) == "DIRECT")
    #expect(try SystemProxyResolver.route(for: remote, settings: settings) == "PROXY 127.0.0.1:7897")
  }

  @Test func preservesSupportedFallbackOrderAndIPv6() throws {
    let proxy: [String: Any] = [
      kCFProxyTypeKey as String: kCFProxyTypeHTTPS,
      kCFProxyHostNameKey as String: "::1",
      kCFProxyPortNumberKey as String: 7897,
    ]
    #expect(try SystemProxyResolver.format([
      proxy, [kCFProxyTypeKey as String: kCFProxyTypeNone],
    ]) == "PROXY [::1]:7897; DIRECT")
  }

  @Test func unsupportedRoutesDoNotFallThroughToDirect() {
    for type in [kCFProxyTypeSOCKS, kCFProxyTypeAutoConfigurationURL,
                 kCFProxyTypeAutoConfigurationJavaScript] {
      #expect(throws: ProxyRoutingError.self) {
        try SystemProxyResolver.format([
          [kCFProxyTypeKey as String: type],
          [kCFProxyTypeKey as String: kCFProxyTypeNone],
        ])
      }
    }
  }

  @Test func manualHTTPSRemainsUsableWithSOCKSFallback() throws {
    #expect(try SystemProxyResolver.format([
      [kCFProxyTypeKey as String: kCFProxyTypeHTTPS,
       kCFProxyHostNameKey as String: "127.0.0.1",
       kCFProxyPortNumberKey as String: 7897],
      [kCFProxyTypeKey as String: kCFProxyTypeSOCKS],
      [kCFProxyTypeKey as String: kCFProxyTypeNone],
    ]) == "PROXY 127.0.0.1:7897")
  }

  @Test func rejectsInvalidURLAndInjectedProxy() {
    #expect(throws: ProxyRoutingError.self) {
      try SystemProxyResolver.validatedURL("file:///tmp/example")
    }
    #expect(throws: ProxyRoutingError.self) {
      try SystemProxyResolver.format([[
        kCFProxyTypeKey as String: kCFProxyTypeHTTP,
        kCFProxyHostNameKey as String: "example.com; DIRECT",
        kCFProxyPortNumberKey as String: 7897,
      ]])
    }
  }
}
