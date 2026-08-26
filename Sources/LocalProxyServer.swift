import Foundation
import Synchronization

/// An HTTP proxy bound to loopback that clients point at permanently.
///
/// The whole point of this indirection is that proxy environment variables are
/// read once at process start. Flipping them on a network change never reaches
/// an already-running app, which is why editors and coding agents had to be
/// restarted. Clients instead target this fixed address for their entire life
/// and the daemon reroutes underneath them by swapping `mode`.
///
/// Built on POSIX sockets rather than Network.framework, which routes every
/// connection through the macOS system proxy setting and offers no working
/// opt-out. Since this daemon points that setting at its own listener, an
/// NWConnection "direct" dial loops back in and never reaches an origin.
final class LocalProxyServer: Sendable {
    /// How far above the preferred port to look for a free one.
    private static let portScanRange = 16

    private struct State {
        var mode: ProxyMode = .direct
        var hasResolvedMode = false
        var sessions: [UInt64: ProxySession] = [:]
        var nextSessionID: UInt64 = 0
    }

    private let preferredPort: UInt16
    private let state = Mutex(State())

    init(preferredPort: UInt16) {
        self.preferredPort = preferredPort
    }

    /// Binds the preferred port, or the next free one after it if something else
    /// already holds it. `onReady` fires once the listener is accepting, and
    /// receives the port actually bound. Callers must not publish an address to
    /// clients before that, or a failed bind would blackhole all traffic.
    func start(onReady: @escaping (UInt16) -> Void) throws {
        // Relaying to a peer that has already gone away is routine here, and the
        // default SIGPIPE disposition would kill the daemon outright.
        signal(SIGPIPE, SIG_IGN)

        var lastError = LocalProxyError.socketFailed("bind", errno: EADDRINUSE)

        for candidate in Self.candidatePorts(startingAt: preferredPort) {
            do {
                let listenFD = try bindListener(port: candidate)

                if candidate != preferredPort {
                    fputs("Local proxy port \(preferredPort) unavailable; using \(candidate)\n", stderr)
                }

                let thread = Thread { [self] in
                    acceptLoop(listenFD: listenFD)
                }
                thread.name = "local-proxy-accept"
                thread.start()

                onReady(candidate)
                return
            } catch let error as LocalProxyError {
                lastError = error
                continue
            }
        }

        throw lastError
    }

    /// The preferred port first, then a short run above it. Deliberately small:
    /// wandering far from the configured port makes the daemon harder to reason
    /// about, and a machine with this many busy ports has a different problem.
    private static func candidatePorts(startingAt preferred: UInt16) -> [UInt16] {
        var ports: [UInt16] = []
        for offset in 0..<portScanRange {
            let candidate = Int(preferred) + offset
            guard candidate <= Int(UInt16.max) else {
                break
            }
            ports.append(UInt16(candidate))
        }
        return ports
    }

    private func bindListener(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LocalProxyError.socketFailed("socket", errno: errno)
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        Self.configure(socket: fd)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw LocalProxyError.socketFailed("bind 127.0.0.1:\(port)", errno: code)
        }

        guard listen(fd, 128) == 0 else {
            let code = errno
            close(fd)
            throw LocalProxyError.socketFailed("listen", errno: code)
        }

        return fd
    }

    func setMode(_ newMode: ProxyMode) {
        // Sockets established over the previous route are already dead, but
        // client connection pools do not know that and will hand them out again.
        // Dropping them turns a confusing "socket connection was closed
        // unexpectedly" into a clean reconnect.
        let doomed: [ProxySession]? = state.withLock { state in
            // The first resolution is forced through even when it matches the
            // initial `.direct`, so the log always records the route once.
            guard !state.hasResolvedMode || newMode != state.mode else {
                return nil
            }

            let isFirstResolution = !state.hasResolvedMode
            state.hasResolvedMode = true
            state.mode = newMode

            guard !isFirstResolution else {
                return []
            }

            let active = Array(state.sessions.values)
            state.sessions.removeAll()
            return active
        }

        guard let doomed else {
            return
        }

        // Answers resolved over the previous route may not be valid on the new
        // one, so they go out with the connections that used them.
        ResolverCache.shared.removeAll()

        fputs("Local proxy route: \(newMode.description)\n", stderr)

        for session in doomed {
            session.shutdownNow()
        }
    }

    private func acceptLoop(listenFD: Int32) {
        while true {
            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(listenFD, &address, &length)

            guard clientFD >= 0 else {
                let code = errno

                if code == EINTR || code == ECONNABORTED {
                    continue
                }

                // Resource pressure clears on its own. Exiting here would take
                // every proxy-aware app on the machine down with us, so back off
                // rather than treating a transient shortage as fatal.
                if code == EMFILE || code == ENFILE || code == ENOMEM || code == ENOBUFS {
                    fputs("Local proxy accept deferred: \(String(cString: strerror(code)))\n", stderr)
                    usleep(100_000)
                    continue
                }

                fputs("Local proxy accept failed: \(String(cString: strerror(code)))\n", stderr)
                exit(1)
            }

            Self.configure(socket: clientFD)
            startSession(clientFD: clientFD)
        }
    }

    private func startSession(clientFD: Int32) {
        let session = state.withLock { state -> ProxySession in
            let id = state.nextSessionID
            state.nextSessionID &+= 1

            let session = ProxySession(id: id, clientFD: clientFD, mode: state.mode) { [weak self] finishedID in
                self?.removeSession(finishedID)
            }
            state.sessions[id] = session
            return session
        }

        session.start()
    }

    private func removeSession(_ id: UInt64) {
        _ = state.withLock { $0.sessions.removeValue(forKey: id) }
    }

    /// Shared by the listener, accepted clients and outbound dials.
    static func configure(socket fd: Int32) {
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))

        // Relay reads block indefinitely, so a peer that disappears without a
        // FIN (laptop sleep, VPN drop) would otherwise pin two threads and two
        // descriptors until the next route change. The system default idle time
        // is two hours, which is far too long to be useful here.
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var keepaliveIdleSeconds: Int32 = 120
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_KEEPALIVE, &keepaliveIdleSeconds, socklen_t(MemoryLayout<Int32>.size))
    }
}
