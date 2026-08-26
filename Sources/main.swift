import Foundation

let controller = WiFiProxyController()

if CommandLine.arguments.contains("--reset") {
    controller.reset()
} else if CommandLine.arguments.contains("--once") {
    controller.reportState()
} else if CommandLine.arguments.contains("--listen-only") {
    // Development: runs the forwarder only. Publishes no configuration and
    // posts no notifications.
    controller.run(publishConfiguration: false)
} else {
    controller.run()
}
