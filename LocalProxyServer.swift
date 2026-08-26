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

enum LocalProxyError: Error, CustomStringConvertible {
    case socketFailed(String, errno: Int32)

    var description: String {
        switch self {
        case .socketFailed(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code))) (\(code))"
        }
    }
}

private let maximumHeadBytes = 64 * 1024
private let relayBufferBytes = 64 * 1024
private let connectTimeout: TimeInterval = 15
private let resolverCacheTTL: TimeInterval = 60
private let resolverCacheLimit = 256
private let headTerminator = Data("\r\n\r\n".utf8)

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
final class LocalProxyServer {
    private let listenPort: UInt16
    private let stateLock = NSLock()
    private var mode: ProxyMode = .direct
    private var hasResolvedMode = false
    private var sessions: [UInt64: ProxySession] = [:]
    private var nextSessionID: UInt64 = 0
    private var listenFD: Int32 = -1

    init(listenPort: UInt16) {
        self.listenPort = listenPort
    }

    /// `onReady` fires once the listener is actually accepting. Callers must not
    /// publish the loopback address to clients before that, or a failed bind
    /// would blackhole all traffic on the machine.
    func start(onReady: @escaping () -> Void) throws {
        // Relaying to a peer that has already gone away is routine here, and the
        // default SIGPIPE disposition would kill the daemon outright.
        signal(SIGPIPE, SIG_IGN)

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
        address.sin_port = listenPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw LocalProxyError.socketFailed("bind 127.0.0.1:\(listenPort)", errno: code)
        }

        guard listen(fd, 128) == 0 else {
            let code = errno
            close(fd)
            throw LocalProxyError.socketFailed("listen", errno: code)
        }

        listenFD = fd

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "local-proxy-accept"
        thread.start()

        onReady()
    }

    func setMode(_ newMode: ProxyMode) {
        stateLock.lock()

        // The first resolution is forced through even when it matches the
        // initial `.direct`, so the log always records the route once.
        guard !hasResolvedMode || newMode != mode else {
            stateLock.unlock()
            return
        }

        let isFirstResolution = !hasResolvedMode
        hasResolvedMode = true
        mode = newMode

        // Sockets established over the previous route are already dead, but
        // client connection pools do not know that and will hand them out again.
        // Dropping them turns a confusing "socket connection was closed
        // unexpectedly" into a clean reconnect.
        var doomed: [ProxySession] = []
        if !isFirstResolution {
            doomed = Array(sessions.values)
            sessions.removeAll()
        }

        stateLock.unlock()

        // Answers resolved over the previous route may not be valid on the new
        // one, so they go out with the connections that used them.
        ResolverCache.shared.removeAll()

        fputs("Local proxy route: \(newMode.description)\n", stderr)

        for session in doomed {
            session.shutdownNow()
        }
    }

    private func acceptLoop() {
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
        stateLock.lock()
        let id = nextSessionID
        nextSessionID &+= 1
        let currentMode = mode
        let session = ProxySession(id: id, clientFD: clientFD, mode: currentMode) { [weak self] finishedID in
            self?.removeSession(finishedID)
        }
        sessions[id] = session
        stateLock.unlock()

        session.start()
    }

    private func removeSession(_ id: UInt64) {
        stateLock.lock()
        sessions.removeValue(forKey: id)
        stateLock.unlock()
    }

    fileprivate static func configure(socket fd: Int32) {
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

private struct ProxyRequest {
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

private struct ResolvedAddress {
    let family: Int32
    let socktype: Int32
    let protocolNumber: Int32
    let storage: [UInt8]
    let length: socklen_t

    init?(_ info: addrinfo) {
        guard let address = info.ai_addr, info.ai_addrlen > 0 else {
            return nil
        }

        family = info.ai_family
        socktype = info.ai_socktype
        protocolNumber = info.ai_protocol
        length = info.ai_addrlen
        storage = Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(address), count: Int(info.ai_addrlen)))
    }
}

/// Caches resolved addresses so a connection does not pay a resolver round trip.
///
/// macOS serializes `getaddrinfo` through mDNSResponder, so a burst of
/// connections queues up behind each other even when every answer is already in
/// the system cache. In upstream mode the cost is pure waste: every connection
/// re-resolves the same corporate proxy hostname.
private final class ResolverCache {
    static let shared = ResolverCache()

    private struct Entry {
        let addresses: [ResolvedAddress]
        let expiry: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func addresses(for key: String) -> [ResolvedAddress]? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else {
            return nil
        }

        guard entry.expiry > Date() else {
            entries.removeValue(forKey: key)
            return nil
        }

        return entry.addresses
    }

    func store(_ addresses: [ResolvedAddress], for key: String) {
        guard !addresses.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        // Bounded so a long-lived daemon cannot accumulate every host ever
        // visited. Wholesale eviction is fine at this size.
        if entries.count >= resolverCacheLimit {
            entries.removeAll(keepingCapacity: true)
        }

        entries[key] = Entry(addresses: addresses, expiry: Date().addingTimeInterval(resolverCacheTTL))
    }

