import CoreWLAN
import Foundation
import SystemConfiguration

/// Confined to the main thread: it owns the run loop the SCDynamicStore
/// notifications arrive on, so its state needs no lock of its own.
@MainActor
final class WiFiProxyController {
    /// Ceiling on any helper process this daemon shells out to.
    private static let commandTimeout: TimeInterval = 15

    private let domainMatch: String
    private let stateFileURL: URL
    private let notificationTitle: String
    private let vpnMatch: String
    private let notifierAppPath: String
    private var proxyConfiguration: ProxyConfiguration
    private let localProxy: LocalProxyServer
    private var lastNetwork: String?
    private var wasProxyEnabled: Bool
    private var hasReconciledState = false
    private let evaluationDebounceInterval: TimeInterval = 2.5
    private var pendingEvaluation: DispatchWorkItem?
    private var isEvaluating = false

    init() {
        let environment = ProcessInfo.processInfo.environment
        self.domainMatch = environment["WIFI_PROXY_DOMAIN_MATCH"] ?? "cat.com"
        self.stateFileURL = URL(fileURLWithPath: environment["WIFI_PROXY_STATE_FILE"] ?? "/var/run/wifi-proxy-daemon.state")
        self.notificationTitle = environment["WIFI_PROXY_NOTIFICATION_TITLE"] ?? "Wi-Fi Proxy"
        self.vpnMatch = environment["WIFI_PROXY_VPN_MATCH"] ?? "Cisco Secure Client"
        self.notifierAppPath = environment["WIFI_PROXY_NOTIFIER_APP"] ?? "/Applications/Utilities/WiFiProxyNotifier.app"
        let proxyHost = environment["WIFI_PROXY_HOST"] ?? "proxy.cat.com"
        let proxyPort = Int(environment["WIFI_PROXY_PORT"] ?? "80") ?? 80
        let configuredListenPort = UInt16(environment["WIFI_PROXY_LISTEN_PORT"] ?? "3128") ?? 3128
        let noProxy = environment["WIFI_PROXY_NO_PROXY"] ?? "localhost,127.0.0.1,::1,.cat.com,169.254.169.254"
        let nonProxyHosts = environment["WIFI_PROXY_NON_PROXY_HOSTS"] ?? "*.cat.com|localhost|127.0.0.1|::1"
        self.proxyConfiguration = ProxyConfiguration(
            host: proxyHost,
            port: proxyPort,
            listenPort: configuredListenPort,
            noProxy: noProxy,
            nonProxyHosts: nonProxyHosts
        )
        let state = Self.loadState(from: stateFileURL)
        self.lastNetwork = state.lastNetwork
        self.wasProxyEnabled = state.wasProxyEnabled

        // Reuse last run's port when there was one, so the address clients read
        // at launch does not move under them across a daemon restart.
        self.localProxy = LocalProxyServer(preferredPort: state.listenPort ?? configuredListenPort)
    }

