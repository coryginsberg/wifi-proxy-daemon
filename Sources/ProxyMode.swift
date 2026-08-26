import Foundation

enum ProxyMode: Equatable, CustomStringConvertible {
    case direct
    case upstream(host: String, port: UInt16)

    var description: String {
        switch self {
        case .direct:
            return "direct"
        case .upstream(let host, let port):
            return "upstream \(host):\(port)"
        }
    }
}
