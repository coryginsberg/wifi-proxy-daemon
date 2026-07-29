import CoreWLAN
import Foundation
import SystemConfiguration

private let commandTimeout: TimeInterval = 15

private struct PersistedState: Codable {
    var lastNetwork: String?
    var wasProxyEnabled: Bool
}

private struct ProxyConfiguration {
    let url: String
    let host: String
    let port: Int
    let noProxy: String
    let nonProxyHosts: String

    var bypassDomains: [String] {
        noProxy
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var javaProxyOptions: String {
        "-Dhttp.proxyHost=\(host) -Dhttp.proxyPort=\(port) -Dhttps.proxyHost=\(host) -Dhttps.proxyPort=\(port)"
    }

    var sbtProxyOptions: String {
        "-Dhttp.proxyHost=\(host) -Dhttp.proxyPort=\(port) -Dhttps.proxyHost=\(host) -Dhttps.proxyPort=\(port) -Dhttp.nonProxyHosts=\(nonProxyHosts) -Dhttps.nonProxyHosts=\(nonProxyHosts)"
    }
}

private struct ConsoleUser {
    let name: String
    let uid: uid_t
    let homeDirectory: URL
}

final class WiFiProxyController {
    private let domainMatch: String
    private let stateFileURL: URL
    private let notificationTitle: String
    private let vpnMatch: String
    private let notifierAppPath: String
    private let proxyConfiguration: ProxyConfiguration
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
        let proxyURL = environment["WIFI_PROXY_URL"] ?? "http://proxy.cat.com:80"
        let proxyHost = environment["WIFI_PROXY_HOST"] ?? "proxy.cat.com"
        let proxyPort = Int(environment["WIFI_PROXY_PORT"] ?? "80") ?? 80
        let noProxy = environment["WIFI_PROXY_NO_PROXY"] ?? "localhost,.cat.com,169.254.169.254"
        let nonProxyHosts = environment["WIFI_PROXY_NON_PROXY_HOSTS"] ?? "*.cat.com|localhost"
        self.proxyConfiguration = ProxyConfiguration(
            url: proxyURL,
            host: proxyHost,
            port: proxyPort,
            noProxy: noProxy,
            nonProxyHosts: nonProxyHosts
        )
        let state = Self.loadState(from: stateFileURL)
        self.lastNetwork = state.lastNetwork
        self.wasProxyEnabled = state.wasProxyEnabled
    }

