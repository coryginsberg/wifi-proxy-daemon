import Foundation

let controller = WiFiProxyController()

if CommandLine.arguments.contains("--reset") {
    controller.reset()
} else if CommandLine.arguments.contains("--once") {
    controller.reportState()
} else if CommandLine.arguments.contains("--listen-only") {
    // Development: exercise the forwarder without root or config side effects.
    controller.run(publishConfiguration: false)
} else {
    controller.run()
}
