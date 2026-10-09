//
//  SSHAgentSandboxPolicy.swift
//  JTSTerminal
//

import Foundation

/// Which ssh-agent sockets a sandboxed `/usr/bin/ssh` child can reach.
///
/// Measured with `scripts/sandbox_probes/run_ssh_agent_probe.sh`, signed with
/// the app's entitlements: on macOS 26.6 the launchd-managed agent socket
/// (`/private/var/run/com.apple.launchd.*/Listeners`) is reachable and an
/// agent-only ssh login succeeds. Agent sockets anywhere else — third-party
/// agents, `ssh-agent -a`, sockets in `~/.ssh` or `/tmp` — are denied by App
/// Sandbox (`deny network-outbound`). macOS 15 kept the launchd socket under
/// `/private/tmp` and denied it too.
nonisolated enum SSHAgentSandboxPolicy {
    enum Availability: Equatable {
        /// `SSH_AUTH_SOCK` is not set for the app.
        case notConfigured
        /// The macOS launchd ssh-agent, reachable from the sandbox.
        case systemAgent
        /// Another agent socket, which the sandbox denies.
        case blockedBySandbox(socketPath: String)
    }

    static func availability(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Availability {
        let path = environment["SSH_AUTH_SOCK"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return .notConfigured }
        return isSystemAgentSocket(path) ? .systemAgent : .blockedBySandbox(socketPath: path)
    }

    static func isSystemAgentSocket(_ path: String) -> Bool {
        var candidate = Substring(path)
        if candidate.hasPrefix("/private/") {
            candidate = candidate.dropFirst("/private".count)
        }
        let prefix = "/var/run/"
        guard candidate.hasPrefix(prefix) else { return false }

        let components = candidate
            .dropFirst(prefix.count)
            .split(separator: "/", omittingEmptySubsequences: false)
        let launchdPrefix = "com.apple.launchd."
        return components.count == 2
            && components[0].hasPrefix(launchdPrefix)
            && components[0].count > launchdPrefix.count
            && components[1] == "Listeners"
    }
}
