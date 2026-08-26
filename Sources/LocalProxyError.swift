import Foundation

enum LocalProxyError: Error, CustomStringConvertible {
    case socketFailed(String, errno: Int32)

    var description: String {
        switch self {
        case .socketFailed(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code))) (\(code))"
        }
    }
}