    func run() {
        evaluateProxyState()

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

    func runOnce() {
        evaluateProxyState()
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
        // Guard against re-entrancy: applyProxyConfiguration runs nested run
        // loops while waiting on subprocesses, which can service a pending
        // scheduled evaluation.
        if isEvaluating {
            return
        }
        isEvaluating = true
        defer { isEvaluating = false }

        let matchedNetwork = currentMatchingNetwork()
        let vpnConnection = currentVPNConnection()
        let shouldEnableProxy = matchedNetwork != nil || vpnConnection != nil
        let isInitialEvaluation = !hasReconciledState
        let stateChanged = shouldEnableProxy != wasProxyEnabled

        // Reconcile the actual system configuration on first run and whenever the
        // effective proxy state changes.
        if isInitialEvaluation || stateChanged {
            applyProxyConfiguration(enabled: shouldEnableProxy)
        }

        // Only notify on a genuine change of proxy state. A restart or reconcile
        // that finds the proxy already in its persisted state stays silent.
        if stateChanged {
            let subtitle = shouldEnableProxy ? "Proxy enabled" : "Proxy disabled"
            sendNotification(subtitle: subtitle, message: notificationMessage(network: matchedNetwork, vpnConnection: vpnConnection))
        }

        if isInitialEvaluation || matchedNetwork != lastNetwork || stateChanged {
            lastNetwork = matchedNetwork
            wasProxyEnabled = shouldEnableProxy
            hasReconciledState = true
            persistState(PersistedState(lastNetwork: matchedNetwork, wasProxyEnabled: shouldEnableProxy))
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
            return PersistedState(lastNetwork: nil, wasProxyEnabled: false)
        }

        if let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            return state
        }

        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return PersistedState(lastNetwork: value.isEmpty ? nil : value, wasProxyEnabled: false)
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

        let deadline = Date().addingTimeInterval(commandTimeout)
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

    private func applyProxyConfiguration(enabled: Bool) {
        updateSystemProxy(enabled: enabled)

        guard let consoleUser = Self.consoleUser() else {
            return
        }

        updateLaunchdEnvironment(for: consoleUser, enabled: enabled)
        updateShellProxyFile(for: consoleUser, enabled: enabled)
        updateGitProxy(for: consoleUser, enabled: enabled)
    }

    private func updateSystemProxy(enabled: Bool) {
        for service in networkServices() {
            if enabled {
                runProcess(
                    executablePath: "/usr/sbin/networksetup",
                    arguments: ["-setwebproxy", service, proxyConfiguration.host, String(proxyConfiguration.port)],
                    errorPrefix: "Failed to set web proxy for \(service)"
                )
                runProcess(
                    executablePath: "/usr/sbin/networksetup",
                    arguments: ["-setsecurewebproxy", service, proxyConfiguration.host, String(proxyConfiguration.port)],
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
                ("ALL_PROXY", proxyConfiguration.url),
                ("all_proxy", proxyConfiguration.url),
                ("HTTP_PROXY", proxyConfiguration.url),
                ("http_proxy", proxyConfiguration.url),
                ("HTTPS_PROXY", proxyConfiguration.url),
                ("https_proxy", proxyConfiguration.url),
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

    private func updateShellProxyFile(for consoleUser: ConsoleUser, enabled: Bool) {
        let shellFileURL = consoleUser.homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("wifi-proxy-daemon", isDirectory: true)
            .appendingPathComponent("proxy-env.zsh")

        do {
            try FileManager.default.createDirectory(
                at: shellFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try shellProxyFileContents(enabled: enabled).write(to: shellFileURL, atomically: true, encoding: .utf8)
        } catch {
            fputs("Failed to update shell proxy file: \(error)\n", stderr)
        }
    }

    private func shellProxyFileContents(enabled: Bool) -> String {
        var lines = ["# Managed by wifi-proxy-daemon. Do not edit."]

        if enabled {
            lines.append("export ALL_PROXY=\(shellQuoted(proxyConfiguration.url))")
            lines.append("export all_proxy=\(shellQuoted(proxyConfiguration.url))")
            lines.append("export HTTP_PROXY=\(shellQuoted(proxyConfiguration.url))")
            lines.append("export http_proxy=\(shellQuoted(proxyConfiguration.url))")
            lines.append("export HTTPS_PROXY=\(shellQuoted(proxyConfiguration.url))")
            lines.append("export https_proxy=\(shellQuoted(proxyConfiguration.url))")
            lines.append("export NO_PROXY=\(shellQuoted(proxyConfiguration.noProxy))")
            lines.append("export no_proxy=\(shellQuoted(proxyConfiguration.noProxy))")
            lines.append("export JAVA_OPTS=\(shellQuoted(proxyConfiguration.javaProxyOptions))")
            lines.append("export java_opts=\(shellQuoted(proxyConfiguration.javaProxyOptions))")
            lines.append("export ES_JAVA_OPTS=\(shellQuoted(proxyConfiguration.javaProxyOptions))")
            lines.append("export SBT_OPTS=\"${WIFI_PROXY_BASE_SBT_OPTS:-}\"")
            lines.append("export SBT_OPTS=\"${SBT_OPTS:+$SBT_OPTS }\(proxyConfiguration.sbtProxyOptions)\"")
            lines.append("export sbt_opts=\"$SBT_OPTS\"")
        } else {
            lines.append("unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy")
            lines.append("unset JAVA_OPTS java_opts ES_JAVA_OPTS")
            lines.append("export SBT_OPTS=\"${WIFI_PROXY_BASE_SBT_OPTS:-}\"")
            lines.append("export sbt_opts=\"$SBT_OPTS\"")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func updateGitProxy(for consoleUser: ConsoleUser, enabled: Bool) {
        if enabled {
            runProcess(
                executablePath: "/usr/bin/sudo",
                arguments: ["-H", "-u", consoleUser.name, "/usr/bin/git", "config", "--global", "http.proxy", proxyConfiguration.url],
                errorPrefix: "Failed to set git http proxy"
            )
            runProcess(
                executablePath: "/usr/bin/sudo",
                arguments: ["-H", "-u", consoleUser.name, "/usr/bin/git", "config", "--global", "https.proxy", proxyConfiguration.url],
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

    private func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
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

        let deadline = Date().addingTimeInterval(commandTimeout)
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

        let deadline = Date().addingTimeInterval(commandTimeout)
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

        guard let homeDirectoryPath = NSHomeDirectoryForUser(user) else {
            return nil
        }

        return ConsoleUser(name: user, uid: uid, homeDirectory: URL(fileURLWithPath: homeDirectoryPath, isDirectory: true))
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

let controller = WiFiProxyController()

if CommandLine.arguments.contains("--once") {
    controller.runOnce()
} else {
    controller.run()
}