    func invalidate(_ key: String) {
        lock.lock()
        entries.removeValue(forKey: key)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

private final class ProxySession {
    private let id: UInt64
    private let clientFD: Int32
    private let mode: ProxyMode
    private let onFinish: (UInt64) -> Void

    private let lock = NSLock()
    private var remoteFD: Int32 = -1
    private var isClosed = false
    private var isRelaying = false

    init(id: UInt64, clientFD: Int32, mode: ProxyMode, onFinish: @escaping (UInt64) -> Void) {
        self.id = id
        self.clientFD = clientFD
        self.mode = mode
        self.onFinish = onFinish
    }

    func start() {
        let thread = Thread { [weak self] in
            self?.run()
        }
        thread.name = "local-proxy-session"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Unblocks both relay directions so the session tears itself down.
    ///
    /// Runs under the lock and bails once closed. A descriptor number is reused
    /// by the kernel the moment it is freed, so shutting one down outside the
    /// lock could hit an unrelated connection that has since inherited it.
    func shutdownNow() {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else {
            return
        }

        shutdown(clientFD, SHUT_RDWR)
        if remoteFD >= 0 {
            shutdown(remoteFD, SHUT_RDWR)
        }
    }

    private func run() {
        guard let (head, headEnd) = readHead() else {
            closeAll()
            return
        }

        guard let requestLine = Self.firstRequestLine(of: head),
              let request = ProxyRequest(requestLine: requestLine) else {
            respond("400 Bad Request")
            closeAll()
            return
        }

        switch mode {
        case .upstream(let host, let port):
            // Relay the request untouched. The corporate proxy expects the
            // original CONNECT or absolute-URI form, and replaying the raw bytes
            // preserves headers such as Proxy-Authorization.
            guard let remote = openRemote(host: host, port: port) else {
                respond("502 Bad Gateway")
                closeAll()
                return
            }
            guard Self.writeFully(remote, head) else {
                closeAll()
                return
            }
            relayBothWays(remote: remote)

        case .direct:
            switch request.kind {
            case .connect(let host, let port):
                guard let remote = openRemote(host: host, port: port) else {
                    respond("502 Bad Gateway")
                    closeAll()
                    return
                }
                guard Self.writeFully(clientFD, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else {
                    closeAll()
                    return
                }
                // Clients may send the TLS ClientHello in the same segment as
                // the CONNECT rather than waiting for the 200. Those bytes are
                // already buffered and would otherwise be dropped.
                if headEnd < head.endIndex {
                    guard Self.writeFully(remote, head[headEnd...]) else {
                        closeAll()
                        return
                    }
                }
                relayBothWays(remote: remote)

            case .absolute(let host, let port, let originForm):
                guard let rewritten = Self.rewrittenHead(head, headEnd: headEnd, originForm: originForm) else {
                    respond("400 Bad Request")
                    closeAll()
                    return
                }
                guard let remote = openRemote(host: host, port: port) else {
                    respond("502 Bad Gateway")
                    closeAll()
                    return
                }
                guard Self.writeFully(remote, rewritten + head[headEnd...]) else {
                    closeAll()
                    return
                }
                relayBothWays(remote: remote)
            }
        }
    }

    private func readHead() -> (head: Data, headEnd: Data.Index)? {
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            if let terminator = head.range(of: headTerminator) {
                return (head, terminator.upperBound)
            }

            guard head.count <= maximumHeadBytes else {
                respond("431 Request Header Fields Too Large")
                return nil
            }

            let count = buffer.withUnsafeMutableBytes { read(clientFD, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            if count == 0 {
                return nil
            }

            head.append(contentsOf: buffer[0..<count])
        }
    }

    private func openRemote(host: String, port: UInt16) -> Int32? {
        guard let fd = Self.connectSocket(host: host, port: port) else {
            fputs("Local proxy could not reach \(host):\(port)\n", stderr)
            return nil
        }

        lock.lock()
        let alreadyClosed = isClosed
        if !alreadyClosed {
            remoteFD = fd
        }
        lock.unlock()

        if alreadyClosed {
            close(fd)
            return nil
        }

        return fd
    }

    private func relayBothWays(remote: Int32) {
        lock.lock()
        isRelaying = true
        lock.unlock()

        let group = DispatchGroup()
        group.enter()

        let outbound = Thread { [weak self] in
            self?.relay(from: self?.clientFD ?? -1, to: remote)
            group.leave()
        }
        outbound.name = "local-proxy-relay"
        outbound.stackSize = 512 * 1024
        outbound.start()

        relay(from: remote, to: clientFD)
        group.wait()

        closeAll()
    }

    private func relay(from source: Int32, to destination: Int32) {
        guard source >= 0, destination >= 0 else {
            return
        }

        var buffer = [UInt8](repeating: 0, count: relayBufferBytes)

        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }

            if count < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }

            if count == 0 {
                // Propagate the half-close so the peer sees a clean FIN rather
                // than waiting on a response that will never arrive.
                shutdown(destination, SHUT_WR)
                return
            }

            guard Self.writeFully(destination, buffer, count: count) else {
                return
            }
        }
    }

    private func respond(_ status: String) {
        lock.lock()
        let relaying = isRelaying
        lock.unlock()

        // Once the tunnel is live an HTTP status would be injected into the
        // caller's byte stream, so say nothing and just drop the connection.
        guard !relaying else {
            return
        }

        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = Self.writeFully(clientFD, Data(response.utf8))
    }

    private func closeAll() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true

        // Closed under the lock so a concurrent shutdownNow() cannot act on a
        // descriptor number the kernel has already handed to someone else.
        close(clientFD)
        if remoteFD >= 0 {
            close(remoteFD)
            remoteFD = -1
        }
        lock.unlock()

        onFinish(id)
    }

    private static func firstRequestLine(of head: Data) -> String? {
        guard let lineEnd = head.range(of: Data("\r\n".utf8)) else {
            return nil
        }
        return String(data: head[..<lineEnd.lowerBound], encoding: .utf8)
    }

    /// Converts the proxy-form request head to origin-form for a direct dial and
    /// drops hop-by-hop proxy headers the origin server must not see.
    ///
    /// Only this first request is ever parsed; everything after it is relayed as
    /// opaque bytes down the socket opened for this origin. A client reusing the
    /// connection for a different host would have that request silently answered
    /// by the wrong server, so reuse is refused outright.
    private static func rewrittenHead(_ head: Data, headEnd: Data.Index, originForm: String) -> Data? {
        guard let text = String(data: head[..<headEnd], encoding: .utf8) else {
            return nil
        }

        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else {
            return nil
        }

        lines[0] = "\(parts[0]) \(originForm) \(parts[2])"

        let dropped = ["proxy-connection:", "proxy-authorization:", "connection:", "keep-alive:"]
        var filtered = lines.filter { line in
            let lower = line.lowercased()
            return !dropped.contains { lower.hasPrefix($0) }
        }

        if let terminator = filtered.firstIndex(of: "") {
            filtered.insert("Connection: close", at: terminator)
        }

        return Data(filtered.joined(separator: "\r\n").utf8)
    }

    private static func connectSocket(host: String, port: UInt16) -> Int32? {
        let key = "\(host):\(port)"

        // A cached answer can go stale before its TTL expires, so a failure to
        // connect falls through to a fresh lookup rather than giving up.
        if let cached = ResolverCache.shared.addresses(for: key) {
            if let fd = connectToFirstReachable(cached) {
                return fd
            }
            ResolverCache.shared.invalidate(key)
        }

        let resolved = resolve(host: host, port: port)
        guard !resolved.isEmpty else {
            return nil
        }

        ResolverCache.shared.store(resolved, for: key)
        return connectToFirstReachable(resolved)
    }

    private static func resolve(host: String, port: UInt16) -> [ResolvedAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let list = result else {
            return []
        }
        defer { freeaddrinfo(list) }

        var addresses: [ResolvedAddress] = []
        var candidate: UnsafeMutablePointer<addrinfo>? = list
        while let info = candidate {
            if let address = ResolvedAddress(info.pointee) {
                addresses.append(address)
            }
            candidate = info.pointee.ai_next
        }

        return addresses
    }

    private static func connectToFirstReachable(_ addresses: [ResolvedAddress]) -> Int32? {
        for address in addresses {
            if let fd = tryConnect(address) {
                return fd
            }
        }
        return nil
    }

    private static func tryConnect(_ address: ResolvedAddress) -> Int32? {
        let fd = socket(address.family, address.socktype, address.protocolNumber)
        guard fd >= 0 else {
            return nil
        }

        LocalProxyServer.configure(socket: fd)

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var status = address.storage.withUnsafeBufferPointer { buffer -> Int32 in
            buffer.baseAddress!.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.connect(fd, pointer, address.length)
            }
        }

        if status != 0 && errno == EINPROGRESS {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, Int32(connectTimeout * 1000)) > 0 else {
                close(fd)
                return nil
            }

            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard socketError == 0 else {
                close(fd)
                return nil
            }

            status = 0
        }

        guard status == 0 else {
            close(fd)
            return nil
        }

        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    private static func writeFully(_ fd: Int32, _ data: Data) -> Bool {
        let bytes = [UInt8](data)
        return writeFully(fd, bytes, count: bytes.count)
    }

    private static func writeFully(_ fd: Int32, _ bytes: [UInt8], count: Int) -> Bool {
        var offset = 0

        while offset < count {
            let written = bytes.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
            }

            if written <= 0 {
                if written < 0 && errno == EINTR {
                    continue
                }
                return false
            }

            offset += written
        }

        return true
    }
}
