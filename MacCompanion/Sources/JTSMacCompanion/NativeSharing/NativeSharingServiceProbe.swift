import Foundation

/// A read-only RFB greeting probe. It never toggles Screen Sharing, authenticates
/// a Mac account, modifies TCC or sends remote desktop input.
enum NativeSharingServiceProbe {
    static func available() async -> Bool {
        var stream: NativeSharingLoopbackStream?
        do {
            let connected = try await NativeSharingLoopbackStream.connect()
            stream = connected
            let greeting = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await connected.read(maximumBytes: 12) }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    await connected.close()
                    throw NativeSharingError.unavailable
                }
                defer { group.cancelAll() }
                let value = try await group.next()!
                await connected.close()
                return value
            }
            return greeting.starts(with: Data("RFB ".utf8))
        } catch { await stream?.close(); return false }
    }
}