    /// `publishConfiguration: false` runs the forwarder and network detection
    /// without touching system proxy settings, launchd env, the shell file, or
    /// git config. Lets the proxy be exercised without root or side effects.
    func run(publishConfiguration: Bool = true) {
        do {
            // Managed configuration is published only after the listener is
            // confirmed accepting. Pointing clients at a loopback port that
            // never bound would blackhole every request on the machine.
            try localProxy.start { [weak self] boundPort in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }

                    // Publish whatever port was actually bound, and remember it
                    // so the next start prefers the same one.
                    self.proxyConfiguration.listenPort = boundPort

                    if publishConfiguration {
                        self.applyManagedConfiguration(enabled: true)
                    }
                    self.evaluateProxyState()
                }
            }
        } catch {
            fputs("Failed to start local proxy: \(error)\n", stderr)

            // Every proxy setting on this machine may already point at the
            // listener from an earlier successful run, and those settings
            // survive reboots. Leaving them in place while the listener is dead
            // takes the whole machine offline, with no network to look up a fix.
            // Fail open instead: revert to direct and let launchd retry.
            if publishConfiguration {
                applyManagedConfiguration(enabled: false)
            }

            exit(1)
        }

        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else {
                return
            }

            let controller = Unmanaged<WiFiProxyController>.fromOpaque(info).takeUnretainedValue()
            controller.scheduleEvaluation()
        }

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let store = SCDynamicStoreCreate(nil, "com.ginsbc.wifi-proxy-daemon" as CFString, callback, &context) else {
            fputs("Failed to create SCDynamicStore.\n", stderr)
            exit(1)
        }

        let watchedKeys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6"
        ] as CFArray
        let watchedPatterns = [
            "State:/Network/Interface/.*/AirPort",
            "State:/Network/Interface/.*/IPv4",
            "State:/Network/Interface/.*/IPv6"
        ] as CFArray

        guard SCDynamicStoreSetNotificationKeys(store, watchedKeys, watchedPatterns) else {
            fputs("Failed to subscribe to network notifications.\n", stderr)
            exit(1)
        }

        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            fputs("Failed to create run loop source.\n", stderr)
            exit(1)
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        CFRunLoopRun()
    }

    /// Prints the detected network state without touching any configuration.
    func reportState() {
        let matchedNetwork = currentMatchingNetwork()
        let vpnConnection = currentVPNConnection()
        let shouldEnableProxy = matchedNetwork != nil || vpnConnection != nil
        let route = shouldEnableProxy ? "upstream \(proxyConfiguration.host):\(proxyConfiguration.port)" : "direct"

        print("listener: \(proxyConfiguration.listenURL) (preferred; falls back if taken)")
        print("route:    \(route)")
        print("network:  \(matchedNetwork ?? "-")")
        print("vpn:      \(vpnConnection ?? "-")")
    }

    /// Strips every managed setting. Used by install for a clean baseline and by
    /// uninstall, which must not leave the machine pointing at a loopback port
    /// that no longer has anything listening on it.
    func reset() {
        applyManagedConfiguration(enabled: false)
        try? FileManager.default.removeItem(at: stateFileURL)
    }

    // Collapse bursts of network-change notifications into a single settled
    // evaluation. Rapid IPv4/IPv6/AirPort churn during a network transition can
    // momentarily hide the corporate DNS domain; evaluating mid-transition made
    // the proxy state (and its notification) flap.
    private func scheduleEvaluation() {
        pendingEvaluation?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.evaluateProxyState()
        }
        pendingEvaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + evaluationDebounceInterval, execute: work)
    }

    private func evaluateProxyState() {
        // Re-entrant because applyManagedConfiguration and sendNotification run
        // nested run loops that service the main queue. Reschedule rather than
        // return, or the network change that triggered this is lost outright.
        if isEvaluating {
            scheduleEvaluation()
            return
        }
        isEvaluating = true
        defer { isEvaluating = false }

        let matchedNetwork = currentMatchingNetwork()
        let vpnConnection = currentVPNConnection()
        let shouldEnableProxy = matchedNetwork != nil || vpnConnection != nil
        let isInitialEvaluation = !hasReconciledState
        let stateChanged = shouldEnableProxy != wasProxyEnabled

        // The only thing a network change touches. Client-visible configuration
        // is static, so nothing has to be restarted to pick this up.
        localProxy.setMode(
            shouldEnableProxy
                ? .upstream(host: proxyConfiguration.host, port: UInt16(proxyConfiguration.port))
                : .direct
        )

        // A restart that finds the proxy already in its persisted state stays silent.
        if stateChanged {
            let subtitle = shouldEnableProxy ? "Proxy enabled" : "Proxy disabled"
            sendNotification(subtitle: subtitle, message: notificationMessage(network: matchedNetwork, vpnConnection: vpnConnection))
        }

        // The `isInitialEvaluation` term forces one write on every startup even
        // when nothing changed. `restart-proxy` detects completion by watching
        // this file's mtime and would hang without it.
        if isInitialEvaluation || matchedNetwork != lastNetwork || stateChanged {
            lastNetwork = matchedNetwork
            wasProxyEnabled = shouldEnableProxy
            hasReconciledState = true
            persistState(PersistedState(
                lastNetwork: matchedNetwork,
                wasProxyEnabled: shouldEnableProxy,
                listenPort: proxyConfiguration.listenPort
            ))
        }
    }

    private func currentMatchingNetwork() -> String? {
        if let override = ProcessInfo.processInfo.environment["WIFI_PROXY_TEST_NETWORK"] {
            return override.isEmpty ? nil : override
        }

        let needle = domainMatch.lowercased()
        guard !needle.isEmpty else {
            return nil
        }

        // macOS gates the Wi-Fi SSID behind Location Services, which a root
        // LaunchDaemon cannot obtain (CoreWLAN returns nil and ipconfig prints
        // "<redacted>"). The DHCP/resolver domain is not gated, so match the
        // corporate network by its DNS domain instead.
        for domain in currentNetworkDomains() where domain.lowercased().contains(needle) {
            return domain
        }

        return nil
    }

    private func currentNetworkDomains() -> [String] {
        var domains: [String] = []

        for interfaceName in wifiInterfaceNames() {
            if let output = processOutput(
                executablePath: "/usr/sbin/ipconfig",
                arguments: ["getsummary", interfaceName],
                errorPrefix: "Failed to read network summary for \(interfaceName)"
            ) {
                domains.append(contentsOf: Self.parseDomains(fromIpconfigSummary: output))
            }
        }

        if let output = processOutput(
            executablePath: "/usr/sbin/scutil",
            arguments: ["--dns"],
            errorPrefix: "Failed to read DNS configuration"
        ) {
            domains.append(contentsOf: Self.parseDomains(fromScutilDNS: output))
        }

        return domains
    }

    private func wifiInterfaceNames() -> [String] {
        var names: [String] = []

        for interface in CWWiFiClient.shared().interfaces() ?? [] {
            if let name = interface.interfaceName, !name.isEmpty {
                names.append(name)
            }
        }

        if names.isEmpty {
            names.append("en0")
        }

        return names
    }

    private static func parseDomains(fromIpconfigSummary output: String) -> [String] {
        var domains: [String] = []

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Format: "domain_name (string): mw.na.cat.com"
            guard line.hasPrefix("domain_name "), let range = line.range(of: "): ") else {
                continue
            }

            let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                domains.append(value)
            }
        }

        return domains
    }

    private static func parseDomains(fromScutilDNS output: String) -> [String] {
        var domains: [String] = []

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Formats: "domain : example.com" and "search domain[0] : example.com"
            guard line.hasPrefix("domain ") || line.hasPrefix("search domain[") else {
                continue
            }

            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }

            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                domains.append(value)
            }
        }

        return domains
    }

    private static func loadState(from stateFileURL: URL) -> PersistedState {
        guard let data = try? Data(contentsOf: stateFileURL) else {
            return PersistedState(lastNetwork: nil, wasProxyEnabled: false, listenPort: nil)
        }

        if let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            return state
        }

        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return PersistedState(lastNetwork: value.isEmpty ? nil : value, wasProxyEnabled: false, listenPort: nil)
    }

    private func persistState(_ state: PersistedState) {
        do {
            let payload = try JSONEncoder().encode(state)
            try payload.write(to: stateFileURL, options: .atomic)
        } catch {
            fputs("Failed to persist state: \(error)\n", stderr)
        }
    }

    private func notificationMessage(network: String?, vpnConnection: String?) -> String {
        if let vpnConnection {
            return "VPN connected: \(vpnConnection)"
        }

        if let network, !network.isEmpty {
            return "Corporate network: \(network)"
        }

        return "Corporate network or VPN no longer detected"
    }

    private func currentVPNConnection() -> String? {
        let overrideKey = "WIFI_PROXY_TEST_VPN"
        if let overriddenVPN = ProcessInfo.processInfo.environment[overrideKey] {
            return overriddenVPN.isEmpty ? nil : overriddenVPN
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--nc", "list"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            fputs("Failed to inspect VPN connections: \(error)\n", stderr)
            return nil
        }

        let deadline = Date().addingTimeInterval(Self.commandTimeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        let normalizedMatch = vpnMatch.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        for line in output.split(separator: "\n") {
            let text = String(line)
            let normalizedText = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard normalizedText.contains("(connected)"), normalizedText.contains(normalizedMatch) else {
                continue
            }

            if let serviceName = Self.extractQuotedName(from: text) {
                return serviceName
            }

            return text.trimmingCharacters(in: .whitespaces)
        }

        return nil
    }

    /// Publishes (or strips) the loopback forwarder address across every surface
    /// clients read at startup. Called once when the listener comes up, and
    /// again with `false` on reset. Never on a network change.
    private func applyManagedConfiguration(enabled: Bool) {
        updateSystemProxy(enabled: enabled)

        guard let consoleUser = Self.consoleUser() else {
            return
        }

        updateLaunchdEnvironment(for: consoleUser, enabled: enabled)
        updateGitProxy(for: consoleUser, enabled: enabled)
    }

    private func updateSystemProxy(enabled: Bool) {
        let listenPort = String(proxyConfiguration.listenPort)

        for service in networkServices() {
            if enabled {
                runProcess(
                    executablePath: "/usr/sbin/networksetup",
                    arguments: ["-setwebproxy", service, ProxyConfiguration.localHost, listenPort],
                    errorPrefix: "Failed to set web proxy for \(service)"
                )
                runProcess(
                    executablePath: "/usr/sbin/networksetup",
                    arguments: ["-setsecurewebproxy", service, ProxyConfiguration.localHost, listenPort],
                    errorPrefix: "Failed to set secure web proxy for \(service)"
                )
                runProcess(
                    executablePath: "/usr/sbin/networksetup",
                    arguments: ["-setwebproxystate", service, "on"],
                    errorPrefix: "Failed to enable web proxy for \(service)"
                )
                runProcess(
                    executablePath: "/usr/sbin/networksetup",
                    arguments: ["-setsecurewebproxystate", service, "on"],
                    errorPrefix: "Failed to enable secure web proxy for \(service)"
                )

                let bypassArguments = ["-setproxybypassdomains", service] + proxyConfiguration.bypassDomains
                runProcess(
                    executablePath: "/usr/sbin/networksetup",
                    arguments: bypassArguments,
                    errorPrefix: "Failed to set bypass domains for \(service)"
                )
            } else {
                runProcess(
                    executablePath: "/usr/sbin/networksetup",
                    arguments: ["-setwebproxystate", service, "off"],
                    errorPrefix: "Failed to disable web proxy for \(service)"
                )
                runProcess(
                    executablePath: "/usr/sbin/networksetup",
                    arguments: ["-setsecurewebproxystate", service, "off"],
                    errorPrefix: "Failed to disable secure web proxy for \(service)"
                )
                runProcess(
                    executablePath: "/usr/sbin/networksetup",
                    arguments: ["-setproxybypassdomains", service, "Empty"],
                    errorPrefix: "Failed to clear bypass domains for \(service)"
                )
            }
        }
    }

    private func networkServices() -> [String] {
        guard let output = processOutput(
            executablePath: "/usr/sbin/networksetup",
            arguments: ["-listallnetworkservices"],
            errorPrefix: "Failed to list network services"
        ) else {
            return ["Wi-Fi"]
        }

        return output
            .split(separator: "\n")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("An asterisk") }
            .filter { !$0.hasPrefix("*") }
    }

    private func updateLaunchdEnvironment(for consoleUser: ConsoleUser, enabled: Bool) {
        let environment = launchdEnvironmentEntries(enabled: enabled)

        for (name, value) in environment {
            let arguments: [String]
            if let value {
                arguments = ["asuser", String(consoleUser.uid), "/bin/launchctl", "setenv", name, value]
            } else {
                arguments = ["asuser", String(consoleUser.uid), "/bin/launchctl", "unsetenv", name]
            }

            runProcess(
                executablePath: "/bin/launchctl",
                arguments: arguments,
                errorPrefix: "Failed to update launchd environment for \(name)"
            )
        }
    }

    private func launchdEnvironmentEntries(enabled: Bool) -> [(String, String?)] {
        if enabled {
            return [
                ("ALL_PROXY", proxyConfiguration.listenURL),
                ("all_proxy", proxyConfiguration.listenURL),
                ("HTTP_PROXY", proxyConfiguration.listenURL),
                ("http_proxy", proxyConfiguration.listenURL),
                ("HTTPS_PROXY", proxyConfiguration.listenURL),
                ("https_proxy", proxyConfiguration.listenURL),
                ("NO_PROXY", proxyConfiguration.noProxy),
                ("no_proxy", proxyConfiguration.noProxy),
                ("JAVA_OPTS", proxyConfiguration.javaProxyOptions),
                ("java_opts", proxyConfiguration.javaProxyOptions),
                ("ES_JAVA_OPTS", proxyConfiguration.javaProxyOptions),
                ("SBT_OPTS", proxyConfiguration.sbtProxyOptions),
                ("sbt_opts", proxyConfiguration.sbtProxyOptions)
            ]
        }

        return [
            ("ALL_PROXY", nil),
            ("all_proxy", nil),
            ("HTTP_PROXY", nil),
            ("http_proxy", nil),
            ("HTTPS_PROXY", nil),
            ("https_proxy", nil),
            ("NO_PROXY", nil),
            ("no_proxy", nil),
            ("JAVA_OPTS", nil),
            ("java_opts", nil),
            ("ES_JAVA_OPTS", nil),
            ("SBT_OPTS", nil),
            ("sbt_opts", nil)
        ]
    }

    private func updateGitProxy(for consoleUser: ConsoleUser, enabled: Bool) {
        if enabled {
            runProcess(
                executablePath: "/usr/bin/sudo",
                arguments: ["-H", "-u", consoleUser.name, "/usr/bin/git", "config", "--global", "http.proxy", proxyConfiguration.listenURL],
                errorPrefix: "Failed to set git http proxy"
            )
            runProcess(
                executablePath: "/usr/bin/sudo",
                arguments: ["-H", "-u", consoleUser.name, "/usr/bin/git", "config", "--global", "https.proxy", proxyConfiguration.listenURL],
                errorPrefix: "Failed to set git https proxy"
            )
        } else {
            runProcess(
                executablePath: "/usr/bin/sudo",
                arguments: ["-H", "-u", consoleUser.name, "/usr/bin/git", "config", "--global", "--unset", "http.proxy"],
                errorPrefix: "Failed to unset git http proxy"
            )
            runProcess(
                executablePath: "/usr/bin/sudo",
                arguments: ["-H", "-u", consoleUser.name, "/usr/bin/git", "config", "--global", "--unset", "https.proxy"],
                errorPrefix: "Failed to unset git https proxy"
            )
        }
    }

    private func processOutput(executablePath: String, arguments: [String], errorPrefix: String) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            fputs("\(errorPrefix): \(error)\n", stderr)
            return nil
        }

        let deadline = Date().addingTimeInterval(Self.commandTimeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private func sendNotification(subtitle: String, message: String) {
        guard let consoleUser = Self.consoleUser() else {
            return
        }

        runProcess(
            executablePath: "/bin/launchctl",
            arguments: [
                "asuser",
                String(consoleUser.uid),
                "/usr/bin/open",
                "-n",
                "-a",
                notifierAppPath,
                "--args",
                "--notify",
                "--title",
                notificationTitle,
                "--subtitle",
                subtitle,
                "--body",
                message
            ],
            errorPrefix: "Failed to post notification"
        )
    }

    private func runProcess(executablePath: String, arguments: [String], errorPrefix: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        do {
            try process.run()
        } catch {
            fputs("\(errorPrefix): \(error)\n", stderr)
            return
        }

        let deadline = Date().addingTimeInterval(Self.commandTimeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if process.isRunning {
            process.terminate()
        }
    }

    private static func consoleUser() -> ConsoleUser? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let cfUser = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) else {
            return nil
        }

        let user = cfUser as String
        guard !user.isEmpty, user != "loginwindow", user != "root" else {
            return nil
        }

        // Confirms the account resolves to a real directory-services record
        // before we start running commands as it.
        guard NSHomeDirectoryForUser(user) != nil else {
            return nil
        }

        return ConsoleUser(name: user, uid: uid)
    }

    private static func extractQuotedName(from line: String) -> String? {
        guard let firstQuote = line.firstIndex(of: "\"") else {
            return nil
        }

        let afterFirstQuote = line.index(after: firstQuote)
        guard let secondQuote = line[afterFirstQuote...].firstIndex(of: "\"") else {
            return nil
        }

        return String(line[afterFirstQuote..<secondQuote])
    }
}
