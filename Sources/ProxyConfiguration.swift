import Foundation

struct ProxyConfiguration {
    static let localHost = "127.0.0.1"

    /// The corporate proxy. Only the local forwarder ever talks to it.
    let host: String
    let port: Int
    /// The loopback forwarder every client is pointed at, permanently. Set to
    /// whatever port was actually bound, which is not necessarily the preferred
    /// one if something else already held it.
    var listenPort: UInt16
    let noProxy: String
    let nonProxyHosts: String

    var listenURL: String {
        "http://\(Self.localHost):\(listenPort)"
    }

    var bypassDomains: [String] {
        noProxy
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var javaProxyOptions: String {
        "-Dhttp.proxyHost=\(Self.localHost) -Dhttp.proxyPort=\(listenPort) -Dhttps.proxyHost=\(Self.localHost) -Dhttps.proxyPort=\(listenPort)"
    }

    var sbtProxyOptions: String {
        "\(javaProxyOptions) -Dhttp.nonProxyHosts=\(nonProxyHosts) -Dhttps.nonProxyHosts=\(nonProxyHosts)"
    }
}
