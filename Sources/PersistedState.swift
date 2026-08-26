import Foundation

struct PersistedState: Codable {
    var lastNetwork: String?
    var wasProxyEnabled: Bool
    /// The port actually bound last run. Preferred on the next start so the
    /// address published to clients survives a restart; a process that captured
    /// it at launch would otherwise be stranded on the old one.
    var listenPort: UInt16?
}
