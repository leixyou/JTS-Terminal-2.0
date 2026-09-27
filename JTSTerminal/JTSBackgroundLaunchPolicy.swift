import Foundation

nonisolated enum JTSBackgroundLaunchPolicy {
    static let argument = "--jts-background-desktop"
    static var isBackgroundLaunch: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func openArguments(bundlePath: String, activate: Bool) -> [String] {
        activate ? [bundlePath] : ["-g", bundlePath, "--args", argument]
    }
}
