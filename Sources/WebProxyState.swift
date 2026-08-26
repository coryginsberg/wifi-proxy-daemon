import Foundation

/// The parts of a network service's proxy configuration this daemon manages.
struct WebProxyState: Equatable {
    let enabled: Bool
    let server: String
    let port: String

    init(enabled: Bool, server: String, port: String) {
        self.enabled = enabled
        self.server = server
        self.port = port
    }

    /// Parses `networksetup -getwebproxy` / `-getsecurewebproxy` output.
    init?(networksetupOutput output: String) {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        guard let enabled = fields["Enabled"] else {
            return nil
        }

        self.enabled = enabled.caseInsensitiveCompare("Yes") == .orderedSame
        self.server = fields["Server"] ?? ""
        self.port = fields["Port"] ?? ""
    }
}
