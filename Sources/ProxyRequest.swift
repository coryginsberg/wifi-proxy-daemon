import Foundation

struct ProxyRequest {
    enum Kind {
        case connect(host: String, port: UInt16)
        case absolute(host: String, port: UInt16, originForm: String)
    }

    let kind: Kind

    init?(requestLine: String) {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else {
            return nil
        }

        let target = parts[1]

        if parts[0].uppercased() == "CONNECT" {
            guard let (host, port) = Self.splitHostPort(target, defaultPort: 443) else {
                return nil
            }
            kind = .connect(host: host, port: port)
            return
        }

        guard let absolute = Self.parseAbsoluteTarget(target) else {
            return nil
        }
        kind = .absolute(host: absolute.host, port: absolute.port, originForm: absolute.originForm)
    }

    /// Parsed by hand rather than via `URL`, whose `path` percent-decodes and
    /// would corrupt the request target on the way through.
    private static func parseAbsoluteTarget(_ target: String) -> (host: String, port: UInt16, originForm: String)? {
        guard target.lowercased().hasPrefix("http://") else {
            return nil
        }

        let rest = target[target.index(target.startIndex, offsetBy: 7)...]
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = String(rest[..<authorityEnd])
        let originForm = authorityEnd == rest.endIndex ? "/" : String(rest[authorityEnd...])

        guard let (host, port) = splitHostPort(authority, defaultPort: 80) else {
            return nil
        }

        return (host, port, originForm)
    }

    private static func splitHostPort(_ value: String, defaultPort: UInt16) -> (host: String, port: UInt16)? {
        var authority = value
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }

        guard !authority.isEmpty else {
            return nil
        }

        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else {
                return nil
            }

            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            let remainder = authority[authority.index(after: close)...]
            guard !remainder.isEmpty else {
                return (host, defaultPort)
            }
            guard remainder.hasPrefix(":"), let port = UInt16(remainder.dropFirst()) else {
                return nil
            }
            return (host, port)
        }

        guard let colon = authority.lastIndex(of: ":") else {
            return (authority, defaultPort)
        }
        guard let port = UInt16(authority[authority.index(after: colon)...]) else {
            return nil
        }
        return (String(authority[..<colon]), port)
    }
}
