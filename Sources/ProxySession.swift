import Foundation
import Synchronization

final class ProxySession: Sendable {
    private static let maximumHeadBytes = 64 * 1024
    private static let relayBufferBytes = 64 * 1024
    private static let connectTimeout: TimeInterval = 15
    private static let headTerminator = Data("\r\n\r\n".utf8)

    /// Teardown state. Reaching a descriptor requires holding the lock, so a
    /// `shutdown()` cannot race the `close()` that frees the same number.
    private struct State {
        var remoteFD: Int32 = -1
        var isClosed = false
        var isRelaying = false
    }

    private let id: UInt64
    private let clientFD: Int32
    private let mode: ProxyMode
    private let onFinish: @Sendable (UInt64) -> Void
    private let state = Mutex(State())

    init(id: UInt64, clientFD: Int32, mode: ProxyMode, onFinish: @escaping @Sendable (UInt64) -> Void) {
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
    /// A descriptor number is reused by the kernel the moment it is freed, so
    /// this bails once closed rather than shutting down a number an unrelated
    /// connection has since inherited.
    func shutdownNow() {
        state.withLock { state in
            guard !state.isClosed else {
                return
            }

            shutdown(clientFD, SHUT_RDWR)
            if state.remoteFD >= 0 {
                shutdown(state.remoteFD, SHUT_RDWR)
            }
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
            if let terminator = head.range(of: Self.headTerminator) {
                return (head, terminator.upperBound)
            }

            guard head.count <= Self.maximumHeadBytes else {
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

        let alreadyClosed = state.withLock { state -> Bool in
            guard !state.isClosed else {
                return true
            }
            state.remoteFD = fd
            return false
        }

        if alreadyClosed {
            close(fd)
            return nil
        }

        return fd
    }

    private func relayBothWays(remote: Int32) {
        state.withLock { $0.isRelaying = true }

        let group = DispatchGroup()
        group.enter()

        let client = clientFD
        let outbound = Thread { [self] in
            relay(from: client, to: remote)
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

        var buffer = [UInt8](repeating: 0, count: Self.relayBufferBytes)

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
        // Once the tunnel is live an HTTP status would be injected into the
        // caller's byte stream, so say nothing and just drop the connection.
        guard !state.withLock({ $0.isRelaying }) else {
            return
        }

        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = Self.writeFully(clientFD, Data(response.utf8))
    }

    private func closeAll() {
        // Closed under the lock so a concurrent shutdownNow() cannot act on a
        // descriptor number the kernel has already handed to someone else.
        let alreadyClosed = state.withLock { state -> Bool in
            guard !state.isClosed else {
                return true
            }
            state.isClosed = true

            close(clientFD)
            if state.remoteFD >= 0 {
                close(state.remoteFD)
                state.remoteFD = -1
            }
            return false
        }

        guard !alreadyClosed else {
            return
        }

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
            guard poll(&descriptor, 1, Int32(Self.connectTimeout * 1000)) > 0 else {
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
